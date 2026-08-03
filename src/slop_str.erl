%% slop_str.erl - SlopLang str methods. Protocol: Fun(Self :: binary(), Pos :: list(), Kw :: map()).
-module(slop_str).
-export([upper/3, lower/3, casefold/3, title/3, capitalize/3, swapcase/3,
         strip/3, lstrip/3, rstrip/3, split/3, rsplit/3, splitlines/3,
         join/3, replace/3, startswith/3, endswith/3, find/3, rfind/3,
         index/3, rindex/3, count/3, zfill/3, center/3, ljust/3, rjust/3,
         partition/3, rpartition/3, removeprefix/3, removesuffix/3,
         isdigit/3, isalpha/3, isalnum/3, isspace/3, isupper/3, islower/3,
         isnumeric/3, encode/3, format/3]).

-import(slop_rt, [raise_exc/2, iter/1, to_str/1, truthy/1]).

upper(S, _, _) -> string:uppercase(S).
lower(S, _, _) -> string:lowercase(S).
casefold(S, _, _) -> string:casefold(S).
capitalize(<<>>, _, _) -> <<>>;
capitalize(S, _, _) ->
    U = string:uppercase(S),
    L = string:lowercase(S),
    <<(hd(unicode:characters_to_list(U)))/utf8, (tl_bin(L))/binary>>.

tl_bin(B) ->
    case unicode:characters_to_list(B) of
        [] -> <<>>;
        [_ | T] -> unicode:characters_to_binary(T)
    end.

swapcase(S, _, _) ->
    unicode:characters_to_binary([swapc(C) || C <- unicode:characters_to_list(S)]).

swapc(C) ->
    Up = string:uppercase(<<C/utf8>>),
    Lo = string:lowercase(<<C/utf8>>),
    case <<C/utf8>> of
        Up -> hd(unicode:characters_to_list(Lo));
        _ -> hd(unicode:characters_to_list(Up))
    end.

title(S, _, _) ->
    Chars = unicode:characters_to_list(S),
    {Out, _} = lists:mapfoldl(fun(C, PrevAlpha) ->
        IsAlpha = is_alpha(C),
        C2 = case {PrevAlpha, IsAlpha} of
                 {false, true} -> hd(unicode:characters_to_list(string:uppercase(<<C/utf8>>)));
                 {true, true} -> hd(unicode:characters_to_list(string:lowercase(<<C/utf8>>)));
                 _ -> C
             end,
        {C2, IsAlpha}
    end, false, Chars),
    unicode:characters_to_binary(Out).

is_alpha(C) ->
    (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse
    (C >= 16#C0 andalso C =/= 16#D7 andalso C =/= 16#F7 andalso C < 16#2FF).

is_digit(C) -> C >= $0 andalso C =< $9.
is_space_c(C) -> lists:member(C, [$\s, $\t, $\n, $\r, 11, 12]).

strip(S, _, _) -> string:trim(S).
lstrip(S, _, _) -> string:trim(S, leading).
rstrip(S, _, _) -> string:trim(S, trailing).

split(S, Pos, _Kw) ->
    case Pos of
        [] -> ws_split(S, -1);
        [nil] -> ws_split(S, -1);
        [nil, Max] -> ws_split(S, Max);
        [Sep] when is_binary(Sep) -> sep_split(S, Sep, -1);
        [Sep, Max] when is_binary(Sep) -> sep_split(S, Sep, Max);
        _ -> raise_exc('TypeError', <<"split() argument must be str">>)
    end.

rsplit(S, Pos, _Kw) ->
    case Pos of
        [] -> ws_split(S, -1);
        [nil] -> ws_split(S, -1);
        [nil, Max] -> ws_rsplit(S, Max);
        [Sep] when is_binary(Sep) -> sep_split(S, Sep, -1);
        [Sep, Max] when is_binary(Sep), is_integer(Max), Max >= 0 ->
            Parts = sep_split(S, Sep, -1),
            case length(Parts) =< Max + 1 of
                true -> Parts;
                false ->
                    {Head, Tail} = lists:split(length(Parts) - Max - 1, Parts),
                    [join_bins(Head, Sep) | Tail]
            end;
        _ -> raise_exc('TypeError', <<"rsplit() argument must be str">>)
    end.

join_bins([], _Sep) -> <<>>;
join_bins([B], _Sep) -> B;
join_bins([B | Rest], Sep) -> <<B/binary, Sep/binary, (join_bins(Rest, Sep))/binary>>.

ws_split(S, Max) ->
    Trimmed = string:trim(S),
    case Trimmed of
        <<>> -> [];
        _ ->
            Parts = split_ws(Trimmed),
            apply_maxsplit_left(Parts, Max)
    end.

ws_rsplit(S, Max) when is_integer(Max), Max >= 0 ->
    Parts = ws_split(S, -1),
    case length(Parts) =< Max + 1 of
        true -> Parts;
        false ->
            {Head, Tail} = lists:split(length(Parts) - Max, Parts),
            [join_bins(Head, <<" ">>) | Tail]
    end;
ws_rsplit(S, _) -> ws_split(S, -1).

apply_maxsplit_left(Parts, -1) -> Parts;
apply_maxsplit_left(Parts, Max) when length(Parts) =< Max + 1 -> Parts;
apply_maxsplit_left(Parts, Max) ->
    {Head, Tail} = lists:split(Max, Parts),
    Head ++ [join_bins(Tail, <<" ">>)].

split_ws(S) ->
    Chars = unicode:characters_to_list(S),
    split_ws_(Chars, [], []).

split_ws_([], Cur, Acc) ->
    case Cur of
        [] -> lists:reverse(Acc);
        _ -> lists:reverse([unicode:characters_to_binary(lists:reverse(Cur)) | Acc])
    end;
split_ws_([C | Rest], Cur, Acc) ->
    case is_space_c(C) of
        true ->
            case Cur of
                [] -> split_ws_(Rest, [], Acc);
                _ -> split_ws_(Rest, [], [unicode:characters_to_binary(lists:reverse(Cur)) | Acc])
            end;
        false ->
            split_ws_(Rest, [C | Cur], Acc)
    end.

sep_split(S, Sep, Max) ->
    case Sep of
        <<>> -> raise_exc('ValueError', <<"empty separator">>);
        _ ->
            Parts = binary:split(S, Sep, [global]),
            case Max of
                -1 -> Parts;
                _ when is_integer(Max), Max >= 0 ->
                    case length(Parts) =< Max + 1 of
                        true -> Parts;
                        false ->
                            {Head, Tail} = lists:split(Max, Parts),
                            Head ++ [join_bins(Tail, Sep)]
                    end;
                _ -> raise_exc('TypeError', <<"maxsplit must be an integer">>)
            end
    end.

splitlines(S, Pos, _Kw) ->
    _Keep = case Pos of [] -> false; [K] -> truthy(K) end,
    Norm = binary:replace(S, <<"\r\n">>, <<"\n">>, [global]),
    Norm2 = binary:replace(Norm, <<"\r">>, <<"\n">>, [global]),
    case Norm2 of
        <<>> -> [];
        _ ->
            Parts = binary:split(Norm2, <<"\n">>, [global]),
            case lists:last(Parts) of
                <<>> -> lists:droplast(Parts);
                _ -> Parts
            end
    end.

join(S, [Iter], _Kw) ->
    Items = iter(Iter),
    lists:foreach(fun(I) ->
                          case is_binary(I) of
                              true -> ok;
                              false -> raise_exc('TypeError',
                                      <<"sequence item: expected str instance">>)
                          end
                  end, Items),
    join_bins(Items, S);
join(_, _, _) -> raise_exc('TypeError', <<"join() takes exactly one argument">>).

replace(S, [Old, New], _Kw) -> replace_(S, Old, New, -1);
replace(S, [Old, New, Count], _Kw) when is_integer(Count) -> replace_(S, Old, New, Count);
replace(_, _, _) -> raise_exc('TypeError', <<"replace() takes 2 or 3 arguments">>).

replace_(_S, <<>>, _New, _Count) ->
    raise_exc('ValueError', <<"empty pattern">>);
replace_(S, Old, New, -1) ->
    binary:replace(S, Old, New, [global]);
replace_(S, _Old, _New, 0) -> S;
replace_(S, Old, New, Count) when Count > 0 ->
    Parts = binary:split(S, Old, [global]),
    case length(Parts) =< Count + 1 of
        true -> join_bins(Parts, New);
        false ->
            {Head, Tail} = lists:split(Count + 1, Parts),
            join_bins(Head ++ [join_bins(Tail, Old)], New)
    end.

startswith(S, [Prefix], _Kw) -> starts_with(S, Prefix);
startswith(S, [Prefix, Start], _Kw) when is_integer(Start) ->
    starts_with(drop_chars(S, Start), Prefix);
startswith(S, [Prefix, Start, End], _Kw) when is_integer(Start), is_integer(End) ->
    Sub = take_chars(drop_chars(S, Start), End - Start),
    starts_with(Sub, Prefix);
startswith(_, _, _) -> raise_exc('TypeError', <<"startswith() takes a str or tuple of str">>).

starts_with(S, Prefix) when is_binary(Prefix) ->
    byte_size(S) >= byte_size(Prefix) andalso
        binary:part(S, 0, byte_size(Prefix)) =:= Prefix;
starts_with(S, Prefix) when is_tuple(Prefix) ->
    lists:any(fun(P) -> starts_with(S, P) end, tuple_to_list(Prefix)).

endswith(S, [Suffix], _Kw) -> ends_with(S, Suffix);
endswith(S, [Suffix, Start], _Kw) when is_integer(Start) ->
    ends_with(drop_chars(S, Start), Suffix);
endswith(_, _, _) -> raise_exc('TypeError', <<"endswith() takes a str or tuple of str">>).

ends_with(S, Suffix) when is_binary(Suffix) ->
    byte_size(S) >= byte_size(Suffix) andalso
        binary:part(S, byte_size(S) - byte_size(Suffix), byte_size(Suffix)) =:= Suffix;
ends_with(S, Suffix) when is_tuple(Suffix) ->
    lists:any(fun(P) -> ends_with(S, P) end, tuple_to_list(Suffix)).

drop_chars(S, N) when N >= 0 ->
    Chars = unicode:characters_to_list(S),
    unicode:characters_to_binary(lists:nthtail(min(N, length(Chars)), Chars));
drop_chars(S, N) ->
    Chars = unicode:characters_to_list(S),
    L = length(Chars),
    unicode:characters_to_binary(lists:nthtail(max(L + N, 0), Chars)).

take_chars(S, N) when N >= 0 ->
    Chars = unicode:characters_to_list(S),
    unicode:characters_to_binary(lists:sublist(Chars, N));
take_chars(_, _) -> <<>>.

find(S, [Sub], _Kw) when is_binary(Sub) -> find_(S, Sub);
find(S, [Sub, Start], _Kw) when is_binary(Sub), is_integer(Start) ->
    case find_(drop_chars(S, Start), Sub) of
        -1 -> -1;
        I -> I + char_offset(S, Start)
    end;
find(_, _, _) -> raise_exc('TypeError', <<"find() takes a str argument">>).

find_(S, Sub) ->
    case binary:match(S, Sub) of
        nomatch -> -1;
        {Pos, _} -> char_count(binary:part(S, 0, Pos))
    end.

char_count(B) -> length(unicode:characters_to_list(B)).
char_offset(_S, Start) when Start >= 0 -> Start;
char_offset(S, Start) -> max(char_count(S) + Start, 0).

rfind(S, [Sub], _Kw) when is_binary(Sub) ->
    case binary:matches(S, Sub) of
        [] -> -1;
        Ms -> {Pos, _} = lists:last(Ms), char_count(binary:part(S, 0, Pos))
    end;
rfind(_, _, _) -> raise_exc('TypeError', <<"rfind() takes a str argument">>).

index(S, [Sub], Kw) ->
    case find(S, [Sub], Kw) of
        -1 -> raise_exc('ValueError', <<"substring not found">>);
        I -> I
    end;
index(_, _, _) -> raise_exc('TypeError', <<"index() takes a str argument">>).

rindex(S, [Sub], Kw) ->
    case rfind(S, [Sub], Kw) of
        -1 -> raise_exc('ValueError', <<"substring not found">>);
        I -> I
    end;
rindex(_, _, _) -> raise_exc('TypeError', <<"rindex() takes a str argument">>).

count(S, [Sub], _Kw) when is_binary(Sub) ->
    case Sub of
        <<>> -> char_count(S) + 1;
        _ -> length(binary:matches(S, Sub))
    end;
count(_, _, _) -> raise_exc('TypeError', <<"count() takes a str argument">>).

zfill(S, [Width], _Kw) when is_integer(Width) ->
    Len = char_count(S),
    case Len >= Width of
        true -> S;
        false ->
            Pad = Width - Len,
            case S of
                <<Sign, Rest/binary>> when Sign =:= $+; Sign =:= $- ->
                    <<Sign, (binary:copy(<<"0">>, Pad))/binary, Rest/binary>>;
                _ ->
                    <<(binary:copy(<<"0">>, Pad))/binary, S/binary>>
            end
    end;
zfill(_, _, _) -> raise_exc('TypeError', <<"zfill() takes an integer">>).

center(S, Pos, _Kw) -> pad_to(S, Pos, center).
ljust(S, Pos, _Kw) -> pad_to(S, Pos, left).
rjust(S, Pos, _Kw) -> pad_to(S, Pos, right).

pad_to(S, [Width], Mode) -> pad_to(S, [Width, <<" ">>], Mode);
pad_to(S, [Width, Fill], Mode) when is_integer(Width), is_binary(Fill) ->
    Len = char_count(S),
    case Len >= Width of
        true -> S;
        false ->
            Pad = Width - Len,
            case Mode of
                left -> <<S/binary, (binary:copy(Fill, Pad))/binary>>;
                right -> <<(binary:copy(Fill, Pad))/binary, S/binary>>;
                center ->
                    L = Pad div 2,
                    R = Pad - L,
                    <<(binary:copy(Fill, L))/binary, S/binary, (binary:copy(Fill, R))/binary>>
            end
    end;
pad_to(_, _, _) -> raise_exc('TypeError', <<"padding requires integer width and str fill">>).

partition(S, [Sep], _Kw) when is_binary(Sep), Sep =/= <<>> ->
    case binary:match(S, Sep) of
        nomatch -> {S, <<>>, <<>>};
        {Pos, Len} ->
            Before = binary:part(S, 0, Pos),
            After = binary:part(S, Pos + Len, byte_size(S) - Pos - Len),
            {Before, Sep, After}
    end;
partition(_, _, _) -> raise_exc('ValueError', <<"empty separator">>).

rpartition(S, [Sep], _Kw) when is_binary(Sep), Sep =/= <<>> ->
    case binary:matches(S, Sep) of
        [] -> {<<>>, <<>>, S};
        Ms ->
            {Pos, Len} = lists:last(Ms),
            Before = binary:part(S, 0, Pos),
            After = binary:part(S, Pos + Len, byte_size(S) - Pos - Len),
            {Before, Sep, After}
    end;
rpartition(_, _, _) -> raise_exc('ValueError', <<"empty separator">>).

removeprefix(S, [Prefix], _Kw) when is_binary(Prefix) ->
    case starts_with(S, Prefix) of
        true -> binary:part(S, byte_size(Prefix), byte_size(S) - byte_size(Prefix));
        false -> S
    end;
removeprefix(_, _, _) -> raise_exc('TypeError', <<"removeprefix() takes a str">>).

removesuffix(S, [Suffix], _Kw) when is_binary(Suffix) ->
    case Suffix =/= <<>> andalso ends_with(S, Suffix) of
        true -> binary:part(S, 0, byte_size(S) - byte_size(Suffix));
        false -> S
    end;
removesuffix(_, _, _) -> raise_exc('TypeError', <<"removesuffix() takes a str">>).

isdigit(<<>>, _, _) -> false;
isdigit(S, _, _) -> lists:all(fun is_digit/1, unicode:characters_to_list(S)).

isalpha(<<>>, _, _) -> false;
isalpha(S, _, _) -> lists:all(fun is_alpha/1, unicode:characters_to_list(S)).

isalnum(<<>>, _, _) -> false;
isalnum(S, _, _) ->
    lists:all(fun(C) -> is_alpha(C) orelse is_digit(C) end, unicode:characters_to_list(S)).

isspace(<<>>, _, _) -> false;
isspace(S, _, _) -> lists:all(fun is_space_c/1, unicode:characters_to_list(S)).

isupper(S, _, _) ->
    Chars = unicode:characters_to_list(S),
    Cased = [C || C <- Chars, is_alpha(C)],
    Cased =/= [] andalso
        lists:all(fun(C) -> <<C/utf8>> =:= string:uppercase(<<C/utf8>>) end, Cased).

islower(S, _, _) ->
    Chars = unicode:characters_to_list(S),
    Cased = [C || C <- Chars, is_alpha(C)],
    Cased =/= [] andalso
        lists:all(fun(C) -> <<C/utf8>> =:= string:lowercase(<<C/utf8>>) end, Cased).

isnumeric(<<>>, _, _) -> false;
isnumeric(S, _, _) -> lists:all(fun is_digit/1, unicode:characters_to_list(S)).

encode(S, _, _) -> S.

%% str.format: {}, {0}, {name}, {{, }}, with :spec after
format(S, Pos, Kw) ->
    format_(S, Pos, Kw, 0, []).

format_(<<>>, _Pos, _Kw, _Auto, Acc) -> iolist_to_binary(lists:reverse(Acc));
format_(<<"{{", Rest/binary>>, Pos, Kw, Auto, Acc) ->
    format_(Rest, Pos, Kw, Auto, [<<"{">> | Acc]);
format_(<<"}}", Rest/binary>>, Pos, Kw, Auto, Acc) ->
    format_(Rest, Pos, Kw, Auto, [<<"}">> | Acc]);
format_(<<"{", Rest/binary>>, Pos, Kw, Auto, Acc) ->
    case binary:match(Rest, <<"}">>) of
        nomatch -> raise_exc('ValueError', <<"single '{' in format string">>);
        {Idx, 1} ->
            Field = binary:part(Rest, 0, Idx),
            After = binary:part(Rest, Idx + 1, byte_size(Rest) - Idx - 1),
            {V, Auto2} = format_field(Field, Pos, Kw, Auto),
            format_(After, Pos, Kw, Auto2, [V | Acc])
    end;
format_(<<C, Rest/binary>>, Pos, Kw, Auto, Acc) ->
    format_(Rest, Pos, Kw, Auto, [<<C>> | Acc]).

format_field(Field, Pos, Kw, Auto) ->
    {Name, Spec} = case binary:split(Field, <<":">>) of
                       [N, Sp] -> {N, Sp};
                       [N] -> {N, <<>>}
                   end,
    case Name of
        <<>> ->
            case Auto < length(Pos) of
                true -> {slop_rt:format_spec(lists:nth(Auto + 1, Pos), Spec), Auto + 1};
                false -> raise_exc('IndexError', <<"replacement index out of range">>)
            end;
        _ ->
            V = case catch binary_to_integer(Name) of
                    I when is_integer(I), I >= 0, I < length(Pos) ->
                        lists:nth(I + 1, Pos);
                    _ ->
                        case maps:find(binary_to_atom(Name, utf8), Kw) of
                            {ok, Kv} -> Kv;
                            error -> raise_exc('KeyError', [Name])
                        end
                end,
            {slop_rt:format_spec(V, Spec), Auto}
    end.
