-module(call_out).
-export([main/0]).
main() ->
    io:format("double: ~p~n", [out:double([21], #{})]),
    io:format("greet default: ~p~n", [out:greet([<<"beam">>], #{})]),
    Kw = #{punct => <<"?">>},
    io:format("greet kw: ~p~n", [out:greet([<<"bob">>], Kw)]),
    P = slop_rt:instantiate('out.Point', [3, 4], #{}),
    io:format("Point.sum: ~p~n", [out:'out.Point.sum'([P], #{}, {})]),
    init:stop().
