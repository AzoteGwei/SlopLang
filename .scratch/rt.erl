-module(rt).
-export([f/0]).
f() ->
  try erlang:throw(ball)
  catch C:R:S -> erlang:raise(C, R, S)
  end.
