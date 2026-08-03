# SlopLang

A Python-flavored programming language that compiles to BEAM bytecode and runs
on the Erlang Virtual Machine. SlopLang keeps Python's surface syntax while
honoring BEAM's immutable data semantics: all values are immutable Erlang
terms, and "mutation" is explicit rebinding.

SlopLang is an independent implementation. The compiler (written in Elixir)
parses SlopLang source into its own AST and emits Core Erlang, which the
standard Erlang compiler turns into `.beam` files.

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
