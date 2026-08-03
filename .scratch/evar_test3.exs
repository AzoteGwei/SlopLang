v = fn n -> :cerl.c_var(String.to_atom("v#{n}")) end
seq = fn a, b -> :cerl.c_seq(a, b) end
call = fn m, f, as_ -> :cerl.c_call(:cerl.abstract(m), :cerl.abstract(f), as_) end
raw_raise = fn c, r, s -> :cerl.c_primop(:cerl.abstract(:raw_raise), [c, r, s]) end
raise_exc = call.(:slop_rt, :raise_exc, [:cerl.abstract("KeyError"), :cerl.abstract("k")])

handler = :cerl.c_case(call.(:slop_rt, :exc_matches, [v.(2), :cerl.abstract([:"ValueError"])]),
  [:cerl.ann_c_clause([], [:cerl.abstract(true)], :cerl.abstract(:handled)),
   :cerl.ann_c_clause([], [:cerl.abstract(false)], raw_raise.(v.(1), v.(2), v.(3)))])

inner_try = :cerl.c_try(seq.(raise_exc, :cerl.abstract(:body)), [v.(7)], v.(7), [v.(1), v.(2), v.(3)], handler)

outer_h = :cerl.c_case(call.(:slop_rt, :exc_matches, [v.(11), :cerl.abstract([:"KeyError"])]),
  [:cerl.ann_c_clause([], [:cerl.abstract(true)], :cerl.abstract(:outer_caught)),
   :cerl.ann_c_clause([], [:cerl.abstract(false)], raw_raise.(v.(10), v.(11), v.(12)))])

outer = :cerl.c_try(inner_try, [v.(16)], v.(16), [v.(10), v.(11), v.(12)], outer_h)

m = :cerl.c_module(:cerl.abstract(:m1), [:cerl.c_fname(:f, 0)], [],
  [{:cerl.c_fname(:f, 0), :cerl.c_fun([], outer)}])

case :compile.forms(m, [:from_core, :binary]) do
  {:ok, mod, bin} ->
    :code.load_binary(mod, ~c"x", bin)
    IO.inspect(mod.f(), label: "result")
  e -> IO.inspect(e, limit: :infinity, printable_limit: :infinity)
end
