#!/usr/bin/env escript
%%! -pa .scratch
main(_) ->
    io:format("~p~n", [slop_rt:binop("+", 1, 2)]),                    % 3
    io:format("~p~n", [slop_rt:binop("+", <<"a">>, <<"b">>)]),        % ab
    io:format("~p~n", [slop_rt:binop("//", -7, 2)]),                  % -4
    io:format("~p~n", [slop_rt:binop("%", -7, 2)]),                   % 1
    io:format("~p~n", [slop_rt:binop("**", 2, 10)]),                  % 1024
    io:format("~p~n", [slop_rt:getitem([1,2,3], -1)]),                % 3
    io:format("~p~n", [slop_rt:slice([1,2,3,4,5], 1, 4, nil)]),       % [2,3,4]
    io:format("~p~n", [slop_rt:slice(<<"hello">>, nil, nil, -1)]),    % olleh
    io:format("~p~n", [slop_rt:to_str([1, <<"a">>, nil, {1,2}])]),    % [1, 'a', None, (1, 2)]
    io:format("~p~n", [slop_rt:to_str(#{a => 1})]),
    io:format("~p~n", [slop_rt:to_str({'$set', #{1 => true, 2 => true}})]),
    io:format("~p~n", [slop_rt:eq([1, 2.0], [1, 2])]),                % true
    io:format("~p~n", [slop_rt:range([1, 10, 3], #{})]),              % [1,4,7]
    io:format("~p~n", [slop_rt:format_spec(3.14159, <<".2f">>)]),
    io:format("~p~n", [slop_rt:format_spec(255, <<"08x">>)]),
    io:format("~p~n", [slop_rt:format_spec(<<"hi">>, <<"*>6">>)]),
    io:format("~p~n", [slop_rt:unpack([1,2,3], [name, name, name])]),
    io:format("~p~n", [slop_rt:unpack([1,2,3,4,5], [name, {'star'}, name])]),
    Spec = #{pos => [{a, false}, {b, true}], vararg => c, kwonly => [{d, true}], kwarg => e},
    io:format("~p~n", [slop_rt:bind_params(Spec, {99, 88}, [1, 2, 3, 4], #{})]),
    io:format("~p~n", [slop_rt:bind_params(Spec, {99, 88}, [1], #{d => 7, z => 9})]),
    C = slop_rt:defclass('test.Point', ['object'], #{'__add__' => fun([Self, Other], _) -> maps:get(x, Self) + maps:get(x, Other) end}, #{}),
    Obj = #{'$class' => C, x => 41},
    io:format("~p~n", [slop_rt:binop("+", Obj, Obj)]),                % 82
    io:format("~p~n", [catch slop_rt:binop("<", Obj, 1)]),
    io:format("~p~n", [catch slop_rt:getitem(Obj, 1)]),
    io:format("~p~n", [slop_rt:print_exc('ValueError', #{'$class' => 'ValueError', args => [<<"bad">>]})]),
    ok.
