v = fn n -> :cerl.c_var(String.to_atom("v#{n}")) end
call = fn m, f, as_ -> :cerl.c_call(:cerl.abstract(m), :cerl.abstract(f), as_) end
list = fn items -> Enum.reduce(Enum.reverse(items), :cerl.c_nil(), &:cerl.c_cons/2) end
raise_exc = call.(:slop_rt, :raise_exc, [:cerl.abstract("KeyError"), :cerl.abstract("k")])

fmt1 = call.(:io, :format, [:cerl.abstract("c=~p r=~p~n"), list.([v.(1), v.(2)])])
fmt2 = call.(:io, :format, [:cerl.abstract("third=~p~n"), list.([v.(3)])])
handler = :cerl.c_seq(fmt1, fmt2)

inner_try = :cerl.c_try(raise_exc, [v.(7)], v.(7), [v.(1), v.(2), v.(3)], handler)

m = :cerl.c_module(:cerl.abstract(:m1), [:cerl.c_fname(:f, 0)], [],
  [{:cerl.c_fname(:f, 0), :cerl.c_fun([], inner_try)}])

case :compile.forms(m, [:from_core, :binary]) do
  {:ok, mod, bin} ->
    :code.load_binary(mod, ~c"x", bin)
    mod.f()
  e -> IO.inspect(e, limit: 3)
end
