v = fn n -> :cerl.c_var(n) end
seq = fn a, b -> :cerl.c_seq(a, b) end
call = fn m, f, as_ -> :cerl.c_call(:cerl.abstract(m), :cerl.abstract(f), as_) end
raw_raise = fn c, r, s -> :cerl.c_primop(:cerl.abstract(:raw_raise), [c, r, s]) end

mkcase = fn rvar, cvar, svar ->
  :cerl.c_case(call.(:slop_rt, :truthy, [rvar]),
    [:cerl.ann_c_clause([], [:cerl.abstract(true)], :cerl.abstract(:handled)),
     :cerl.ann_c_clause([], [:cerl.abstract(false)], raw_raise.(cvar, rvar, svar))])
end

test = fn name, full ->
  m = :cerl.c_module(:cerl.abstract(:m1), [:cerl.c_fname(:f, 0)], [],
    [{:cerl.c_fname(:f, 0), :cerl.c_fun([], full)}])
  case :compile.forms(m, [:from_core, :binary]) do
    {:ok, _, _} -> IO.puts("#{name}: ok")
    _ -> IO.puts("#{name}: ERROR")
  end
end

throw_call = call.(:erlang, :throw, [:cerl.abstract(:ball)])
plain_rr = raw_raise.(v.(:"_7"), v.(:"_6"), v.(:"_5"))

for {bname, body} <- [{"call", throw_call}, {"seq", seq.(throw_call, :cerl.abstract(:body))}],
    {hname, ih} <- [{"case", mkcase.(v.(:"_2"), v.(:"_3"), v.(:"_1"))}, {"rr", raw_raise.(v.(:"_3"), v.(:"_2"), v.(:"_1"))}],
    {oname, oh} <- [{"case", mkcase.(v.(:"_6"), v.(:"_7"), v.(:"_5"))}, {"rr", plain_rr}] do
  inner = :cerl.c_try(body, [v.(:"_0")], v.(:"_0"), [v.(:"_3"), v.(:"_2"), v.(:"_1")], ih)
  outer = :cerl.c_try(inner, [v.(:"_4")], v.(:"_4"), [v.(:"_7"), v.(:"_6"), v.(:"_5")], oh)
  test.("body=#{bname} innerH=#{hname} outerH=#{oname}", outer)
end
