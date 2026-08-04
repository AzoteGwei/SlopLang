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

## Decorator expressions

`@` accepts any expression: calls, attribute chains, factories —
`@deco(1, 2)`, `@app.get("/hello/<name>")`, `@registry.register("x")`.
The expression is evaluated at definition time (top to bottom), the
result is invoked with the defined function/class, and the name binds to
the returned replacement. Registration-style decorators that mutate
shared state should keep that state in ETS or a process (immutable values
make instance-mutating registration invisible to later readers); see
`sloplib/web.slop` and `examples/12_decorators.slop`.

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
- `app.run(host, port)` — blocking development server backed by
  `slop_http` (gen_tcp + OTP HTTP packet parsing, one spawned process per
  connection, so requests are served concurrently).
- Deferred: templates, static files, middleware, keep-alive, HTTPS.
