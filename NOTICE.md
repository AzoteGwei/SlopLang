# Dependency & License Record

SlopLang itself: 0BSD (see LICENSE).

Runtime/build-time dependencies (no third-party libraries):

| Component | License | Notes |
|---|---|---|
| Erlang/OTP | Apache-2.0 | Target VM. `compiler` assembles Core Erlang into BEAM bytecode; runtime also uses OTP stdlib modules (`gen_tcp`, `ets`, `timer`, `maps`, ...) including the HTTP packet parser in `kernel` |
| Elixir | Apache-2.0 | Implementation language of the compiler toolchain |

The HTTP development server (`src/slop_http.erl`), the web framework
(`sloplib/web.slop`), and the stream library (`sloplib/stream.slop`) are
original SlopLang code (0BSD); no third-party libraries are used.

No GPL/LGPL/AGPL code is used anywhere in this project.
