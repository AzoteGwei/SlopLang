%% slop_set.erl - SlopLang set methods. Sets are {'$set', Map}; methods return new sets.
-module(slop_set).
-export([add/3, discard/3, remove/3, pop/3, clear/3, copy/3, union/3,
         intersection/3, difference/3, symmetric_difference/3, issubset/3,
         issuperset/3, isdisjoint/3, update/3]).

-import(slop_rt, [raise_exc/2, iter/1, to_repr/1]).

to_map({'$set', M}) -> M;
to_map(Other) -> maps:from_list([{E, true} || E <- iter(Other)]).

add({'$set', M}, [X], _) -> {'$set', maps:put(X, true, M)};
add(_, _, _) -> raise_exc('TypeError', <<"add() takes exactly one argument">>).

discard({'$set', M}, [X], _) -> {'$set', maps:remove(X, M)};
discard(_, _, _) -> raise_exc('TypeError', <<"discard() takes exactly one argument">>).

remove({'$set', M}, [X], _) ->
    case maps:is_key(X, M) of
        true -> {'$set', maps:remove(X, M)};
        false -> raise_exc('KeyError', [to_repr(X)])
    end;
remove(_, _, _) -> raise_exc('TypeError', <<"remove() takes exactly one argument">>).

%% pop returns {NewSet, Element}
pop({'$set', M}, [], _) ->
    case maps:keys(M) of
        [] -> raise_exc('KeyError', <<"pop from an empty set">>);
        [K | _] -> {{'$set', maps:remove(K, M)}, K}
    end;
pop(_, _, _) -> raise_exc('TypeError', <<"pop() takes no arguments">>).

clear(_, [], _) -> {'$set', #{}};
clear(_, _, _) -> raise_exc('TypeError', <<"clear() takes no arguments">>).

copy({'$set', _} = S, [], _) -> S;
copy(_, _, _) -> raise_exc('TypeError', <<"copy() takes no arguments">>).

union({'$set', M}, Args, _) ->
    lists:foldl(fun(A, Acc) -> {'$set', maps:merge(Acc, to_map(A))} end,
                {'$set', M}, Args).

intersection({'$set', M}, Args, _) ->
    lists:foldl(fun(A, {'$set', Acc}) ->
                        AM = to_map(A),
                        K = [Kx || Kx <- maps:keys(Acc), maps:is_key(Kx, AM)],
                        {'$set', maps:with(K, Acc)}
                end, {'$set', M}, Args).

difference({'$set', M}, Args, _) ->
    lists:foldl(fun(A, {'$set', Acc}) ->
                        {'$set', maps:without(maps:keys(to_map(A)), Acc)}
                end, {'$set', M}, Args).

symmetric_difference({'$set', M}, [Other], _) ->
    OM = to_map(Other),
    A = maps:without(maps:keys(OM), M),
    B = maps:without(maps:keys(M), OM),
    {'$set', maps:merge(A, B)};
symmetric_difference(_, _, _) ->
    raise_exc('TypeError', <<"symmetric_difference() takes exactly one argument">>).

issubset({'$set', M}, [Other], _) ->
    OM = to_map(Other),
    lists:all(fun(K) -> maps:is_key(K, OM) end, maps:keys(M));
issubset(_, _, _) -> raise_exc('TypeError', <<"issubset() takes exactly one argument">>).

issuperset({'$set', M}, [Other], _) ->
    OM = to_map(Other),
    lists:all(fun(K) -> maps:is_key(K, M) end, maps:keys(OM));
issuperset(_, _, _) -> raise_exc('TypeError', <<"issuperset() takes exactly one argument">>).

isdisjoint({'$set', M}, [Other], _) ->
    OM = to_map(Other),
    not lists:any(fun(K) -> maps:is_key(K, OM) end, maps:keys(M));
isdisjoint(_, _, _) -> raise_exc('TypeError', <<"isdisjoint() takes exactly one argument">>).

update({'$set', M}, Args, _) ->
    union({'$set', M}, Args, #{}).
