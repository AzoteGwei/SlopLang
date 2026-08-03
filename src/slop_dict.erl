%% slop_dict.erl - SlopLang dict methods. "Mutating" methods return NEW dicts.
-module(slop_dict).
-export([get/3, keys/3, values/3, items/3, pop/3, update/3, clear/3,
         setdefault/3, copy/3, popitem/3]).

-import(slop_rt, [raise_exc/2, to_repr/1]).

get(D, [K], _) -> maps:get(K, D, nil);
get(D, [K, Default], _) -> maps:get(K, D, Default);
get(_, _, _) -> raise_exc('TypeError', <<"get() takes 1 or 2 arguments">>).

keys(D, [], _) -> maps:keys(D);
keys(_, _, _) -> raise_exc('TypeError', <<"keys() takes no arguments">>).

values(D, [], _) -> maps:values(D);
values(_, _, _) -> raise_exc('TypeError', <<"values() takes no arguments">>).

items(D, [], _) -> [{K, V} || {K, V} <- maps:to_list(D)];
items(_, _, _) -> raise_exc('TypeError', <<"items() takes no arguments">>).

%% pop returns {NewDict, Value} - the honest immutable version of dict.pop
pop(D, [K], _) ->
    case maps:take(K, D) of
        {V, New} -> {New, V};
        error -> raise_exc('KeyError', [to_repr(K)])
    end;
pop(D, [K, Default], _) ->
    case maps:take(K, D) of
        {V, New} -> {New, V};
        error -> {D, Default}
    end;
pop(_, _, _) -> raise_exc('TypeError', <<"pop() takes 1 or 2 arguments">>).

%% setdefault returns {NewDict, Value}
setdefault(D, [K], _) -> setdefault(D, [K, nil], #{});
setdefault(D, [K, Default], _) ->
    case maps:find(K, D) of
        {ok, V} -> {D, V};
        error -> {maps:put(K, Default, D), Default}
    end;
setdefault(_, _, _) -> raise_exc('TypeError', <<"setdefault() takes 1 or 2 arguments">>).

update(D, Pos, Kw) ->
    M0 = case Pos of
             [] -> D;
             [Other] when is_map(Other) ->
                 case Other of
                     #{'$class' := _} ->
                         raise_exc('TypeError', <<"update() argument must be a mapping">>);
                     _ -> maps:merge(D, Other)
                 end;
             [Pairs] -> maps:merge(D, slop_rt:to_dict(Pairs));
             _ -> raise_exc('TypeError', <<"update() takes at most 1 argument">>)
         end,
    maps:merge(M0, Kw).

clear(_, [], _) -> #{};
clear(_, _, _) -> raise_exc('TypeError', <<"clear() takes no arguments">>).

copy(D, [], _) -> D;
copy(_, _, _) -> raise_exc('TypeError', <<"copy() takes no arguments">>).

%% popitem returns {NewDict, {Key, Value}}
popitem(D, [], _) ->
    case maps:to_list(D) of
        [] -> raise_exc('KeyError', <<"popitem(): dictionary is empty">>);
        [{K, V} | _] -> {maps:remove(K, D), {K, V}}
    end;
popitem(_, _, _) -> raise_exc('TypeError', <<"popitem() takes no arguments">>).
