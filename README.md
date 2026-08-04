# SlopLang

A Python-flavored programming language that compiles to BEAM bytecode and runs
on the Erlang Virtual Machine. SlopLang keeps Python's surface syntax while
honoring BEAM's immutable data semantics: all values are immutable Erlang
terms, and "mutation" is explicit rebinding.

SlopLang is an independent implementation. The compiler (written in Elixir)
parses SlopLang source into its own AST and emits Core Erlang, which the
standard Erlang compiler turns into `.beam` files.

See [docs/semantics.md](docs/semantics.md) for the language semantics,
including where SlopLang deviates from Python (immutability, the statement
rebind rule, the pop protocol, by-value closures).

## Features

- Python 3-flavored syntax: classes with inheritance, exceptions,
  match, decorators (arbitrary expressions: `@app.get("/x/<name>")`),
  comprehensions, generators (eager), f-strings, unpacking.
- BEAM interop, both directions: `import erlang.lists` / `import
  elixir.String` from SlopLang; compiled `.beam` modules export
  `name/2` entry points callable from Erlang and Elixir.
- Concurrency: `spawn`/`join` (with timeout) task builtins, `cancel`
  tree-kill, `task_group` with fail-fast and collect modes, plus
  `send`/`recv` message passing — mapped to BEAM processes; 10 000
  tasks spawn and join in well under a second.
- A 12-module standard library ([sloplib/](sloplib)): math, random,
  hashlib, statistics, functools, itertools (on lazy streams),
  collections, re, json, datetime, os, sys — each documented against
  its PEP with BEAM deviations called out.
- Hot reload: `sloplang.recompile(path)` swaps code in the running VM,
  and `app.run(debug=True)` gives the web dev server Flask-style
  source-watching reloads (broken edits keep serving the old version).
- Lazy streams ([sloplib/stream.slop](sloplib/stream.slop)):
  `naturals`/`iterate`/`fib`/`smap`/`sfilter`/`take`/`to_list`; `for`
  loops and comprehensions force streams and lists through the same
  protocol, and million-element pipelines run in constant memory.
- A Bottle-flavored web framework written in SlopLang
  ([sloplib/web.slop](sloplib/web.slop)) with a concurrent development
  server ([examples/webapp.slop](examples/webapp.slop)):

```python
from web import App, json_resp

app = App()

@app.get("/hello/<name>")
def hello(name):
    return json_resp({"hello": name})

app.run(port=8080)
```

Imports resolve relative to the importing file, then `SLOP_PATH`
(colon-separated), then the toolchain's `sloplib/`.

## Building

Requires Erlang/OTP 24+ and Elixir 1.14+.

```sh
mix escript.build      # produces ./slopc
```

## Usage

```sh
./slopc run examples/hello.slop        # compile + execute
./slopc build examples/hello.slop -o ebin_out   # write .beam files
./slopc dump examples/hello.slop       # print generated Core Erlang
./slopc tokens examples/hello.slop     # debug: token stream
./slopc parse examples/hello.slop      # debug: AST
```

## License

0BSD (see LICENSE). No external runtime dependencies beyond Erlang/OTP and
Elixir, both permissively licensed (Apache-2.0). See NOTICE.md.
