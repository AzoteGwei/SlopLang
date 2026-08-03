alias :cerl, as: C
lit = &C.abstract/1
test = fn name, body ->
  mod = C.c_module(lit.(:t), [C.c_fname(:main, 0)], [], [{C.c_fname(:main, 0), C.c_fun([], body)}])
  case :compile.forms(mod, [:from_core, :binary, :return_errors]) do
    {:ok, :t, bin, _} -> :code.load_binary(:t, ~c"t.beam", bin); IO.puts("#{name}: OK -> #{inspect(:t.main())}")
    err -> IO.puts("#{name}: FAIL #{inspect(err)}")
  end
end
# 1: simple literal
test.("lit", lit.(42))
# 2: binary literal
test.("binlit", lit.(<<"héllo">>))
# 3: let + call
test.("call", C.c_let([C.c_var(:S)], lit.(<<"x">>), C.c_call(lit.(:io), lit.(:format), [lit.(~c"~p~n"), C.c_cons(C.c_var(:S), C.c_nil())])))
# 4: values in let (multi bind)
test.("values", C.c_let([C.c_var(:A), C.c_var(:B)], C.c_values([lit.(1), lit.(2)]), C.c_var(:A)))
# 5: binary construction
test.("binseg", C.c_binary([C.c_bitstr(lit.(?a), lit.(8), lit.(1), lit.(:integer), lit.([:unsigned, :big]))]))
# 6: map pattern
test.("mappat", C.c_case(lit.(%{a: 5}), [
  C.c_clause([C.c_map_pattern([C.c_map_pair_exact(lit.(:a), C.c_var(:A))])], lit.(true), C.c_var(:A)),
  C.c_clause([C.c_var(:_)], lit.(true), lit.(:none))
]))
# 7: map construction
test.("mapcon", C.c_map(lit.(%{}), [C.c_map_pair_exact(lit.(:a), lit.(1))]))
# 8: nested case as call arg
test.("nested", C.c_call(lit.(:erlang), lit.(:length), [C.c_case(lit.(true), [C.c_clause([lit.(true)], lit.(true), C.c_cons(lit.(1), C.c_nil())), C.c_clause([lit.(false)], lit.(true), C.c_nil())])]))
# 9: fname as value + apply
f2 = C.c_fname(:double, 2)
test.("fname", C.c_let([C.c_var(:F)], f2, lit.(:ok)))
