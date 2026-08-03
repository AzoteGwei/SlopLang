-module(probe).
-export([t1/1, t2/0, t3/1, t4/0, t5/1, t6/1, t7/1]).
t1(X) ->
  try X() of
    ok -> good;
    V -> {val, V}
  catch
    throw:{exc, C, _}:ST -> {caught, C, ST};
    error:R -> {err, R}
  after
    cleanup
  end.
t2() ->
  F = fun Loop(N, Acc) when N > 0 -> Loop(N-1, [N|Acc]); Loop(_, Acc) -> Acc end,
  F(3, []).
t3(M) -> M#{a := 1, b := 2}.
t4() -> <<"abc", 1, 2:16/little>>.
t5(X) -> case X of #{a := A} -> A; [H|T] -> {H,T}; _ -> none end.
t6(X) -> begin A = X + 1, B = A * 2, {A, B} end.
t7(F) -> apply(F, [1,2]).
