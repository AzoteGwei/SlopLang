alias :cerl, as: C
lit = &C.abstract/1
test = fn name, modname, body ->
  mod = C.c_module(lit.(modname), [C.c_fname(:main, 0)], [], [{C.c_fname(:main, 0), C.c_fun([], body)}])
  case :compile.forms(mod, [:from_core, :binary, :return_errors]) do
    {:ok, _, bin} -> :code.load_binary(modname, ~c"t.beam", bin); IO.puts("#{name}: OK -> #{inspect(apply(modname, :main, []))}")
    {:ok, _, bin, _w} -> :code.load_binary(modname, ~c"t.beam", bin); IO.puts("#{name}: OK(w) -> #{inspect(apply(modname, :main, []))}")
    err -> IO.puts("#{name}: FAIL #{inspect(err, limit: 6)}")
  end
end
# letrec fun capturing outer var
outer = C.c_var(:Base)
fname = C.c_fname(:inner, 1)
x = C.c_var(:X)
fval = C.c_var(:F)
body = C.c_let([outer], lit.(10),
  C.c_letrec([{fname, C.c_fun([x], C.c_call(lit.(:erlang), lit.(:+), [x, outer]))}],
    C.c_let([fval], fname, C.c_apply(fval, [lit.(5)]))))
test.("letrec-capture", :t1, body)
# letrec self recursion + capture
n = C.c_var(:N)
body2 = C.c_let([outer], lit.(100),
  C.c_letrec([{fname, C.c_fun([n],
    C.c_let([fval], fname,
      C.c_case(C.c_call(lit.(:erlang), lit.(:>), [n, lit.(0)]), [
        C.c_clause([lit.(true)], lit.(true), C.c_apply(fval, [C.c_call(lit.(:erlang), lit.(:-), [n, lit.(1)])])),
        C.c_clause([lit.(false)], lit.(true), C.c_call(lit.(:erlang), lit.(:+), [n, outer]))
      ])))}],
    C.c_apply(fname, [lit.(3)])))
test.("letrec-rec-capture", :t2, body2)
# external fun via make_fun
body3 = C.c_let([fval], C.c_call(lit.(:erlang), lit.(:make_fun), [lit.(:lists), lit.(:reverse), lit.(1)]),
  C.c_apply(fval, [C.c_cons(lit.(1), C.c_cons(lit.(2), C.c_nil()))]))
test.("make_fun", :t3, body3)
