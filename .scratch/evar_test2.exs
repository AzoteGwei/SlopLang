v = fn n -> :cerl.c_var(String.to_atom("v#{n}")) end
call = fn m, f, as_ -> :cerl.c_call(:cerl.abstract(m), :cerl.abstract(f), as_) end
raise_exc = call.(:slop_rt, :raise_exc, [:cerl.abstract("KeyError"), :cerl.abstract("k")])

# handler: rethrow with the raw third evar
handler = call.(:slop_rt, :rethrow, [v.(1), v.(2), v.(3)])
inner_try = :cerl.c_try(raise_exc, [v.(7)], v.(7), [v.(1), v.(2), v.(3)], handler)

# outer: catch and report
report = :cerl.c_seq(
  call.(:io, :format, [:cerl.abstract("outer c=~p r=~p~n"),
    Enum.reduce(Enum.reverse([v.(11), v.(12)]), :cerl.c_nil(), &:cerl.c_cons/2)]),
  :cerl.abstract(:ok))
outer = :cerl.c_try(inner_try, [v.(16)], v.(16), [v.(10), v.(11), v.(12)], report)

m = :cerl.c_module(:cerl.abstract(:m1), [:cerl.c_fname(:f, 0)], [],
  [{:cerl.c_fname(:f, 0), :cerl.c_fun([], outer)}])

case :compile.forms(m, [:from_core, :binary]) do
  {:ok, mod, bin} ->
    :code.load_binary(mod, ~c"x", bin)
    IO.inspect(mod.f(), label: "result")
  e -> IO.inspect(e, limit: 3)
end
