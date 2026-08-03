v = fn n -> :cerl.c_var(n) end
call = fn m, f, as_ -> :cerl.c_call(:cerl.abstract(m), :cerl.abstract(f), as_) end
raw_raise = fn c, r, s -> :cerl.c_primop(:cerl.abstract(:raw_raise), [c, r, s]) end

mk = fn body, handler ->
  inner = :cerl.c_try(body, [v.(:"_0")], v.(:"_0"), [v.(:"_3"), v.(:"_2"), v.(:"_1")], handler)
  outer_h = raw_raise.(v.(:"_7"), v.(:"_6"), v.(:"_5"))
  :cerl.c_try(inner, [v.(:"_4")], v.(:"_4"), [v.(:"_7"), v.(:"_6"), v.(:"_5")], outer_h)
end

test = fn name, full ->
  m = :cerl.c_module(:cerl.abstract(:m1), [:cerl.c_fname(:f, 0)], [],
    [{:cerl.c_fname(:f, 0), :cerl.c_fun([], full)}])
  case :compile.forms(m, [:from_core, :binary]) do
    {:ok, _, _} -> IO.puts("#{name}: ok")
    {:error, _, _} -> IO.puts("#{name}: ERROR")
    :error -> IO.puts("#{name}: ERROR2")
  end
end

throw_call = call.(:erlang, :throw, [:cerl.abstract(:ball)])

# 1. exact Erlang shape
test.("exact", mk.(throw_call, raw_raise.(v.(:"_3"), v.(:"_2"), v.(:"_1"))))

# 2. handler with case around raw_raise
h2 = :cerl.c_case(call.(:slop_rt, :truthy, [v.(:"_2")]),
  [:cerl.ann_c_clause([], [:cerl.abstract(true)], :cerl.abstract(:handled)),
   :cerl.ann_c_clause([], [:cerl.abstract(false)], raw_raise.(v.(:"_3"), v.(:"_2"), v.(:"_1")))])
test.("case-handler", mk.(throw_call, h2))
