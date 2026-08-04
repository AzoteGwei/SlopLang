# SlopLang Semantics

SlopLang keeps Python's surface syntax but runs on the BEAM, where all data
is immutable. This document describes where SlopLang follows Python, and
where it deliberately deviates.

## Values

| SlopLang type | BEAM representation |
| ------------- | ------------------- |
| `int`         | integer             |
| `float`       | float               |
| `str`         | UTF-8 binary        |
| `bool`        | `true` / `false`    |
| `None`        | `nil`               |
| `list`        | Erlang list         |
| `tuple`       | Erlang tuple        |
| `dict`        | Erlang map          |
| `set`         | `{'$set', Map}`     |
| instance      | map with a `'$class'` key |
| class         | atom `'module.Name'` |

All values are immutable terms. There is no in-place mutation anywhere in
the language.

## Rebinding instead of mutation

Because values are immutable, "mutating" operations return updated values:

```python
xs = [3, 1, 2]
ys = xs.sort()      # xs is unchanged; ys is the sorted list
```

To keep Python's ergonomic statement style, SlopLang has the **statement
rebind rule**: when a statement consists of a single method call whose
receiver is a name (or an attr/subscript chain rooted at a name), the
receiver is rebound to the call's result:

```python
xs.sort()                # same as: xs = xs.sort()
self.items.append(x)     # same as: self.items = self.items.append(x)
st.push(1).push(2)       # same as: st = st.push(1).push(2)
```

The rebind is **type-conditional**: it only takes effect when the result
has the same kind as the receiver (list→list, dict→dict, set→set, or an
instance of the same class). Value-returning calls leave the binding
alone:

```python
st.pop()     # st is NOT rebound to the popped integer
n.bit_length()  # n is unchanged
```

In expression position (`y = xs.pop()` etc.) no rebind ever happens; the
expression simply evaluates to the result.

## The pop protocol

Since a single value cannot both yield an element and the updated
collection, `pop` on lists, dicts, and sets returns a 2-tuple
`(updated, element)`:

```python
xs, top = xs.pop()       # unpack rebinds xs and binds top
d2, val = d.pop("k")
```

User classes that model mutable state should follow the same convention
(see `examples/09_classes_state.slop`):

```python
class Stack:
    def pop(self):
        self.items, top = self.items.pop()
        return (self, top)

st, a = st.pop()
```

## Objects and methods

- `__init__` initializes `self` via attribute assignment; its (implicit)
  return value is the resulting instance.
- A method with no explicit `return` evaluates to `self`, so mutating
  methods chain naturally: `st.push(1).push(2).push(3)`.
- Attribute assignment returns the updated object, so `self.x = 1`
  rebinds the local `self` variable; callers that hold the old instance
  keep the old value unless the rebind rule applies.

## Closures

Closures capture their enclosing environment **by value** at the point
the function is created:

```python
fs = [lambda: i for i in range(3)]
[f() for f in fs]    # [2, 2, 2], matching Python's late binding here
```

`nonlocal` is not supported (parse error); rebinding a captured variable
inside a closure does not affect the outer scope. Module-level names are
always read through the module environment, so lambdas can reference
module globals defined by the time the call happens (including the
binding they are assigned to, e.g. memoized self-recursion at module
level).

## Other deviations from Python

- Generators are eager: a generator expression fully evaluates to a list.
- `NAME.method()` in statement position rebinds (see above); Python
  mutates in place instead.
- Loop closures capture loop variables by value per iteration state.
- Integers are arbitrary precision (BEAM), floats are 64-bit.
- `str` is a UTF-8 binary; indexing yields 1-character strings.

## Error model

SlopLang exceptions are thrown as `{'$slop_exc', Class, Instance}` terms
and integrate with `try`/`except`/`finally`, `raise ... from ...`, and
exception classes with inheritance. Uncaught exceptions print the class
and `args`.

## BEAM interop

### Inbound: calling Erlang/Elixir from SlopLang

`import erlang.MOD` and `import elixir.MOD` bind a foreign-module value
(the as-name or last dotted segment):

```python
import erlang.lists
import erlang.crypto
import elixir.String

lists.reverse([1, 2, 3])          # [3, 2, 1]
crypto.strong_rand_bytes(16)      # binary
String.upcase("hi")               # "HI"
```

Attribute access on a foreign module yields a foreign function; calling it
performs a plain BEAM `apply`. Keyword arguments become a trailing Elixir
keyword list. `atom("ok")` creates a BEAM atom.

Value mapping (both directions):

| SlopLang            | Erlang term                          |
| ------------------- | ------------------------------------ |
| `str`               | binary                               |
| `int` / `float`     | integer / float                      |
| `list` / `tuple`    | list / tuple                         |
| `dict`              | map                                  |
| `None`              | `nil`                                |
| `bool`              | `true` / `false`                     |
| `atom("...")`       | atom                                 |
| pid / ref (W2)      | pid / reference                      |
| functions           | `fun(Pos, Kw)` closures (see below)  |

Erlang results that are pids, references, ports, or plain atoms pass
through as opaque values and can be sent messages, compared, and printed.

### Outbound: calling SlopLang from Erlang/Elixir

A compiled `.beam` exports every top-level `def name(...)` as:

- `name/2` — `name(ArgsList, KwMap)`; defaults are baked in and the
  module's top-level statements are initialized on first call.
- `name/3` — the raw protocol: `name(ArgsList, KwMap, DefaultsTuple)`.

Class methods export as `'mod.Class.method'/3` (the first positional
argument is `self`). Instances are created with
`slop_rt:instantiate('mod.Class', Args, Kw)`.

```erlang
out:double([21], #{}).                      %% 42
out:greet([<<"bob">>], #{punct => <<"?">>}).
P = slop_rt:instantiate('out.Point', [3, 4], #{}),
out:'out.Point.sum'([P], #{}, {}).          %% 7
```

SlopLang functions are `fun(PosArgs, KwMap)/2` values on the BEAM, so an
Erlang side holding one calls it as `F([Arg1, Arg2], #{})`.

## Concurrency

SlopLang tasks are BEAM processes:

- `spawn(f)` / `spawn(f, args_list)` — run `f(*args)` in a new monitored
  process; returns a task handle.
- `join(task)` — blocks until the task finishes; returns its result, or
  re-raises the task's SlopLang exception in the joiner. A dead task
  raises `RuntimeError`. `join(task, timeout_ms)` returns `None` on
  timeout (the task keeps running and the result stays deliverable to a
  later `join`).
- `cancel(task)` — terminates the task and its spawned descendants
  (tree kill). Joiners observe `RuntimeError("task was cancelled")`.
- `is_alive(task)` — `True` while the task process is running.
- `task_group()` — a group; `group_spawn(g, f, args)` spawns a member,
  `group_join(g)` returns member results in spawn order. On the first
  failure the remaining members are cancelled and the exception
  re-raised (fail-fast). `group_join(g, atom("collect"))` instead
  returns a list of `(ok, result)` / `(error, message)` tuples, one per
  member in spawn order, without raising.
- `send(pid_or_task, msg)` / `recv()` / `recv(timeout_ms)` — raw BEAM
  message passing; any SlopLang value is a valid message. `recv` with a
  timeout returns `None` on expiry.
- `sleep(ms)`, `self_pid()`, `monotonic()` (milliseconds).

Because tasks are ordinary processes, IO (print) interleaves and message
passing works between any of them. Spawning and joining 10 000 tasks
takes well under a second (see `examples/13_taskgroups.slop`).

## Rejected designs

- **`async`/`await`** — rejected. SlopLang has no colored functions:
  concurrency is plain `spawn`/`join` over BEAM processes, which already
  give preemptive scheduling, per-process heaps, and distribution. An
  async subset would need an effect-typed call protocol and would
  duplicate what the runtime already does for every function. Blocking
  is cheap here, so `join` is the whole story.
- **`yield` / generators** — rejected. Generators suspend a call frame
  mid-execution, which the compile-to-Core-Erlang pipeline cannot
  represent without CPS-transforming every function (killing
  interoperability and stack traces). Lazy sequences are provided as a
  library type instead: `sloplib/stream.slop` builds streams from thunks
  (`naturals`, `iterate`, `fib`, `smap`, `sfilter`, `take`, `to_list`),
  and `for` loops/comprehensions force any sequence uniformly.

The parser rejects `async`, `await`, and `yield` with an error pointing
here, so code using them fails loudly at compile time rather than
silently misbehaving.

## Streams (sloplib/stream.slop)

Lazy, unbounded sequences without generators. A stream is a tagged
tuple wrapping a step function; the step returns `stream_end()` or a
`(value, next_step)` pair. The runtime iterates through a two-function
protocol — `seq_init/1` (opaque state) and `seq_next/1` (`(value,
state2)` or end) — used by `for` loops and comprehensions for *every*
sequence, so lists and streams share one forcing path (lists are
walked zero-copy; streams walk their step chain). Anything that
materializes (`iter`, star-unpacking, `in`, `tuple()`, `sorted()`)
forces finite streams to lists.

Library functions: `stream(step)` / `stream_end()` (constructor and
sentinel), `iterate(f, x)`, `naturals()`, `fib()`, `smap(f, s)`,
`sfilter(f, s)`, `take(n, s)`, `to_list(s)`. All combinators accept
streams or ordinary iterables.

Because steps are plain SlopLang closures, a stream element costs one
closure allocation that becomes garbage immediately: a three-stage
pipeline over `take(1000000, naturals())` runs in constant memory
(see `test/e2e/streams_test.exs`). Note: `(x for x in xs)` genexps
remain eager (they build a list); reach for streams when laziness
matters.

## Decorator expressions

`@` accepts any expression: calls, attribute chains, factories —
`@deco(1, 2)`, `@app.get("/hello/<name>")`, `@registry.register("x")`.
The expression is evaluated at definition time (top to bottom), the
result is invoked with the defined function/class, and the name binds to
the returned replacement. Registration-style decorators that mutate
shared state should keep that state in ETS or a process (immutable values
make instance-mutating registration invisible to later readers); see
`sloplib/web.slop` and `examples/12_decorators.slop`.

## The standard library (sloplib/)

Twelve modules ship in `sloplib/`, all original SlopLang code (0BSD),
importable by plain name (`import math`, `from functools import
partial`). Each wraps an OTP service only where the primitive genuinely
requires the VM; everything else is pure SlopLang. Stdlib module atoms
are namespaced (`slop$math`) so they can never shadow OTP modules.

| Module | Follows | Contents | Deliberate deviations |
|---|---|---|---|
| `math` | Python `math` | pi/e/tau, sqrt/pow/exp/log/log2/log10, trig, floor/ceil/trunc, fabs/fmod, isclose, gcd/lcm/factorial/isqrt, degrees/radians | no inf/nan/isinf/isnan: BEAM floats trap on overflow and divide-by-zero instead of producing inf/nan; no erf/gamma (not in OTP `:math`) |
| `random` | Python `random` | seed, random, uniform, randint, randrange, choice, choices, shuffle, sample | PRNG state is per-process (BEAM process state), no getstate/setstate; shuffle returns a NEW list (immutability) |
| `hashlib` | PEP 247 (`hashlib`) | new + update/digest/hexdigest; md5/sha1/sha224/sha256/sha384/sha512 constructors with optional data | algorithms limited to OTP `:crypto`; no shake/blake2 keyed variants; str input is UTF-8 |
| `statistics` | PEP 450 | mean/fmean, median/median_low/median_high, mode/multimode, pvariance/variance, pstdev/stdev | ints/floats only (no Fraction/Decimal); no NormalDist |
| `functools` | PEP 309 (`partial`) + `reduce`/`cache` | partial (positional+keyword), reduce, cache (ETS-backed), lru_cache (unbounded), compose | lru_cache accepts but does not enforce maxsize; no __wrapped__ introspection |
| `itertools` | Python `itertools` | count/cycle/repeat/chain/islice/takewhile/dropwhile/accumulate/pairwise/zip_longest | built on SlopLang streams: lazy results are streams, not iterators; cycle materializes its source once; no combinatorics family yet |
| `collections` | Python `collections` | Counter (update/most_common/elements/total/get, zero-default getitem), defaultdict(factory) | no OrderedDict: SlopLang dicts are unordered BEAM maps — documented, not faked; no namedtuple/deque yet |
| `re` | Python `re` | compile/search/match/fullmatch/findall/sub/split/escape; Match with group/groups/start/end/span | engine is OTP `:re` (PCRE), not CPython's — edge syntax can differ; sub replaces all (no count); no groupdict; `match` is a soft keyword in SlopLang so `re.match(...)` works |
| `json` | Python `json` | dumps/loads with the same default separators as web.slop | dict keys stringified on dump; non-container objects fall back to str(); no hooks; NaN/Infinity not representable |
| `datetime` | Python `datetime` | date/time/datetime/timedelta, now/utcnow/today/fromtimestamp, isoformat/fromisoformat, weekday, timestamp round-trip | naive datetimes only — no tzinfo, so PEP 495 fold is N/A; strptime restricted to ISO 8601 |
| `os` | Python `os` (selective) | getcwd/listdir/getenv/remove/rename/mkdir/makedirs/system_time + os.path (join/basename/dirname/split/splitext/exists/isfile/isdir/abspath/isabs) | POSIX process model (fork/exec/wait), uid/gid, signals: N/A, not faked |
| `sys` | Python `sys` (selective) | platform/otp_release/version_info/maxsize | CPython interpreter introspection (refcounts, frames, recursion limit) is N/A; `argv()` and `exit()` stay builtins |

See `examples/15_stdlib.slop` for a golden-output tour of all twelve.

## Hot reload

SlopLang code can be swapped into a running VM without a restart.

**Entry point.** `import sloplang` → `sloplang.recompile(path)` recompiles
a `.slop` file plus its import tree and loads the new BEAM binaries with
`code:load_binary/3`. It returns `(ok, module_name)` or `(error,
message)`; a failed compile leaves the running code untouched. The
wrapper lives in `sloplib/sloplang.slop`; the primitive is
`slop_rt:recompile/1` because compilation and code loading are VM
services.

**Reload semantics.** BEAM keeps at most two versions of a module; this
is what reloads mean for each kind of state:

- **Running tasks/processes** keep executing the version they started
  on until they return from it. New calls go to the new version. If a
  *second* reload happens while a process still runs the *oldest*
  version, the VM's two-version limit forces that process out — it is
  killed by `code:purge/1`. In practice only in-flight web requests hit
  this; the keep-alive process and the source watcher run inside
  `slop_rt` (never recompiled) precisely so reloads never find user
  frames on their stacks.
- **Module globals** (the per-name ETS rows backing module state) are
  cleared for every recompiled module and re-initialized from the new
  source on next access: reload *resets* module-level state. Named ETS
  tables, process dictionaries, and registered names survive — code
  that owns them must be idempotent or check for existing state
  (the web framework does both).
- **Existing instances and closures.** A closure captures its code
  version and keeps it. Instances created before a reload dispatch
  method calls to the *new* class code (class registration is by name),
  while their attribute maps are untouched.
- **The web route registry.** Routes live in a per-App ETS *set* table
  keyed by `(method, pattern)`. A reload builds a fresh App (fresh
  table), and re-registering an identical route replaces rather than
  duplicates — repeated reloads never accumulate duplicate routes.

**Debug server.** `app.run(port=..., debug=True)` starts a watcher (in
`slop_rt`, polling mtimes of the entry file and its import tree every
400 ms). On change it recompiles and re-registers the app; the listen
socket and the connection-handler fun (`slop_rt:http_dispatch/2`) are
never touched, so there is no downtime window. A broken edit logs
`reload failed: ...` / `keeping the previous version` and the old code
keeps serving; the next valid edit reloads normally. Editing the
framework itself (`sloplib/web.slop`, `slop_rt`, `slop_http`) requires a
restart — the watcher only watches the application tree, and
runtime-infrastructure code is deliberately kept out of the purge path.

## Dynamic execution (eval / exec)

`eval(source)` compiles and evaluates an expression string at runtime;
`exec(source)` compiles and executes statements. Both take an optional
second argument naming the execution context.

**Contexts.** The default context is the *caller's module*: the dynamic
source sees the module's globals (`g = 10; eval("g * 2")` → `20`), and
names defined by `exec` land in that same module env, so later
`eval`/`exec` calls — and later dynamic code — can use them
(`exec("def h(x): return x * 2")` then `eval("h(21)")` → `42`). An
explicit context name (a string, e.g. `eval("x", "repl")`) selects a
standalone shared env with that name: contexts with equal names share
state, distinct names are isolated.

**Scope rule.** Dynamic code resolves names against the context
module's globals only — never against caller *locals*. There is no
runtime frame to inherit locals from (functions compile to BEAM code;
locals are SSA values), so `eval("local")` inside a function where
`local` is a local variable raises `NameError`. Pass values through
explicitly (e.g. string formatting or a named context).

**Errors.** A source string that fails to parse or compile raises
`SyntaxError`; a well-formed string whose execution fails raises the
runtime error itself (`eval("1 / 0")` → `ZeroDivisionError`). One bad
call never corrupts the session — the context env is untouched by
failed compiles, and subsequent calls keep working.

**Implementation.** Dynamic sources compile into a churn module
`dyn_<context>` whose *code identity* is separate from its *global
namespace* (the context env, plain ETS rows). This keeps hot-reload
purges from ever killing the caller's running frames. When the env
still holds values derived from a previous dynamic module (e.g. a fun
stored by `exec`), the next call compiles into a fresh suffixed module
instead of reloading — retained funs keep their code alive, exactly
like `exec`'d functions persist in a Python session. Transient calls
reuse the base module name, so `eval` in a loop does not leak atoms;
each *retained* closure necessarily retains its module.

## The web framework (sloplib/web.slop)

Bottle-flavored, implemented in SlopLang itself:

- `@app.get("/path")`, `@app.post(...)`, `@app.put/delete/route(...)`;
  `<name>` path parameters are passed positionally; query parameters are
  passed as keyword arguments.
- Handler return forms: `str` (200 text/html), `dict`/`list` (JSON),
  `(body, status)` and `(body, status, headers)` tuples, `Response`.
- `json_resp(data, status=200)`, `redirect(url, status=302)`,
  `abort(status, body)`, `HTTPError`.
- `current_request()` — the request being handled (method, path, query,
  query_string, headers, body), stored in the connection process.
- `app.run(host, port, debug=False)` — development server backed by
  `slop_http` (gen_tcp + OTP HTTP packet parsing, one spawned process per
  connection, so requests are served concurrently). With `debug=True` it
  additionally watches the app's sources and hot-reloads on change (see
  "Hot reload").
- Deferred: templates, static files, middleware, keep-alive, HTTPS.
