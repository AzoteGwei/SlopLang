%% slop_list.erl - SlopLang list methods. All return NEW lists (immutable semantics).
-module(slop_list).
-export([append/3, insert/3, remove/3, pop/3, clear/3, index/3, count/3,
         extend/3, reverse/3, sort/3, copy/3]).

-import(slop_rt, [raise_exc/2, iter/1, eq/2]).

append(L, [X], _) -> L ++ [X];
append(_, _, _) -> raise_exc('TypeError', <<"append() takes exactly one argument">>).

insert(L, [I, X], _) when is_integer(I) ->
    N = length(L),
    J = if I < 0 -> max(N + I, 0); true -> min(I, N) end,
    {A, B} = lists:split(J, L),
    A ++ [X] ++ B;
insert(_, _, _) -> raise_exc('TypeError', <<"insert() takes an integer and a value">>).

remove(L, [X], _) ->
    case remove_first(L, X) of
        {ok, New} -> New;
        error -> raise_exc('ValueError', <<"list.remove(x): x not in list">>)
    end;
remove(_, _, _) -> raise_exc('TypeError', <<"remove() takes exactly one argument">>).

remove_first([], _X) -> error;
remove_first([H | T], X) ->
    case eq(H, X) of
        true -> {ok, T};
        false ->
            case remove_first(T, X) of
                {ok, New} -> {ok, [H | New]};
                error -> error
            end
    end.

%% pop returns {NewList, Element} - the honest immutable version of list.pop
pop(L, [], _) -> pop_(L, length(L) - 1);
pop(L, [I], _) when is_integer(I) ->
    N = length(L),
    J = if I < 0 -> I + N; true -> I end,
    pop_(L, J);
pop(_, _, _) -> raise_exc('TypeError', <<"pop() takes at most one integer argument">>).

pop_(L, J) ->
    N = length(L),
    case J >= 0 andalso J < N of
        true ->
            {A, [E | B]} = lists:split(J, L),
            {A ++ B, E};
        false ->
            case N of
                0 -> raise_exc('IndexError', <<"pop from empty list">>);
                _ -> raise_exc('IndexError', <<"pop index out of range">>)
            end
    end.

clear(_, [], _) -> [];
clear(_, _, _) -> raise_exc('TypeError', <<"clear() takes no arguments">>).

index(L, [X], _) -> index_(L, X, 0);
index(L, [X, Start], _) when is_integer(Start) ->
    N = length(L),
    J = if Start < 0 -> max(N + Start, 0); true -> min(Start, N) end,
    Sub = lists:nthtail(J, L),
    case index_from(Sub, X, 0) of
        -1 -> raise_exc('ValueError', <<"value is not in list">>);
        I -> J + I
    end;
index(_, _, _) -> raise_exc('TypeError', <<"index() takes 1 or 2 arguments">>).

index_(L, X, Off) ->
    case index_from(L, X, Off) of
        -1 -> raise_exc('ValueError', <<"value is not in list">>);
        I -> I
    end.

index_from([], _X, _) -> -1;
index_from([H | T], X, I) ->
    case eq(H, X) of
        true -> I;
        false -> index_from(T, X, I + 1)
    end.

count(L, [X], _) ->
    length([ok || E <- L, eq(E, X)]);
count(_, _, _) -> raise_exc('TypeError', <<"count() takes exactly one argument">>).

extend(L, [It], _) -> L ++ iter(It);
extend(_, _, _) -> raise_exc('TypeError', <<"extend() takes exactly one argument">>).

reverse(L, [], _) -> lists:reverse(L);
reverse(_, _, _) -> raise_exc('TypeError', <<"reverse() takes no arguments">>).

sort(L, _, Kw) -> slop_rt:sorted_(L, Kw).

copy(L, [], _) -> L;
copy(_, _, _) -> raise_exc('TypeError', <<"copy() takes no arguments">>).
