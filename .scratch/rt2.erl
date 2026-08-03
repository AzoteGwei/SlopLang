-module(rt2).
-export([f/0]).
f() ->
  try
    try erlang:throw(ball)
    catch C1:R1:S1 -> erlang:raise(C1, R1, S1)
    end
  catch C2:R2:S2 -> erlang:raise(C2, R2, S2)
  end.
