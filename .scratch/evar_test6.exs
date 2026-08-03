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

# both handlers are cases, inner body has seq
inner = :cerl.c_try(seq.(throw_call, :cerl.abstract(:body)), [v.(:"_0")], v.(:"_0"),
  [v.(:"_3"), v.(:"_2"), v.(:"_1")], mkcase.(v.(:"_2"), v.(:"_3"), v.(:"_1")))
outer = :cerl.c_try(inner, [v.(:"_4")], v.(:"_4"),
  [v.(:"_7"), v.(:"_6"), v.(:"_5")], mkcase.(v.(:"_6"), v.(:"_7"), v.(:"_5")))
test.("both-case + seq-body", outer)

# outer handler case, inner body seq, but try is inside a let that destructures
innerfull = :cerl.c_let([v.(:"_9")], inner, v.(:"_9"))
outer2 = :cerl.c_try(seq.(innerfull, :cerl.abstract(:body)), [v.(:"_4")], v.(:"_4"),
  [v.(:"_7"), v.(:"_6"), v.(:"_5")], mkcase.(v.(:"_6"), v.(:"_7"), v.(:"_5")))
test.("let-wrapped inner", outer2)

# destructuring case after inner try
destr = :cerl.c_let([v.(:"_9")], inner,
  :cerl.c_case(call.(:erlang, :element, [:cerl.abstract(1), v.(:"_9")]),
    [:cerl.ann_c_clause([], [:cerl.abstract(:body)], :cerl.abstract(:nil)),
     :cerl.ann_c_clause([], [:cerl.abstract(:handler)], :cerl.abstract(:nil))]))
outer3 = :cerl.c_try(seq.(destr, :cerl.abstract(:body)), [v.(:"_4")], v.(:"_4"),
  [v.(:"_7"), v.(:"_6"), v.(:"_5")], mkcase.(v.(:"_6"), v.(:"_7"), v.(:"_5")))
test.("destructured inner", outer3)
