v = fn n -> :cerl.c_var(String.to_atom("v#{n}")) end
seq = fn a, b -> :cerl.c_seq(a, b) end
let_ = fn vs, a, b -> :cerl.c_let(vs, a, b) end
call = fn m, f, as_ -> :cerl.c_call(:cerl.abstract(m), :cerl.abstract(f), as_) end
raise_f = fn c, r, st -> call.(:slop_rt, :rethrow, [c, r, st]) end
raise_exc = call.(:slop_rt, :raise_exc, [:cerl.abstract("KeyError"), :cerl.abstract("k")])

handler = fn ev_c, ev_r, ev_s, match_cls, tag ->
  nt = :cerl.c_var(:norm_t)
  nc = :cerl.c_var(:nc_v)
  let_.([nt], call.(:slop_rt, :normalize_exc, [ev_c, ev_r]),
    let_.([nc], call.(:erlang, :element, [:cerl.abstract(1), nt]),
      :cerl.c_case(call.(:slop_rt, :exc_matches, [nc, :cerl.abstract([match_cls])]),
        [:cerl.ann_c_clause([], [:cerl.abstract(true)], :cerl.abstract(tag)),
         :cerl.ann_c_clause([], [:cerl.abstract(false)], raise_f.(ev_c, ev_r, ev_s))])))
end

inner_try = :cerl.c_try(seq.(raise_exc, :cerl.abstract(:body)), [v.(7)], v.(7), [v.(1), v.(2), v.(3)], handler.(v.(1), v.(2), v.(3), "ValueError", :handled))
inner_fun = :cerl.c_apply(:cerl.c_fun([], inner_try), [])

outer = :cerl.c_try(inner_fun, [v.(16)], v.(16), [v.(10), v.(11), v.(12)], handler.(v.(10), v.(11), v.(12), "KeyError", :outer_caught))

m = :cerl.c_module(:cerl.abstract(:m1), [:cerl.c_fname(:f, 0)], [],
  [{:cerl.c_fname(:f, 0), :cerl.c_fun([], outer)}])

case :compile.forms(m, [:from_core, :binary]) do
  {:ok, mod, bin} ->
    :code.load_binary(mod, ~c"x", bin)
    IO.inspect(mod.f(), label: "result")
  e -> IO.inspect(e, label: "compile error", limit: 3)
end
