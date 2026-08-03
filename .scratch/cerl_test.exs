alias :cerl, as: C
lit = &C.abstract/1
main_fname = C.c_fname(:main, 0)
s = C.c_var(:S)
a_var = C.c_var(:A)
body =
  C.c_let(
    [s],
    lit.(<<"héllo">>),
    C.c_call(lit.(:io), lit.(:format), [
      lit.(~c"~p ~p ~p~n"),
      C.c_values([
        s,
        C.c_binary([C.c_bitstr(lit.(?a), lit.(8), lit.(1), lit.(:integer), lit.([:unsigned, :big]))]),
        C.c_case(lit.(%{a: 5}), [
          C.c_clause([C.c_map_pattern([C.c_map_pair_exact(lit.(:a), a_var)])], lit.(true), a_var),
          C.c_clause([C.c_var(:_)], lit.(true), lit.(:none))
        ])
      ])
    ])
  )
mdef = {main_fname, C.c_fun([], body)}
mod = C.c_module(lit.(:m), [main_fname], [], [mdef])
case :compile.forms(mod, [:from_core, :binary, :return_errors, :return_warnings]) do
  {:ok, :m, bin, warns} ->
    IO.inspect(warns, label: "warnings")
    :code.load_binary(:m, ~c"m.beam", bin)
    :m.main()
  other -> IO.inspect(other, label: "FAIL")
end
