%% slop_tuple.erl - SlopLang tuple methods.
-module(slop_tuple).
-export([count/3, index/3]).

-import(slop_rt, [raise_exc/2, eq/2]).

count(T, [X], _) ->
    length([ok || E <- tuple_to_list(T), eq(E, X)]);
count(_, _, _) -> raise_exc('TypeError', <<"count() takes exactly one argument">>).

index(T, [X], _) -> index_(tuple_to_list(T), X, 0);
index(_, _, _) -> raise_exc('TypeError', <<"index() takes exactly one argument">>).

index_([], _X, _) -> raise_exc('ValueError', <<"tuple.index(x): x not in tuple">>);
index_([H | T], X, I) ->
    case eq(H, X) of
        true -> I;
        false -> index_(T, X, I + 1)
    end.
