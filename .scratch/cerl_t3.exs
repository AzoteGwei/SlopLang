alias :cerl, as: C
lit = &C.abstract/1
test = fn name, body ->
  mod = C.c_module(lit.(:t), [C.c_fname(:main, 0)], [], [{C.c_fname(:main, 0), C.c_fun([], body)}])
  case :compile.forms(mod, [:from_core, :binary, :return_errors]) do
    {:ok, :t, bin} -> :code.load_binary(:t, ~c"t.beam", bin); IO.puts("#{name}: OK -> #{inspect(:t.main())}")
    {:ok, :t, bin, _w} -> :code.load_binary(:t, ~c"t.beam", bin); IO.puts("#{name}: OK(warn) -> #{inspect(:t.main())}")
    err -> IO.puts("#{name}: FAIL #{inspect(err, limit: 8)}")
  end
end
test.("mapupd", C.ann_c_map([], lit.(%{b: 0}), [C.c_map_pair(lit.(:a), lit.(1))]))
# letrec + apply via fname value
loop = C.c_fname(:loop, 1)
n = C.c_var(:N)
lvar = C.c_var(:L)
body = C.c_letrec([{loop, C.c_fun([n],
    C.c_let([lvar], loop,
      C.c_case(C.c_call(lit.(:erlang), lit.(:>), [n, lit.(0)]), [
        C.c_clause([lit.(true)], lit.(true), C.c_apply(lvar, [C.c_call(lit.(:erlang), lit.(:-), [n, lit.(1)])])),
        C.c_clause([lit.(false)], lit.(true), C.c_tuple([lit.(:done), n]))
      ])))}], C.c_apply(loop, [lit.(3)]))
test.("letrec", body)
# try/catch
arg = C.c_var(:X)
evars = [C.c_var(:C), C.c_var(:R), C.c_var(:ST)]
body = C.c_try(
  C.c_call(lit.(:erlang), lit.(:throw), [C.c_tuple([lit.(:exc), lit.(:oops)])]),
  [arg], arg,
  evars,
  C.c_case(C.c_tuple(evars), [
    C.c_clause([C.c_tuple([lit.(:throw), C.c_tuple([lit.(:exc), C.c_var(:Msg)]), C.c_var(:_St)])], lit.(true), C.c_tuple([lit.(:caught), C.c_var(:Msg)])),
    C.c_clause([C.c_var(:Other)], lit.(true), C.c_tuple([lit.(:other), C.c_var(:Other)]))
  ]))
test.("try", body)
# primop raise (rethrow)
body2 = C.c_try(
  C.c_call(lit.(:erlang), lit.(:error), [lit.(:badarg)]),
  [arg], arg,
  evars,
  C.c_primop(lit.(:raise), [C.c_var(:ST), C.c_var(:R)]))
try do
  test.("raise", body2)
rescue
  e -> IO.puts("raise: OK (reraised) #{inspect(e.__struct__)}")
end
# seq
test.("seq", C.c_seq(C.c_call(lit.(:io), lit.(:format), [lit.(~c"side~n")]), lit.(7)))
# guard with call
test.("guard", C.c_case(lit.(5), [C.c_clause([C.c_var(:N)], C.c_call(lit.(:erlang), lit.(:>), [C.c_var(:N), lit.(3)]), lit.(:big)), C.c_clause([C.c_var(:_)], lit.(true), lit.(:small))]))
