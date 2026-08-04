%% slop_rt.erl - SlopLang runtime core (0BSD).
%%
%% Value representation on the BEAM:
%%   int     -> integer()          float -> float()
%%   str     -> binary() (UTF-8)   bool  -> true | false
%%   None    -> nil                list  -> list()
%%   tuple   -> tuple()            dict  -> map()
%%   set     -> {'$set', #{Elem => true}}
%%   class   -> atom (fully qualified, e.g. 'mymod.Point' or builtin 'ValueError')
%%   object  -> map with key '$class' => ClassAtom, other keys = attributes
%%   module  -> atom (the BEAM module name)
%%   function -> fun(PosArgs :: list(), KwArgs :: map())
%%   bound method -> {'$bound', Fun, Self}
%%   builtin-type bound method -> {'$tbound', Module, FunName, Self}
%%   static method -> {'$static', Fun}
%%   super proxy -> {'$super', Class, Self}
%%   slice  -> {'$slice', Lo, Hi, Step}
%%   file   -> {'$slop_file', IoDevice}
%%
%% Raised SlopLang exceptions are thrown as {'$slop_exc', Class, Instance}.
-module(slop_rt).

%% core ops used by generated code
-export([invoke/3, call_method/4, getattr/2, getattr/3, setattr/3, delattr/2,
         rebind/2,
         getitem/2, setitem/3, delitem/2, slice/4,
         binop/3, unary/2, truthy/1, eq/2, cmp/3, contains/2, iter/1,
         to_str/1, to_repr/1, raise_exc/2, raise_exc/1,
         exc_matches/2, map_erlang_error/2, bind_params/4, unpack/2,
         defclass/4, instantiate/3, mro/1, is_slop_class/1,
         global_get/2, global_set/3, global_del/2, module_ensure_init/1, sorted_/2,
         raise_any/1, normalize_exc/2, pattern_match/2, rethrow/3,
         get_builtin/1, builtins/0, builtin_classes/0,
         with_enter/1, with_exit/2, format_spec/2, super_proxy/2,
         set_argv/1, exc_class_name/1, print_exc/2]).

%% builtins (all take (PosArgs, KwArgs))
-export([atom/2, erl_mod/1, kw_from_dict/1,
         spawn_task/2, join/2, sleep/2, send_msg/2, recv_msg/2, self_pid/2, monotonic/2,
         print/2, len/2, str/2, repr/2, int/2, float/2, bool/2, list/2,
         tuple/2, dict/2, set/2, range/2, enumerate/2, zip/2, map/2,
         filter/2, sorted/2, reversed/2, sum/2, min/2, max/2, abs/2,
         all/2, any/2, chr/2, ord/2, hex/2, oct/2, bin/2, round/2,
         divmod/2, pow/2, hash/2, id/2, callable/2, hasattr/2,
         getattr_wrap/2, setattr_wrap/2, isinstance/2, issubclass/2,
         type/2, input/2, open/2, argv/2, exit/2, frozenset/2]).

-define(NIL, nil).

%% guard-safe check for internal tagged tuples (sets, bound methods, ...)
-define(TAGGED(T), (is_tuple(T) andalso tuple_size(T) > 0 andalso
    (element(1, T) =:= '$set' orelse element(1, T) =:= '$bound' orelse
     element(1, T) =:= '$tbound' orelse element(1, T) =:= '$static' orelse
     element(1, T) =:= '$classmeth' orelse element(1, T) =:= '$super' orelse
     element(1, T) =:= '$slice' orelse element(1, T) =:= '$slop_file'))).

%%====================================================================
%% Exceptions
%%====================================================================

exc_bases('BaseException') -> [];
exc_bases('Exception') -> ['BaseException'];
exc_bases('ArithmeticError') -> ['Exception'];
exc_bases('ZeroDivisionError') -> ['ArithmeticError'];
exc_bases('LookupError') -> ['Exception'];
exc_bases('IndexError') -> ['LookupError'];
exc_bases('KeyError') -> ['LookupError'];
exc_bases('ValueError') -> ['Exception'];
exc_bases('TypeError') -> ['Exception'];
exc_bases('RuntimeError') -> ['Exception'];
exc_bases('AttributeError') -> ['Exception'];
exc_bases('NameError') -> ['Exception'];
exc_bases('UnboundLocalError') -> ['NameError'];
exc_bases('StopIteration') -> ['Exception'];
exc_bases('NotImplementedError') -> ['RuntimeError'];
exc_bases('OSError') -> ['Exception'];
exc_bases('FileNotFoundError') -> ['OSError'];
exc_bases('AssertionError') -> ['Exception'];
exc_bases('ImportError') -> ['Exception'];
exc_bases('EOFError') -> ['Exception'];
exc_bases(_) -> unknown.

builtin_exception_classes() ->
    ['BaseException', 'Exception', 'ArithmeticError', 'ZeroDivisionError',
     'LookupError', 'IndexError', 'KeyError', 'ValueError', 'TypeError',
     'RuntimeError', 'AttributeError', 'NameError', 'UnboundLocalError',
     'StopIteration', 'NotImplementedError', 'OSError', 'FileNotFoundError',
     'AssertionError', 'ImportError', 'EOFError'].

builtin_type_classes() ->
    ['int', 'float', 'str', 'bool', 'list', 'tuple', 'dict', 'set',
     'frozenset', 'object', 'function', 'module', 'NoneType'].

builtin_classes() -> builtin_exception_classes() ++ builtin_type_classes().

is_builtin_exception(C) -> lists:member(C, builtin_exception_classes()).

is_exception_class(C) ->
    is_builtin_exception(C) orelse
        (is_slop_class(C) andalso lists:member('Exception', mro(C))).

-spec raise_exc(atom(), term()) -> no_return().
raise_exc(Class, Msg) when is_binary(Msg) ->
    throw({'$slop_exc', Class, #{'$class' => Class, args => [Msg]}});
raise_exc(Class, Args) when is_list(Args) ->
    throw({'$slop_exc', Class, #{'$class' => Class, args => Args}});
raise_exc(Class, Msg) ->
    raise_exc(Class, to_str(Msg)).

-spec raise_exc(atom()) -> no_return().
raise_exc(Class) ->
    throw({'$slop_exc', Class, #{'$class' => Class, args => []}}).

exc_class_name(Class) when is_atom(Class) ->
    L = atom_to_list(Class),
    case string:split(L, ".", trailing) of
        [_, Name] -> list_to_binary(Name);
        _ -> list_to_binary(L)
    end.

%% Does thrown class match any of the except-clause classes?
exc_matches(_Class, []) -> false;
exc_matches(Class, [C | Rest]) ->
    case lists:member(C, mro(Class)) of
        true -> true;
        false -> exc_matches(Class, Rest)
    end.

map_erlang_error(error, badarg) -> {'TypeError', [<<"bad argument">>]};
map_erlang_error(error, function_clause) -> {'TypeError', [<<"bad argument (no matching clause)">>]};
map_erlang_error(error, badarith) -> {'ArithmeticError', [<<"bad arithmetic">>]};
map_erlang_error(error, {badkey, K}) -> {'KeyError', [to_repr(K)]};
map_erlang_error(error, {badmap, V}) -> {'TypeError', [<<"not a mapping: ", (to_repr(V))/binary>>]};
map_erlang_error(error, {case_clause, V}) -> {'RuntimeError', [<<"no case clause matched: ", (to_repr(V))/binary>>]};
map_erlang_error(error, {badmatch, V}) -> {'RuntimeError', [<<"no match: ", (to_repr(V))/binary>>]};
map_erlang_error(error, noproc) -> {'RuntimeError', [<<"no such process">>]};
map_erlang_error(error, system_limit) -> {'RuntimeError', [<<"system limit reached">>]};
map_erlang_error(error, enomem) -> {'RuntimeError', [<<"out of memory">>]};
map_erlang_error(error, R) when is_atom(R) ->
    {'RuntimeError', [atom_to_binary(R, utf8)]};
map_erlang_error(error, R) ->
    {'RuntimeError', [to_repr(R)]};
map_erlang_error(throw, {'$slop_exc', _, _} = E) -> E;
map_erlang_error(throw, R) -> {'RuntimeError', [<<"uncaught throw: ", (to_repr(R))/binary>>]};
map_erlang_error(exit, R) -> {'RuntimeError', [<<"exit: ", (to_repr(R))/binary>>]}.

%% Normalize any BEAM exception into {SlopClass, Instance} for except handling.
rethrow(C, R, ST) -> erlang:raise(C, R, ST).

normalize_exc(throw, {'$slop_exc', Class, Instance}) -> {Class, Instance};
normalize_exc(Class, Reason) ->
    case map_erlang_error(Class, Reason) of
        {'$slop_exc', C, I} -> {C, I};
        {C, Args} -> {C, #{'$class' => C, args => Args}}
    end.

%% raise statement: accept a class (atom) or an exception instance.
raise_any(E) when is_atom(E) ->
    case is_exception_class(E) orelse is_slop_class(E) of
        true ->
            case is_exception_class(E) of
                true -> throw({'$slop_exc', E, instantiate(E, [], #{})});
                false -> raise_exc('TypeError',
                        <<"exceptions must derive from BaseException">>)
            end;
        false ->
            raise_exc('TypeError', <<"exceptions must derive from BaseException">>)
    end;
raise_any(E) when is_map(E) ->
    case E of
        #{'$class' := C} ->
            case is_exception_class(C) of
                true -> throw({'$slop_exc', C, E});
                false -> raise_exc('TypeError',
                        <<"exceptions must derive from BaseException">>)
            end;
        _ ->
            raise_exc('TypeError', <<"exceptions must derive from BaseException">>)
    end;
raise_any(_) ->
    raise_exc('TypeError', <<"exceptions must derive from BaseException">>).

global_del(Mod, Name) ->
    case persistent_term:get({slop_mod, Mod}, undefined) of
        M when is_map(M) ->
            persistent_term:put({slop_mod, Mod}, maps:remove(Name, M)),
            ?NIL;
        _ -> ?NIL
    end.

%%====================================================================
%% Structural pattern matching (match statement)
%%====================================================================
%%
%% Spec forms (plain data built by generated code):
%%   {lit, V} | {capture} | {wild} | {value, V}
%%   {seq, [Spec], StarIdx | nil, list | tuple}
%%   {map, [{KeySpec, Spec}], HasRest}
%%   {class, ClassAtom, [{AttrName, Spec}]}
%%   {or, [Spec]} | {as, Spec}
%% Returns {ok, [BoundValuesInTraversalOrder]} | fail.

pattern_match(Spec, Val) ->
    case pm(Spec, Val) of
        {ok, Bs} -> {ok, Bs};
        fail -> fail
    end.

pm({lit, V}, Val) ->
    case eq(V, Val) of true -> {ok, []}; false -> fail end;
pm({capture}, Val) -> {ok, [Val]};
pm({wild}, _Val) -> {ok, []};
pm({value, V}, Val) ->
    case eq(V, Val) of true -> {ok, []}; false -> fail end;
pm({seq, Specs, StarIdx, Tag}, Val) ->
    case seq_view(Val) of
        fail -> fail;
        {ok, List} ->
            case Tag of
                tuple ->
                    case is_tuple(Val) andalso (not ?TAGGED(Val)) of
                        true -> pm_seq(Specs, StarIdx, List);
                        false -> fail
                    end;
                list ->
                    case is_list(Val) of
                        true -> pm_seq(Specs, StarIdx, List);
                        false -> fail
                    end
            end
    end;
pm({map, KeySpecs, HasRest}, Val) when is_map(Val) ->
    case maps:is_key('$class', Val) of
        true -> fail;
        false -> pm_map(KeySpecs, HasRest, Val)
    end;
pm({map, _, _}, _) -> fail;
pm({class, Class, AttrSpecs}, Val) ->
    case isinstance_(Val, Class) of
        false -> fail;
        true -> pm_class_attrs(AttrSpecs, Val)
    end;
pm({'or', Specs}, Val) -> pm_or(Specs, Val);
pm({as, Sub}, Val) ->
    case pm(Sub, Val) of
        {ok, Bs} -> {ok, Bs ++ [Val]};
        fail -> fail
    end.

seq_view(V) when is_list(V) -> {ok, V};
seq_view(V) when is_tuple(V), (not ?TAGGED(V)) -> {ok, tuple_to_list(V)};
seq_view(_) -> fail.

pm_seq(Specs, nil, List) ->
    case length(Specs) =:= length(List) of
        false -> fail;
        true -> pm_seq_all(Specs, List)
    end;
pm_seq(Specs, StarIdx, List) ->
    NPre = StarIdx,
    NPost = length(Specs) - StarIdx - 1,
    N = length(List),
    case N < NPre + NPost of
        true -> fail;
        false ->
            PreSpecs = lists:sublist(Specs, NPre),
            PostSpecs = lists:nthtail(StarIdx + 1, Specs),
            PreVals = lists:sublist(List, NPre),
            StarVals = lists:sublist(List, NPre + 1, N - NPre - NPost),
            PostVals = lists:nthtail(N - NPost, List),
            case pm_seq_all(PreSpecs, PreVals) of
                fail -> fail;
                {ok, Bs1} ->
                    case pm_seq_all(PostSpecs, PostVals) of
                        fail -> fail;
                        {ok, Bs2} -> {ok, Bs1 ++ [StarVals] ++ Bs2}
                    end
            end
    end.

pm_seq_all([], []) -> {ok, []};
pm_seq_all([S | Ss], [V | Vs]) ->
    case pm(S, V) of
        fail -> fail;
        {ok, Bs} ->
            case pm_seq_all(Ss, Vs) of
                fail -> fail;
                {ok, Rest} -> {ok, Bs ++ Rest}
            end
    end.

pm_map(KeySpecs, HasRest, Val) ->
    case pm_map_keys(KeySpecs, Val, [], []) of
        fail -> fail;
        {ok, Bs, UsedKeys} ->
            case HasRest of
                true ->
                    Rest = maps:without(UsedKeys, Val),
                    {ok, Bs ++ [Rest]};
                false ->
                    {ok, Bs}
            end
    end.

pm_map_keys([], _Val, BsAcc, UsedAcc) ->
    {ok, lists:reverse(BsAcc), lists:reverse(UsedAcc)};
pm_map_keys([{{key, K}, Sub} | Rest], Val, BsAcc, UsedAcc) ->
    case maps:find(K, Val) of
        error -> fail;
        {ok, V} ->
            case pm(Sub, V) of
                fail -> fail;
                {ok, Bs} ->
                    pm_map_keys(Rest, Val, lists:reverse(Bs) ++ BsAcc, [K | UsedAcc])
            end
    end.

pm_class_attrs(AttrSpecs, Val) ->
    pm_class_attrs_(AttrSpecs, Val, []).

pm_class_attrs_([], _Val, Acc) -> {ok, lists:reverse(Acc)};
pm_class_attrs_([{Name, Sub} | Rest], Val, Acc) ->
    AttrVal = try
        getattr(Val, Name)
    catch
        _:_ -> '$__pm_fail__'
    end,
    case AttrVal of
        '$__pm_fail__' -> fail;
        _ ->
            case pm(Sub, AttrVal) of
                fail -> fail;
                {ok, Bs} -> pm_class_attrs_(Rest, Val, lists:reverse(Bs) ++ Acc)
            end
    end.

pm_or([], _Val) -> fail;
pm_or([S | Ss], Val) ->
    case pm(S, Val) of
        fail -> pm_or(Ss, Val);
        {ok, Bs} -> {ok, Bs}
    end.

print_exc(Class, Instance) ->
    Name = exc_class_name(Class),
    Msg = case Instance of
              #{args := Args} ->
                  case Args of
                      [] -> "";
                      [A] -> to_str(A);
                      _ -> to_repr(list_to_tuple(Args))
                  end;
              _ -> ""
          end,
    case Msg of
        "" -> iolist_to_binary(["SlopError: ", Name]);
        _ -> iolist_to_binary(["SlopError: ", Name, ": ", Msg])
    end.

%%====================================================================
%% Classes
%%====================================================================

-spec defclass(atom(), [atom()], map(), map()) -> atom().
defclass(Class, Bases, Methods, Attrs) ->
    persistent_term:put({slop_class, Class},
                        #{bases => Bases, methods => Methods, attrs => Attrs}),
    Class.

is_slop_class(C) when is_atom(C) ->
    persistent_term:get({slop_class, C}, undefined) =/= undefined;
is_slop_class(_) -> false.

class_info(C) -> persistent_term:get({slop_class, C}, undefined).

-spec mro(atom()) -> [atom()].
mro('object') -> ['object'];
mro(C) ->
    case is_builtin_exception(C) of
        true -> [C | chain_exc(exc_bases(C))];
        false ->
            case lists:member(C, builtin_type_classes()) of
                true -> [C, 'object'];
                false ->
                    case class_info(C) of
                        undefined -> [C, 'object'];
                        #{bases := Bases} -> [C | merge_bases(Bases)]
                    end
            end
    end.

chain_exc([]) -> [];
chain_exc([B | _]) -> [B | chain_exc(exc_bases(B))].

merge_bases(Bases) ->
    Lists = [mro(B) || B <- Bases],
    dedup(lists:append(Lists) ++ ['object']).

dedup(L) -> dedup(L, #{}).
dedup([], _) -> [];
dedup([H | T], Seen) ->
    case maps:is_key(H, Seen) of
        true -> dedup(T, Seen);
        false -> [H | dedup(T, Seen#{H => true})]
    end.

%% look up a method through the MRO; returns {ok, Val} | error
method_lookup(Class, Name) ->
    method_lookup_(mro(Class), Name).

method_lookup_([], _Name) -> error;
method_lookup_([C | Rest], Name) ->
    case class_info(C) of
        undefined -> method_lookup_(Rest, Name);
        #{methods := Ms} ->
            case maps:find(Name, Ms) of
                {ok, V} -> {ok, V};
                error -> method_lookup_(Rest, Name)
            end
    end.

attr_lookup(Class, Name) ->
    attr_lookup_(mro(Class), Name).

attr_lookup_([], _Name) -> error;
attr_lookup_([C | Rest], Name) ->
    case class_info(C) of
        undefined -> attr_lookup_(Rest, Name);
        #{attrs := As} ->
            case maps:find(Name, As) of
                {ok, V} -> {ok, V};
                error -> attr_lookup_(Rest, Name)
            end
    end.

-spec instantiate(atom(), list(), map()) -> term().
instantiate(Class, Pos, Kw) ->
    case lists:member(Class, builtin_type_classes()) of
        true -> instantiate_builtin(Class, Pos, Kw);
        false ->
            IsBuiltinExc = is_builtin_exception(Class),
            HasInit = method_lookup(Class, '__init__') =/= error,
            case IsBuiltinExc orelse (is_exception_class(Class) andalso not HasInit) of
                true ->
                    #{'$class' => Class, args => Pos};
                false ->
                    case class_info(Class) of
                        undefined ->
                            raise_exc('TypeError', <<"'", (atom_to_binary(Class, utf8))/binary,
                                      "' object is not callable">>);
                        _ ->
                            Obj = #{'$class' => Class},
                            case method_lookup(Class, '__init__') of
                                {ok, Init} ->
                                    case invoke({'$bound', Init, Obj}, Pos, Kw) of
                                        #{'$class' := _} = NewObj ->
                                            %% exceptions keep .args (BaseException)
                                            case is_exception_class(Class) of
                                                true -> maps:put(args, maps:get(args, NewObj, Pos), NewObj);
                                                false -> NewObj
                                            end;
                                        _ -> Obj
                                    end;
                                error ->
                                    case Pos =:= [] andalso map_size(Kw) =:= 0 of
                                        true -> Obj;
                                        false ->
                                            raise_exc('TypeError',
                                                      <<(exc_class_name(Class))/binary,
                                                        "() takes no arguments">>)
                                    end
                            end
                    end
            end
    end.

instantiate_builtin('object', [], _) -> #{'$class' => 'object'};
instantiate_builtin('object', _, _) -> raise_exc('TypeError', <<"object() takes no arguments">>);
instantiate_builtin('int', Pos, _) -> to_int(Pos);
instantiate_builtin('float', Pos, _) -> to_float(Pos);
instantiate_builtin('str', Pos, _) ->
    case Pos of [] -> <<"">>; [X] -> to_str(X); [X, _Enc] -> to_str(X);
        _ -> raise_exc('TypeError', <<"str() takes at most 1 argument">>) end;
instantiate_builtin('bool', Pos, _) ->
    case Pos of [] -> false; [X] -> truthy(X);
        _ -> raise_exc('TypeError', <<"bool() takes at most 1 argument">>) end;
instantiate_builtin('list', Pos, _) ->
    case Pos of [] -> []; [X] -> iter(X);
        _ -> raise_exc('TypeError', <<"list() takes at most 1 argument">>) end;
instantiate_builtin('tuple', Pos, _) ->
    case Pos of [] -> {}; [X] -> list_to_tuple(iter(X));
        _ -> raise_exc('TypeError', <<"tuple() takes at most 1 argument">>) end;
instantiate_builtin('dict', Pos, Kw) ->
    M0 = case Pos of
             [] -> #{};
             [X] -> to_dict(X);
             _ -> raise_exc('TypeError', <<"dict() takes at most 1 argument">>)
         end,
    maps:merge(M0, Kw);
instantiate_builtin('set', Pos, _) ->
    case Pos of [] -> {'$set', #{}};
        [X] -> to_set(X);
        _ -> raise_exc('TypeError', <<"set() takes at most 1 argument">>) end;
instantiate_builtin('frozenset', Pos, _) -> instantiate_builtin('set', Pos, #{});
instantiate_builtin('function', _, _) -> raise_exc('TypeError', <<"cannot create 'function' instances">>);
instantiate_builtin('module', _, _) -> raise_exc('TypeError', <<"cannot create 'module' instances">>);
instantiate_builtin('NoneType', _, _) -> raise_exc('TypeError', <<"cannot create 'NoneType' instances">>);
instantiate_builtin(C, _, _) ->
    raise_exc('TypeError', <<(atom_to_binary(C, utf8))/binary, " is not instantiable">>).

to_dict(X) when is_map(X) -> maps:remove('$class', X);
to_dict(X) when is_list(X) ->
    lists:foldl(fun
                    ({K, V}, Acc) -> maps:put(K, V, Acc);
                    ([K, V], Acc) -> maps:put(K, V, Acc);
                    (Bad, _) -> raise_exc('TypeError', <<"cannot convert item to dict entry: ", (to_repr(Bad))/binary>>)
                end, #{}, X);
to_dict(X) -> raise_exc('TypeError', <<"cannot convert to dict: ", (to_str(type_of(X)))/binary>>).

to_set(X) ->
    L = iter(X),
    {'$set', maps:from_list([{E, true} || E <- L])}.

to_int([]) -> 0;
to_int([X]) -> to_int(X, 10);
to_int([X, Base]) when is_integer(Base) -> to_int(X, Base);
to_int(_) -> raise_exc('TypeError', <<"int() takes at most 2 arguments">>).

to_int(X, _) when is_integer(X) -> X;
to_int(X, _) when is_float(X) -> trunc(X);
to_int(true, _) -> 1;
to_int(false, _) -> 0;
to_int(?NIL, _) -> raise_exc('TypeError', <<"int() argument cannot be None">>);
to_int(X, Base) when is_binary(X) ->
    S = string:trim(binary_to_list(X)),
    case S of
        "" -> raise_exc('ValueError', <<"invalid literal for int(): ", (to_repr(X))/binary>>);
        _ ->
            {Sign, Digits} = case S of
                                 [$- | D] -> {-1, D};
                                 [$+ | D] -> {1, D};
                                 D -> {1, D}
                             end,
            case catch list_to_integer(Digits, Base) of
                {'EXIT', _} ->
                    raise_exc('ValueError', <<"invalid literal for int(): ", (to_repr(X))/binary>>);
                V -> Sign * V
            end
    end;
to_int(X, _) ->
    raise_exc('TypeError', <<"int() argument must be a string or a number, not '",
                             (to_str(type_of(X)))/binary, "'">>).

to_float([]) -> 0.0;
to_float([X]) -> to_float1(X);
to_float(_) -> raise_exc('TypeError', <<"float() takes at most 1 argument">>).

to_float1(X) when is_float(X) -> X;
to_float1(X) when is_integer(X) -> float(X);
to_float1(true) -> 1.0;
to_float1(false) -> 0.0;
to_float1(X) when is_binary(X) ->
    S = string:trim(binary_to_list(X)),
    case S of
        "" -> raise_exc('ValueError', <<"could not convert string to float: ", (to_repr(X))/binary>>);
        _ ->
            Norm = case string:find(S, ".") of
                       nomatch ->
                           case string:find(S, "e") of
                               nomatch -> S ++ ".0";
                               _ -> S
                           end;
                       _ -> S
                   end,
            case catch list_to_float(Norm) of
                {'EXIT', _} ->
                    case Norm of
                        "inf" -> raise_exc('ValueError', <<"float overflow">>);
                        "Infinity" -> raise_exc('ValueError', <<"float overflow">>);
                        _ -> raise_exc('ValueError',
                                       <<"could not convert string to float: ", (to_repr(X))/binary>>)
                    end;
                V -> V
            end
    end;
to_float1(_) ->
    raise_exc('TypeError', <<"float() argument must be a string or a number">>).

%%====================================================================
%% Calling protocol
%%====================================================================

-spec invoke(term(), list(), map()) -> term().
invoke(F, Pos, Kw) when is_function(F, 2) -> F(Pos, Kw);
invoke({'$bound', Fun, Self}, Pos, Kw) -> invoke(Fun, [Self | Pos], Kw);
invoke({'$tbound', M, Fname, Self}, Pos, Kw) -> apply(M, Fname, [Self, Pos, Kw]);
invoke({'$static', Fun}, Pos, Kw) -> invoke(Fun, Pos, Kw);
invoke({'$super', _C, _Self}, _Pos, _Kw) ->
    raise_exc('RuntimeError', <<"super() proxy is not directly callable">>);
invoke(C, Pos, Kw) when is_atom(C) ->
    case is_slop_class(C) orelse lists:member(C, builtin_classes()) of
        true -> instantiate(C, Pos, Kw);
        false ->
            case C of
                ?NIL -> raise_exc('TypeError', <<"'NoneType' object is not callable">>);
                true -> raise_exc('TypeError', <<"'bool' object is not callable">>);
                false -> raise_exc('TypeError', <<"'bool' object is not callable">>);
                _ ->
                    case module_ensure_init_safe(C) of
                        ok -> raise_exc('TypeError', <<"'module' object is not callable">>);
                        error ->
                            raise_exc('TypeError', <<"'",
                                (atom_to_binary(C, utf8))/binary, "' object is not callable">>)
                    end
            end
    end;
invoke(Obj, Pos, Kw) when is_map(Obj) ->
    case Obj of
        #{'$class' := C} ->
            case method_lookup(C, '__call__') of
                {ok, M} -> invoke({'$bound', M, Obj}, Pos, Kw);
                error ->
                    raise_exc('TypeError', <<"'", (exc_class_name(C))/binary,
                              "' object is not callable">>)
            end;
        _ ->
            raise_exc('TypeError', <<"'dict' object is not callable">>)
    end;
invoke({'$erl_fun', M, F}, Pos, Kw) ->
    Args = case maps:to_list(Kw) of
        [] -> Pos;
        Kws -> Pos ++ [[{binary_to_atom(K, utf8), V} || {K, V} <- Kws]]
    end,
    apply(M, F, Args);
invoke(_, _, _) ->
    raise_exc('TypeError', <<"object is not callable">>).

-spec call_method(term(), atom(), list(), map()) -> term().
call_method({'$erl_mod', _} = EM, Name, Pos, Kw) ->
    invoke(getattr(EM, Name), Pos, Kw);
call_method(Obj, Name, Pos, Kw) when is_map(Obj) ->
    case Obj of
        #{'$class' := _C} -> invoke(getattr(Obj, Name), Pos, Kw);
        _ ->
            case method_exported(slop_dict, Name) of
                true -> apply(slop_dict, Name, [Obj, Pos, Kw]);
                false -> attr_err(Obj, Name)
            end
    end;
call_method(Obj, Name, Pos, Kw) when is_binary(Obj) ->
    case method_exported(slop_str, Name) of
        true -> apply(slop_str, Name, [Obj, Pos, Kw]);
        false -> attr_err(Obj, Name)
    end;
call_method(Obj, Name, Pos, Kw) when is_list(Obj) ->
    case method_exported(slop_list, Name) of
        true -> apply(slop_list, Name, [Obj, Pos, Kw]);
        false -> attr_err(Obj, Name)
    end;
call_method({'$set', _} = Obj, Name, Pos, Kw) ->
    case method_exported(slop_set, Name) of
        true -> apply(slop_set, Name, [Obj, Pos, Kw]);
        false -> attr_err(Obj, Name)
    end;
call_method({'$slop_file', _} = Obj, Name, Pos, Kw) ->
    case method_exported(slop_file, Name) of
        true -> apply(slop_file, Name, [Obj, Pos, Kw]);
        false -> attr_err(Obj, Name)
    end;
call_method({'$super', _, _} = Obj, Name, Pos, Kw) ->
    invoke(getattr(Obj, Name), Pos, Kw);
call_method(Obj, Name, Pos, Kw) when is_atom(Obj) ->
    invoke(getattr(Obj, Name), Pos, Kw);
call_method(Obj, Name, Pos, Kw) when is_tuple(Obj) ->
    case method_exported(slop_tuple, Name) of
        true -> apply(slop_tuple, Name, [Obj, Pos, Kw]);
        false -> attr_err(Obj, Name)
    end;
call_method(Obj, Name, _Pos, _Kw) ->
    attr_err(Obj, Name).

attr_err(Obj, Name) ->
    raise_exc('AttributeError', <<"'", (to_str(type_of(Obj)))/binary,
              "' object has no attribute '", (atom_to_binary(Name, utf8))/binary, "'">>).

method_exported(Mod, Name) ->
    code:ensure_loaded(Mod),
    erlang:function_exported(Mod, Name, 3).

-spec getattr(term(), atom()) -> term().
getattr({'$erl_mod', M}, Name) ->
    code:ensure_loaded(M),
    case erlang:function_exported(M, Name, 0) of
        true -> {'$erl_fun', M, Name};
        false -> {'$erl_fun', M, Name}
    end;
getattr(Obj, Name) when is_map(Obj) ->
    case Obj of
        #{'$class' := C} ->
            case maps:find(Name, Obj) of
                {ok, V} -> V;
                error ->
                    case method_lookup(C, Name) of
                        {ok, {'$static', F}} -> F;
                        {ok, {'$classmeth', F}} -> {'$bound', F, C};
                        {ok, F} -> {'$bound', F, Obj};
                        error ->
                            case attr_lookup(C, Name) of
                                {ok, V} -> V;
                                error ->
                                    case method_lookup(C, '__getattr__') of
                                        {ok, GG} when Name =/= '__getattr__' ->
                                            invoke({'$bound', GG, Obj},
                                                   [atom_to_binary(Name, utf8)], #{});
                                        _ -> attr_err(Obj, Name)
                                    end
                            end
                    end
            end;
        _ ->
            case method_exported(slop_dict, Name) of
                true -> {'$tbound', slop_dict, Name, Obj};
                false -> attr_err(Obj, Name)
            end
    end;
getattr(Obj, Name) when is_binary(Obj) ->
    case method_exported(slop_str, Name) of
        true -> {'$tbound', slop_str, Name, Obj};
        false -> attr_err(Obj, Name)
    end;
getattr(Obj, Name) when is_list(Obj) ->
    case method_exported(slop_list, Name) of
        true -> {'$tbound', slop_list, Name, Obj};
        false -> attr_err(Obj, Name)
    end;
getattr({'$set', _} = Obj, Name) ->
    case method_exported(slop_set, Name) of
        true -> {'$tbound', slop_set, Name, Obj};
        false -> attr_err(Obj, Name)
    end;
getattr({'$slop_file', _} = Obj, Name) ->
    case method_exported(slop_file, Name) of
        true -> {'$tbound', slop_file, Name, Obj};
        false -> attr_err(Obj, Name)
    end;
getattr({'$super', C, Self}, Name) ->
    case mro(C) of
        [_ | Tail] ->
            case method_lookup_in(Tail, Name) of
                {ok, {'$static', F}} -> F;
                {ok, F} -> {'$bound', F, Self};
                error -> attr_err(Self, Name)
            end;
        [] ->
            attr_err(Self, Name)
    end;
getattr(Obj, Name) when is_atom(Obj) ->
    case lists:member(Obj, builtin_classes()) orelse is_slop_class(Obj) of
        true ->
            %% attribute on a class object
            case Name of
                '__name__' -> exc_class_name(Obj);
                '__mro__' -> list_to_tuple(mro(Obj));
                _ ->
                    case method_lookup(Obj, Name) of
                        {ok, {'$static', F}} -> F;
                        {ok, {'$classmeth', F}} -> {'$bound', F, Obj};
                        {ok, F} -> F;
                        error ->
                            case attr_lookup(Obj, Name) of
                                {ok, V} -> V;
                                error ->
                                    case Obj of
                                        'object' -> attr_err(Obj, Name);
                                        _ -> attr_err(Obj, Name)
                                    end
                            end
                    end
            end;
        false ->
            case module_ensure_init_safe(Obj) of
                ok -> Obj:'$__attr__'(Name);
                error ->
                    case Obj of
                        ?NIL -> attr_err(Obj, Name);
                        true -> attr_err(Obj, Name);
                        false -> attr_err(Obj, Name);
                        _ -> attr_err(Obj, Name)
                    end
            end
    end;
getattr(Obj, Name) when is_tuple(Obj) ->
    case method_exported(slop_tuple, Name) of
        true -> {'$tbound', slop_tuple, Name, Obj};
        false -> attr_err(Obj, Name)
    end;
getattr(Obj, Name) ->
    attr_err(Obj, Name).

method_lookup_in([], _Name) -> error;
method_lookup_in([C | Rest], Name) ->
    case class_info(C) of
        undefined -> method_lookup_in(Rest, Name);
        #{methods := Ms} ->
            case maps:find(Name, Ms) of
                {ok, V} -> {ok, V};
                error -> method_lookup_in(Rest, Name)
            end
    end.

-spec getattr(term(), atom(), term()) -> term().
getattr(Obj, Name, Default) ->
    try getattr(Obj, Name)
    catch
        throw:{'$slop_exc', 'AttributeError', _} -> Default
    end.

-spec setattr(term(), atom(), term()) -> term().
setattr(Obj, Name, Val) when is_map(Obj) ->
    case Obj of
        #{'$class' := _C} -> maps:put(Name, Val, Obj);
        _ -> raise_exc('AttributeError', <<"'dict' object attribute assignment is not supported; use d['k'] = v">>)
    end;
setattr(Obj, Name, Val) when is_atom(Obj) ->
    case class_info(Obj) of
        undefined -> attr_err(Obj, Name);
        Info = #{attrs := As} ->
            persistent_term:put({slop_class, Obj}, Info#{attrs => maps:put(Name, Val, As)}),
            Val
    end;
setattr(_Obj, _Name, _Val) ->
    raise_exc('AttributeError', <<"attribute assignment not supported on this value">>).

-spec delattr(term(), atom()) -> term().
delattr(Obj, Name) when is_map(Obj) ->
    case Obj of
        #{'$class' := _C} ->
            case maps:is_key(Name, Obj) of
                true -> maps:remove(Name, Obj);
                false -> attr_err(Obj, Name)
            end;
        _ -> attr_err(Obj, Name)
    end;
delattr(Obj, Name) ->
    attr_err(Obj, Name).

-spec super_proxy(atom(), term()) -> term().
super_proxy(Class, Self) -> {'$super', Class, Self}.

%%====================================================================
%% Indexing / slicing
%%====================================================================

-spec getitem(term(), term()) -> term().
getitem(Obj, {'$slice', Lo, Hi, Step}) -> slice(Obj, Lo, Hi, Step);
getitem(Obj, Idx) when is_list(Obj) ->
    I = check_int_index(Idx),
    N = length(Obj),
    case norm_index(I, N) of
        {ok, J} -> lists:nth(J + 1, Obj);
        error -> raise_exc('IndexError', <<"list index out of range">>)
    end;
getitem(Obj, Idx) when is_tuple(Obj), (not ?TAGGED(Obj)) ->
    I = check_int_index(Idx),
    N = tuple_size(Obj),
    case norm_index(I, N) of
        {ok, J} -> element(J + 1, Obj);
        error -> raise_exc('IndexError', <<"tuple index out of range">>)
    end;
getitem(Obj, Idx) when is_binary(Obj) ->
    I = check_int_index(Idx),
    Chars = unicode:characters_to_list(Obj),
    N = length(Chars),
    case norm_index(I, N) of
        {ok, J} -> unicode:characters_to_binary([lists:nth(J + 1, Chars)]);
        error -> raise_exc('IndexError', <<"string index out of range">>)
    end;
getitem(Obj, Idx) when is_map(Obj) ->
    case Obj of
        #{'$class' := C} ->
            case method_lookup(C, '__getitem__') of
                {ok, M} -> invoke({'$bound', M, Obj}, [Idx], #{});
                error -> raise_exc('TypeError', <<"'", (exc_class_name(C))/binary,
                                   "' object is not subscriptable">>)
            end;
        _ ->
            case maps:find(Idx, Obj) of
                {ok, V} -> V;
                error -> raise_exc('KeyError', [to_repr(Idx)])
            end
    end;
getitem(Obj, _Idx) when is_atom(Obj) ->
    case lists:member(Obj, builtin_classes()) orelse is_slop_class(Obj) of
        %% class subscription: List[int] etc - evaluated to the class itself
        true -> Obj;
        false -> raise_exc('TypeError', <<"'", (atom_to_binary(Obj, utf8))/binary,
                           "' object is not subscriptable">>)
    end;
getitem(Obj, _Idx) ->
    raise_exc('TypeError', <<"'", (to_str(type_of(Obj)))/binary,
              "' object is not subscriptable">>).

is_record_tag(T) ->
    is_tuple(T) andalso tuple_size(T) > 0 andalso
        lists:member(element(1, T), ['$set', '$bound', '$tbound', '$static',
                                      '$classmeth', '$super', '$slice', '$slop_file',
                                      '$erl_mod', '$erl_fun', '$task']).

check_int_index(I) when is_integer(I) -> I;
check_int_index(_) -> raise_exc('TypeError', <<"indices must be integers">>).

norm_index(I, N) when I < 0 ->
    J = I + N,
    if J >= 0 -> {ok, J}; true -> error end;
norm_index(I, N) when I < N -> {ok, I};
norm_index(_, _) -> error.

-spec setitem(term(), term(), term()) -> term().
setitem(Obj, Idx, Val) when is_list(Obj) ->
    I = check_int_index(Idx),
    N = length(Obj),
    case norm_index(I, N) of
        {ok, J} -> replace_nth(J, Obj, Val);
        error -> raise_exc('IndexError', <<"list assignment index out of range">>)
    end;
setitem(Obj, Idx, Val) when is_map(Obj) ->
    case Obj of
        #{'$class' := C} ->
            case method_lookup(C, '__setitem__') of
                {ok, M} ->
                    _ = invoke({'$bound', M, Obj}, [Idx, Val], #{}),
                    Obj;
                error ->
                    raise_exc('TypeError', <<"'", (exc_class_name(C))/binary,
                              "' object does not support item assignment">>)
            end;
        _ ->
            maps:put(Idx, Val, Obj)
    end;
setitem(Obj, _Idx, _Val) ->
    raise_exc('TypeError', <<"'", (to_str(type_of(Obj)))/binary,
              "' object does not support item assignment">>).

replace_nth(0, [_ | T], V) -> [V | T];
replace_nth(J, [H | T], V) when J > 0 -> [H | replace_nth(J - 1, T, V)].

-spec delitem(term(), term()) -> term().
delitem(Obj, Idx) when is_list(Obj) ->
    I = check_int_index(Idx),
    N = length(Obj),
    case norm_index(I, N) of
        {ok, J} -> delete_nth(J, Obj);
        error -> raise_exc('IndexError', <<"list assignment index out of range">>)
    end;
delitem(Obj, Idx) when is_map(Obj) ->
    case Obj of
        #{'$class' := C} ->
            case method_lookup(C, '__delitem__') of
                {ok, M} ->
                    _ = invoke({'$bound', M, Obj}, [Idx], #{}),
                    Obj;
                error -> raise_exc('TypeError', <<"item deletion not supported">>)
            end;
        _ ->
            case maps:is_key(Idx, Obj) of
                true -> maps:remove(Idx, Obj);
                false -> raise_exc('KeyError', [to_repr(Idx)])
            end
    end;
delitem(Obj, _Idx) ->
    raise_exc('TypeError', <<"'", (to_str(type_of(Obj)))/binary,
              "' object does not support item deletion">>).

delete_nth(0, [_ | T]) -> T;
delete_nth(J, [H | T]) when J > 0 -> [H | delete_nth(J - 1, T)].

-spec slice(term(), term(), term(), term()) -> term().
slice(Obj, Lo, Hi, Step) when is_list(Obj) ->
    St = case Step of ?NIL -> 1; _ -> check_int_index(Step) end,
    N = length(Obj),
    {A, B} = slice_bounds(Lo, Hi, St, N),
    slice_list(Obj, A, B, St);
slice(Obj, Lo, Hi, Step) when is_binary(Obj) ->
    Chars = unicode:characters_to_list(Obj),
    Sliced = slice(Chars, Lo, Hi, Step),
    unicode:characters_to_binary(Sliced);
slice(Obj, Lo, Hi, Step) when is_tuple(Obj), (not ?TAGGED(Obj)) ->
    list_to_tuple(slice(tuple_to_list(Obj), Lo, Hi, Step));
slice(Obj, _Lo, _Hi, _Step) ->
    raise_exc('TypeError', <<"'", (to_str(type_of(Obj)))/binary,
              "' object is not sliceable">>).

slice_bounds(Lo, Hi, St, N) when St > 0 ->
    A = case Lo of
            ?NIL -> 0;
            _ -> L0 = check_int_index(Lo),
                 if L0 < 0 -> erlang:max(L0 + N, 0); true -> erlang:min(L0, N) end
        end,
    B = case Hi of
            ?NIL -> N;
            _ -> H0 = check_int_index(Hi),
                 if H0 < 0 -> erlang:max(H0 + N, 0); true -> erlang:min(H0, N) end
        end,
    {A, B};
slice_bounds(Lo, Hi, St, N) when St < 0 ->
    A = case Lo of
            ?NIL -> N - 1;
            _ -> L0 = check_int_index(Lo),
                 if L0 < 0 -> erlang:max(L0 + N, -1); true -> erlang:min(L0, N - 1) end
        end,
    B = case Hi of
            ?NIL -> -1;
            _ -> H0 = check_int_index(Hi),
                 if H0 < 0 -> H0 + N; true -> erlang:min(H0, N - 1) end
        end,
    {A, B}.

slice_list(_L, A, B, St) when St > 0, A >= B -> [];
slice_list(L, A, B, St) when St > 0 ->
    Sub = lists:sublist(L, A + 1, B - A),
    take_every(Sub, St);
slice_list(_L, A, B, St) when St < 0, A =< B -> [];
slice_list(L, A, B, St) when St < 0 ->
    Len = A - B,
    Sub = lists:reverse(lists:sublist(L, B + 2, Len)),
    take_every(Sub, -St).

take_every(L, 1) -> L;
take_every(L, St) -> take_every(L, St, 1).
take_every([], _, _) -> [];
take_every([H | T], St, N) when N =:= 1 -> [H | take_every(T, St, St)];
take_every([_ | T], St, N) -> take_every(T, St, N - 1).

%%====================================================================
%% Operators
%%====================================================================

-spec truthy(term()) -> boolean().
truthy(?NIL) -> false;
truthy(false) -> false;
truthy(true) -> true;
truthy(0) -> false;
truthy(0.0) -> false;
truthy(<<>>) -> false;
truthy([]) -> false;
truthy({}) -> false;
truthy(M) when is_map(M) -> map_size(M) > 0;
truthy({'$set', S}) -> map_size(S) > 0;
truthy(T) when is_tuple(T) -> tuple_size(T) > 0;
truthy(_) -> true.

-spec binop(string() | atom(), term(), term()) -> term().
binop(Op, A, B) when is_binary(Op) -> binop(binary_to_list(Op), A, B);
binop("+", A, B) -> add(A, B);
binop("-", A, B) -> sub(A, B);
binop("*", A, B) -> mul(A, B);
binop("/", A, B) -> truediv(A, B);
binop("//", A, B) -> floordiv(A, B);
binop("%", A, B) -> pymod(A, B);
binop("**", A, B) -> pypow(A, B);
binop("<<", A, B) when is_integer(A), is_integer(B), B >= 0 -> A bsl B;
binop(">>", A, B) when is_integer(A), is_integer(B), B >= 0 -> A bsr B;
binop("&", A, B) -> band_(A, B);
binop("|", A, B) -> bor_(A, B);
binop("^", A, B) -> bxor_(A, B);
binop(Op, A, B) when Op =:= "=="; Op =:= "!="; Op =:= "<"; Op =:= ">";
                     Op =:= "<="; Op =:= ">=" ->
    cmp(Op, A, B);
binop(Op, A, B) ->
    dunder_fallback(Op, A, B).

-define(DUNDER(Op, Meth), dunder(Op, A, B) ->
    case maybe_dunder(A, Meth, [B]) of
        {ok, V} -> V;
        error -> {dunder_fail, Op, A, B}
    end).

add(A, B) when is_number(A), is_number(B) -> A + B;
add(A, B) when is_binary(A), is_binary(B) -> <<A/binary, B/binary>>;
add(A, B) when is_list(A), is_list(B) -> A ++ B;
add(A, B) when is_tuple(A), is_tuple(B), (not ?TAGGED(A)), (not ?TAGGED(B)) ->
    list_to_tuple(tuple_to_list(A) ++ tuple_to_list(B));
add(A, B) -> dunder_or_type_error('__add__', '__radd__', A, B, "+").

sub(A, B) when is_number(A), is_number(B) -> A - B;
sub({'$set', SA}, {'$set', SB}) -> {'$set', maps:without(maps:keys(SB), SA)};
sub(A, B) -> dunder_or_type_error('__sub__', '__rsub__', A, B, "-").

mul(A, B) when is_number(A), is_number(B) -> A * B;
mul(A, B) when is_binary(A), is_integer(B) -> repeat_bin(A, B);
mul(A, B) when is_integer(A), is_binary(B) -> repeat_bin(B, A);
mul(A, B) when is_list(A), is_integer(B) -> repeat_list(A, B);
mul(A, B) when is_integer(A), is_list(B) -> repeat_list(B, A);
mul(A, B) when is_tuple(A), is_integer(B), (not ?TAGGED(A)) ->
    list_to_tuple(repeat_list(tuple_to_list(A), B));
mul(A, B) when is_integer(A), is_tuple(B), (not ?TAGGED(B)) ->
    list_to_tuple(repeat_list(tuple_to_list(B), A));
mul(A, B) -> dunder_or_type_error('__mul__', '__rmul__', A, B, "*").

repeat_bin(_, N) when N =< 0 -> <<>>;
repeat_bin(B, N) -> binary:copy(B, N).

repeat_list(_, N) when N =< 0 -> [];
repeat_list(L, N) -> lists:append(lists:duplicate(N, L)).

truediv(A, B) when is_number(A), is_number(B) ->
    case B of
        0 -> raise_exc('ZeroDivisionError', <<"division by zero">>);
        0.0 -> raise_exc('ZeroDivisionError', <<"division by zero">>);
        _ -> A / B
    end;
truediv(A, B) -> dunder_or_type_error('__truediv__', '__rtruediv__', A, B, "/").

floordiv(A, B) when is_integer(A), is_integer(B) ->
    case B of
        0 -> raise_exc('ZeroDivisionError', <<"integer division or modulo by zero">>);
        _ ->
            Q = A div B,
            case (A rem B =/= 0) andalso ((A < 0) =/= (B < 0)) of
                true -> Q - 1;
                false -> Q
            end
    end;
floordiv(A, B) when is_number(A), is_number(B) ->
    case B of
        0 -> raise_exc('ZeroDivisionError', <<"float floor division by zero">>);
        0.0 -> raise_exc('ZeroDivisionError', <<"float floor division by zero">>);
        _ -> math:floor(A / B)
    end;
floordiv(A, B) -> dunder_or_type_error('__floordiv__', '__rfloordiv__', A, B, "//").

pymod(A, B) when is_integer(A), is_integer(B) ->
    case B of
        0 -> raise_exc('ZeroDivisionError', <<"integer division or modulo by zero">>);
        _ ->
            R = A rem B,
            case R =/= 0 andalso ((R < 0) =/= (B < 0)) of
                true -> R + B;
                false -> R
            end
    end;
pymod(A, B) when is_number(A), is_number(B) ->
    case B of
        0 -> raise_exc('ZeroDivisionError', <<"float modulo">>);
        0.0 -> raise_exc('ZeroDivisionError', <<"float modulo">>);
        _ -> A - B * math:floor(A / B)
    end;
pymod(A, B) when is_binary(A) ->
    %% printf-style formatting: "%s and %s" % (a, b)
    format_percent(A, B);
pymod(A, B) -> dunder_or_type_error('__mod__', '__rmod__', A, B, "%").

pypow(A, B) when is_integer(A), is_integer(B), B >= 0 -> int_pow(A, B);
pypow(A, B) when is_number(A), is_number(B) ->
    R = math:pow(A, B),
    case is_integer(A) andalso is_integer(B) of
        true -> R;
        false -> R
    end;
pypow(A, B) -> dunder_or_type_error('__pow__', '__rpow__', A, B, "**").

int_pow(_, 0) -> 1;
int_pow(A, 1) -> A;
int_pow(A, B) when B rem 2 =:= 0 ->
    H = int_pow(A, B div 2),
    H * H;
int_pow(A, B) -> A * int_pow(A, B - 1).

band_(A, B) when is_integer(A), is_integer(B) -> A band B;
band_({'$set', SA}, {'$set', SB}) ->
    K = [K1 || K1 <- maps:keys(SA), maps:is_key(K1, SB)],
    {'$set', maps:with(K, SA)};
band_(A, B) -> dunder_or_type_error('__and__', '__rand__', A, B, "&").

bor_(A, B) when is_integer(A), is_integer(B) -> A bor B;
bor_({'$set', SA}, {'$set', SB}) -> {'$set', maps:merge(SA, SB)};
bor_(A, B) when is_map(A), is_map(B), (not is_map_key('$class', A)), (not is_map_key('$class', B)) ->
    maps:merge(A, B);
bor_(A, B) -> dunder_or_type_error('__or__', '__ror__', A, B, "|").

bxor_(A, B) when is_integer(A), is_integer(B) -> A bxor B;
bxor_({'$set', SA}, {'$set', SB}) ->
    Only = maps:without(maps:keys(SB), SA),
    OnlyB = maps:without(maps:keys(SA), SB),
    {'$set', maps:merge(Only, OnlyB)};
bxor_(A, B) -> dunder_or_type_error('__xor__', '__rxor__', A, B, "^").

dunder_or_type_error(Meth, RMeth, A, B, OpStr) ->
    case maybe_dunder(A, Meth, [B]) of
        {ok, V} -> V;
        error ->
            case maybe_dunder(B, RMeth, [A]) of
                {ok, V} -> V;
                error ->
                    raise_exc('TypeError', <<"unsupported operand type(s) for ", OpStr/binary,
                              ": '", (to_str(type_of(A)))/binary, "' and '",
                              (to_str(type_of(B)))/binary, "'">>)
            end
    end.

dunder_fallback(Op, A, B) ->
    raise_exc('TypeError', <<"unsupported operator ", Op/binary, " for '",
              (to_str(type_of(A)))/binary, "' and '", (to_str(type_of(B)))/binary, "'">>).

maybe_dunder(Obj, Meth, Args) when is_map(Obj) ->
    case Obj of
        #{'$class' := C} ->
            case method_lookup(C, Meth) of
                {ok, M} -> {ok, invoke({'$bound', M, Obj}, Args, #{})};
                error -> error
            end;
        _ -> error
    end;
maybe_dunder(_, _, _) -> error.

-spec unary(string(), term()) -> term().
unary(Op, A) when is_binary(Op) -> unary(binary_to_list(Op), A);
unary("-", A) when is_number(A) -> -A;
unary("+", A) when is_number(A) -> A;
unary("~", A) when is_integer(A) -> bnot(A);
unary("not", A) -> not truthy(A);
unary("-", A) -> unary_dunder('__neg__', A, "-");
unary("+", A) -> unary_dunder('__pos__', A, "+");
unary("~", A) -> unary_dunder('__invert__', A, "~").

unary_dunder(Meth, A, OpStr) ->
    case maybe_dunder(A, Meth, []) of
        {ok, V} -> V;
        error ->
            raise_exc('TypeError', <<"bad operand type for unary ", OpStr/binary,
                      ": '", (to_str(type_of(A)))/binary, "'">>)
    end.

%%====================================================================
%% Comparison
%%====================================================================

-spec eq(term(), term()) -> boolean().
eq(A, B) when is_number(A), is_number(B) -> A == B;
eq(A, B) when is_binary(A), is_binary(B) -> A =:= B;
eq(A, B) when is_atom(A), is_atom(B) -> A =:= B;
eq(A, B) when is_list(A), is_list(B) ->
    length(A) =:= length(B) andalso
        lists:all(fun({X, Y}) -> eq(X, Y) end, lists:zip(A, B));
eq(A, B) when is_tuple(A), is_tuple(B) ->
    case is_record_tag(A) orelse is_record_tag(B) of
        true -> tagged_eq(A, B);
        false ->
            tuple_size(A) =:= tuple_size(B) andalso
                eq(tuple_to_list(A), tuple_to_list(B))
    end;
eq({'$set', SA}, {'$set', SB}) ->
    map_size(SA) =:= map_size(SB) andalso
        lists:all(fun(K) -> maps:is_key(K, SB) end, maps:keys(SA));
eq(A, B) when is_map(A), is_map(B) ->
    case {maps:is_key('$class', A), maps:is_key('$class', B)} of
        {true, true} ->
            C = maps:get('$class', A),
            case method_lookup(C, '__eq__') of
                {ok, M} -> truthy(invoke({'$bound', M, A}, [B], #{}));
                error -> A =:= B
            end;
        {false, false} ->
            map_size(A) =:= map_size(B) andalso
                maps:fold(fun(K, V, Acc) ->
                                  Acc andalso maps:is_key(K, B) andalso eq(V, maps:get(K, B))
                          end, true, A);
        _ -> false
    end;
eq(_, _) -> false.

tagged_eq({'$set', _} = A, {'$set', _} = B) -> eq(A, B);
tagged_eq(A, B) -> A =:= B.

-spec cmp(binary() | string(), term(), term()) -> boolean().
cmp(Op, A, B) when is_binary(Op) -> cmp(binary_to_list(Op), A, B);
cmp("==", A, B) -> eq(A, B);
cmp("!=", A, B) -> not eq(A, B);
cmp(Op, A, B) when is_number(A), is_number(B) ->
    case Op of
        "<" -> A < B;
        ">" -> A > B;
        "<=" -> A =< B;
        ">=" -> A >= B
    end;
cmp(Op, A, B) when is_binary(A), is_binary(B) ->
    case Op of
        "<" -> A < B;
        ">" -> A > B;
        "<=" -> A =< B;
        ">=" -> B >= A orelse A =:= B
    end;
cmp(Op, A, B) when is_list(A), is_list(B) ->
    list_cmp(Op, A, B);
cmp(Op, A, B) when is_tuple(A), is_tuple(B), (not ?TAGGED(A)), (not ?TAGGED(B)) ->
    list_cmp(Op, tuple_to_list(A), tuple_to_list(B));
cmp(Op, {'$set', SA}, {'$set', SB}) ->
    Sub = lists:all(fun(K) -> maps:is_key(K, SB) end, maps:keys(SA)),
    Sup = lists:all(fun(K) -> maps:is_key(K, SA) end, maps:keys(SB)),
    case Op of
        "<" -> Sub andalso map_size(SA) < map_size(SB);
        "<=" -> Sub;
        ">" -> Sup andalso map_size(SA) > map_size(SB);
        ">=" -> Sup
    end;
cmp("<", A, B) -> cmp_dunder('__lt__', '__gt__', A, B);
cmp(">", A, B) -> cmp_dunder('__gt__', '__lt__', A, B);
cmp("<=", A, B) -> cmp_dunder('__le__', '__ge__', A, B);
cmp(">=", A, B) -> cmp_dunder('__ge__', '__le__', A, B).

list_cmp(Op, A, B) ->
    case lex_cmp(A, B) of
        lt -> Op =:= "<" orelse Op =:= "<=" orelse Op =:= "!=";
        gt -> Op =:= ">" orelse Op =:= ">=" orelse Op =:= "!=";
        eqv -> Op =:= "<=" orelse Op =:= ">=" orelse Op =:= "=="
    end.

lex_cmp([], []) -> eqv;
lex_cmp([], [_ | _]) -> lt;
lex_cmp([_ | _], []) -> gt;
lex_cmp([H1 | T1], [H2 | T2]) ->
    case cmp("<", H1, H2) of
        true -> lt;
        false ->
            case cmp(">", H1, H2) of
                true -> gt;
                false -> lex_cmp(T1, T2)
            end
    end.

cmp_dunder(Meth, RMeth, A, B) ->
    case maybe_dunder(A, Meth, [B]) of
        {ok, V} -> truthy(V);
        error ->
            case maybe_dunder(B, RMeth, [A]) of
                {ok, V} -> truthy(V);
                error ->
                    raise_exc('TypeError', <<"'<' not supported between instances of '",
                              (to_str(type_of(A)))/binary, "' and '",
                              (to_str(type_of(B)))/binary, "'">>)
            end
    end.

-spec contains(term(), term()) -> boolean().
contains(Container, Item) when is_list(Container) ->
    lists:any(fun(E) -> eq(E, Item) end, Container);
contains(Container, Item) when is_binary(Container), is_binary(Item) ->
    binary:match(Container, Item) =/= nomatch;
contains(Container, Item) when is_binary(Container) ->
    raise_exc('TypeError', <<"'in <string>' requires string as left operand, not ",
              (to_str(type_of(Item)))/binary>>);
contains(Container, Item) when is_tuple(Container), (not ?TAGGED(Container)) ->
    contains(tuple_to_list(Container), Item);
contains(Container, Item) when is_map(Container) ->
    case Container of
        #{'$class' := C} ->
            case method_lookup(C, '__contains__') of
                {ok, M} -> truthy(invoke({'$bound', M, Container}, [Item], #{}));
                error ->
                    %% fall back to iteration
                    contains_iter(Container, Item)
            end;
        _ -> maps:is_key(Item, Container)
    end;
contains({'$set', S}, Item) -> maps:is_key(Item, S);
contains(Container, _Item) when is_atom(Container) ->
    case is_slop_class(Container) orelse lists:member(Container, builtin_classes()) of
        true -> raise_exc('TypeError', <<"argument of type 'type' is not iterable">>);
        false -> raise_exc('TypeError', <<"argument of type 'module' is not iterable">>)
    end;
contains(Container, Item) ->
    contains_iter(Container, Item).

contains_iter(Container, Item) ->
    case type_of(Container) of
        T when T =:= 'int'; T =:= 'float'; T =:= 'bool'; T =:= 'NoneType' ->
            raise_exc('TypeError', <<"argument of type '", (to_str(T))/binary,
                      "' is not iterable">>);
        _ ->
            lists:any(fun(E) -> eq(E, Item) end, iter(Container))
    end.

%%====================================================================
%% Iteration
%%====================================================================

-spec iter(term()) -> list().
iter(L) when is_list(L) -> L;
iter(B) when is_binary(B) ->
    [unicode:characters_to_binary([C]) || C <- unicode:characters_to_list(B)];
iter(T) when is_tuple(T) ->
    case is_record_tag(T) of
        true ->
            case T of
                {'$set', S} -> maps:keys(S);
                _ -> raise_exc('TypeError', <<"object is not iterable">>)
            end;
        false -> tuple_to_list(T)
    end;
iter(M) when is_map(M) ->
    case M of
        #{'$class' := C} ->
            case method_lookup(C, '__iter__') of
                {ok, F} -> iter(invoke({'$bound', F, M}, [], #{}));
                error ->
                    raise_exc('TypeError', <<"'", (exc_class_name(C))/binary,
                              "' object is not iterable">>)
            end;
        _ -> maps:keys(M)
    end;
iter(A) when is_atom(A) ->
    raise_exc('TypeError', <<"'", (to_str(type_of(A)))/binary, "' object is not iterable">>);
iter(X) ->
    raise_exc('TypeError', <<"'", (to_str(type_of(X)))/binary, "' object is not iterable">>).

%%====================================================================
%% String conversion
%%====================================================================

-spec to_str(term()) -> binary().
to_str(?NIL) -> <<"None">>;
to_str(true) -> <<"True">>;
to_str(false) -> <<"False">>;
to_str(I) when is_integer(I) -> integer_to_binary(I);
to_str(F) when is_float(F) -> float_to_binary(F, [short]);
to_str(B) when is_binary(B) -> B;
to_str(L) when is_list(L) ->
    io_list("[", L, "]", fun to_repr/1);
to_str(T) when is_tuple(T) ->
    case is_record_tag(T) of
        true -> tagged_str(T);
        false ->
            case tuple_size(T) of
                0 -> <<"()">>;
                1 -> <<"(", (to_repr(element(1, T)))/binary, ",)">>;
                _ -> io_list("(", tuple_to_list(T), ")", fun to_repr/1)
            end
    end;
to_str(M) when is_map(M) ->
    case M of
        #{'$class' := C} ->
            case method_lookup(C, '__str__') of
                {ok, F} ->
                    R = invoke({'$bound', F, M}, [], #{}),
                    case is_binary(R) of
                        true -> R;
                        false -> raise_exc('TypeError', <<"__str__ returned non-string">>)
                    end;
                error -> default_obj_str(M)
            end;
        _ ->
            Pairs = maps:to_list(M),
            Inner = [[to_repr(K), ": ", to_repr(V)] || {K, V} <- Pairs],
            iolist_to_binary(["{", join_iolist(Inner, ", "), "}"])
    end;
to_str(F) when is_function(F, 2) -> <<"<function>">>;
to_str(P) when is_pid(P) ->
    iolist_to_binary(io_lib:format("<pid ~w>", [P]));
to_str(R) when is_reference(R) ->
    iolist_to_binary(io_lib:format("<ref ~w>", [R]));
to_str(A) when is_atom(A) ->
    case is_slop_class(A) orelse lists:member(A, builtin_classes()) of
        true ->
            <<"<class '", (exc_class_name(A))/binary, "'>">>;
        false ->
            case module_ensure_init_safe(A) of
                ok -> <<"<module '", (atom_to_binary(A, utf8))/binary, "'>">>;
                error -> atom_to_binary(A, utf8)
            end
    end;
to_str(_) -> <<"<object>">>.

tagged_str({'$set', S}) ->
    case map_size(S) of
        0 -> <<"set()">>;
        _ -> io_list("{", maps:keys(S), "}", fun to_repr/1)
    end;
tagged_str({'$bound', _F, Self}) ->
    <<"<bound method of ", (to_str(Self))/binary, ">">>;
tagged_str({'$tbound', _M, F, Self}) ->
    <<"<built-in method ", (atom_to_binary(F, utf8))/binary, " of ",
      (to_str(Self))/binary, ">">>;
tagged_str({'$static', _}) -> <<"<staticmethod>">>;
tagged_str({'$super', C, _}) ->
    <<"<super: ", (exc_class_name(C))/binary, ">">>;
tagged_str({'$slice', Lo, Hi, Step}) ->
    <<"slice(", (to_repr(Lo))/binary, ", ", (to_repr(Hi))/binary, ", ",
      (to_repr(Step))/binary, ")">>;
tagged_str({'$slop_file', _}) -> <<"<file>">>;
tagged_str({'$erl_mod', M}) ->
    <<"<erl_mod '", (atom_to_binary(M, utf8))/binary, "'>">>;
tagged_str({'$task', P, _}) ->
    iolist_to_binary(io_lib:format("<task ~w>", [P]));
tagged_str({'$erl_fun', M, F}) ->
    <<"<erl_fun '", (atom_to_binary(M, utf8))/binary, ":",
      (atom_to_binary(F, utf8))/binary, "'>">>;
tagged_str(T) -> iolist_to_binary(io_lib:format("~p", [T])).

default_obj_str(#{'$class' := C, args := Args}) ->
    case is_exception_class(C) orelse is_builtin_exception(C) of
        true ->
            case Args of
                [] -> <<>>;
                [A] -> to_str(A);
                _ -> io_list("(", Args, ")", fun to_repr/1)
            end;
        false ->
            <<"<", (exc_class_name(C))/binary, " object>">>
    end;
default_obj_str(#{'$class' := C}) ->
    <<"<", (exc_class_name(C))/binary, " object>">>.

-spec to_repr(term()) -> binary().
to_repr(B) when is_binary(B) ->
    Escaped = binary:replace(
                binary:replace(
                  binary:replace(
                    binary:replace(B, <<"\\">>, <<"\\\\">>, [global]),
                    <<"'">>, <<"\\'">>, [global]),
                  <<"\n">>, <<"\\n">>, [global]),
                <<"\t">>, <<"\\t">>, [global]),
    <<"'", Escaped/binary, "'">>;
to_repr(M) when is_map(M) ->
    case M of
        #{'$class' := C} ->
            case method_lookup(C, '__repr__') of
                {ok, F} ->
                    R = invoke({'$bound', F, M}, [], #{}),
                    case is_binary(R) of
                        true -> R;
                        false -> default_obj_str(M)
                    end;
                error -> default_obj_str(M)
            end;
        _ -> to_str(M)
    end;
to_repr(X) -> to_str(X).

io_list(Open, Items, Close, Fun) ->
    Inner = [Fun(I) || I <- Items],
    iolist_to_binary([Open, join_iolist(Inner, ", "), Close]).

join_iolist([], _Sep) -> [];
join_iolist([X], _Sep) -> [X];
join_iolist([X | Rest], Sep) -> [X, Sep | join_iolist(Rest, Sep)].

-spec type_of(term()) -> atom().
type_of(?NIL) -> 'NoneType';
type_of(true) -> 'bool';
type_of(false) -> 'bool';
type_of(I) when is_integer(I) -> 'int';
type_of(F) when is_float(F) -> 'float';
type_of(B) when is_binary(B) -> 'str';
type_of(L) when is_list(L) -> 'list';
type_of(M) when is_map(M) ->
    case M of
        #{'$class' := C} -> C;
        _ -> 'dict'
    end;
type_of(F) when is_function(F, 2) -> 'function';
type_of(T) when is_tuple(T) ->
    case is_record_tag(T) of
        true ->
            case element(1, T) of
                '$set' -> 'set';
                '$slop_file' -> 'file';
                _ -> 'object'
            end;
        false -> 'tuple'
    end;
type_of(A) when is_atom(A) ->
    case is_slop_class(A) orelse lists:member(A, builtin_classes()) of
        true -> 'type';
        false -> 'module'
    end;
type_of(_) -> 'object'.

%%====================================================================
%% Parameter binding
%%====================================================================
%%
%% Spec: #{pos => [{Name, HasDefault}], vararg => Name | nil,
%%        kwonly => [{Name, HasDefault}], kwarg => Name | nil}
%% Defaults: tuple of default values (positional defaults first in order
%% of appearance, then kwonly defaults in order of appearance)
%% Returns {Values(list, positional then kwonly), Vararg(list|nil), KwRest(map|nil)}

-spec bind_params(map(), tuple(), list(), map()) -> {list(), list() | ?NIL, map() | ?NIL}.
bind_params(Spec, Defaults, Args, Kw) ->
    PosSpec = maps:get(pos, Spec),
    Vararg = maps:get(vararg, Spec, ?NIL),
    Kwonly = maps:get(kwonly, Spec, []),
    Kwarg = maps:get(kwarg, Spec, ?NIL),
    NPos = length(PosSpec),
    NArgs = length(Args),
    case NArgs > NPos andalso Vararg =:= ?NIL of
        true ->
            raise_exc('TypeError', iolist_to_binary(
                      io_lib:format("expected at most ~B positional arguments but ~B were given",
                                    [NPos, NArgs])));
        false -> ok
    end,
    {PosVals, Kw1, NDefUsed} = bind_pos(PosSpec, Defaults, Args, Kw, 1, []),
    VarargVal = case Vararg of
                    ?NIL -> ?NIL;
                    _ -> lists:nthtail(erlang:min(NPos, NArgs), Args)
                end,
    {KwonlyVals, Kw2, _} = bind_kwonly(Kwonly, Defaults, NDefUsed, Kw1, []),
    KwRest = case Kwarg of
                 ?NIL ->
                     case map_size(Kw2) of
                         0 -> ?NIL;
                         _ ->
                             [BadKey | _] = maps:keys(Kw2),
                             raise_exc('TypeError', <<"unexpected keyword argument '",
                                       (atom_to_binary(BadKey, utf8))/binary, "'">>)
                     end;
                 _ -> Kw2
             end,
    {PosVals ++ KwonlyVals, VarargVal, KwRest}.

bind_pos([], _Defaults, _Args, Kw, DefIdx, Acc) ->
    {lists:reverse(Acc), Kw, DefIdx - 1};
bind_pos([{Name, HasDef} | Rest], Defaults, Args, Kw, DefIdx, Acc) ->
    NextDefIdx = case HasDef of true -> DefIdx + 1; false -> DefIdx end,
    case Args of
        [A | RestArgs] ->
            bind_pos(Rest, Defaults, RestArgs, Kw, NextDefIdx, [A | Acc]);
        [] ->
            case maps:take(Name, Kw) of
                {Kv, Kw2} ->
                    bind_pos(Rest, Defaults, [], Kw2, NextDefIdx, [Kv | Acc]);
                error ->
                    case HasDef of
                        true ->
                            Dv = element(DefIdx, Defaults),
                            bind_pos(Rest, Defaults, [], Kw, NextDefIdx, [Dv | Acc]);
                        false ->
                            raise_exc('TypeError', <<"missing required argument: '",
                                      (atom_to_binary(Name, utf8))/binary, "'">>)
                    end
            end
    end.

bind_kwonly([], _Defaults, DefIdx, Kw, Acc) ->
    {lists:reverse(Acc), Kw, DefIdx};
bind_kwonly([{Name, HasDef} | Rest], Defaults, DefIdx, Kw, Acc) ->
    NextDefIdx = case HasDef of true -> DefIdx + 1; false -> DefIdx end,
    case maps:take(Name, Kw) of
        {V, Kw2} ->
            bind_kwonly(Rest, Defaults, NextDefIdx, Kw2, [V | Acc]);
        error ->
            case HasDef of
                true ->
                    Dv = element(DefIdx, Defaults),
                    bind_kwonly(Rest, Defaults, NextDefIdx, Kw, [Dv | Acc]);
                false ->
                    raise_exc('TypeError', <<"missing required keyword-only argument: '",
                              (atom_to_binary(Name, utf8))/binary, "'">>)
            end
    end.

%%====================================================================
%% Sequence unpacking
%%====================================================================
%%
%% Shape: nested structure describing the target tree. A sequence is a
%% list of elements; an element is the atom 'name' (a leaf), {'star'}
%% (the starred leaf of that sequence), or a nested list.
%% Returns a flat list of leaf values in left-to-right order.

-spec unpack(term(), term()) -> [term()].
unpack(Value, Shape) when is_list(Shape) ->
    Seq = iter(Value),
    case find_star(Shape, 0) of
        none ->
            N = length(Shape),
            case length(Seq) of
                N -> unpack_zip(Seq, Shape);
                L when L < N ->
                    raise_exc('ValueError', iolist_to_binary(io_lib:format(
                        "not enough values to unpack (expected ~B, got ~B)", [N, L])));
                L ->
                    raise_exc('ValueError', iolist_to_binary(io_lib:format(
                        "too many values to unpack (expected ~B, got ~B)", [N, L])))
            end;
        StarIdx ->
            unpack_star(Seq, Shape, StarIdx)
    end.

find_star([], _I) -> none;
find_star([{'star'} | _], I) -> I;
find_star([_ | T], I) -> find_star(T, I + 1).

unpack_zip(Seq, Shape) ->
    lists:append([unpack_one(V, S) || {V, S} <- lists:zip(Seq, Shape)]).

unpack_one(V, S) when is_list(S) -> unpack(V, S);
unpack_one(V, _Leaf) -> [V].

unpack_star(Seq, Shape, StarIdx) ->
    N = length(Seq),
    Pre = lists:sublist(Shape, StarIdx),
    Post = lists:nthtail(StarIdx + 1, Shape),
    NPre = length(Pre),
    NPost = length(Post),
    case N < NPre + NPost of
        true ->
            raise_exc('ValueError', iolist_to_binary(io_lib:format(
                "not enough values to unpack (expected at least ~B, got ~B)",
                [NPre + NPost, N])));
        false -> ok
    end,
    PreVals = lists:sublist(Seq, NPre),
    StarVals = lists:sublist(Seq, NPre + 1, N - NPre - NPost),
    PostVals = lists:nthtail(N - NPost, Seq),
    unpack_zip(PreVals, Pre) ++ [StarVals] ++ unpack_zip(PostVals, Post).

%%====================================================================
%% Globals (module-level mutable state)
%%====================================================================

-spec global_get(atom(), atom()) -> term().
global_get(Mod, Name) ->
    module_ensure_init(Mod),
    case persistent_term:get({slop_mod, Mod}, undefined) of
        M when is_map(M) ->
            case maps:find(Name, M) of
                {ok, V} -> V;
                error ->
                    raise_exc('NameError', <<"name '", (atom_to_binary(Name, utf8))/binary,
                              "' is not defined">>)
            end;
        _ ->
            raise_exc('NameError', <<"name '", (atom_to_binary(Name, utf8))/binary,
                      "' is not defined">>)
    end.

-spec global_set(atom(), atom(), term()) -> term().
global_set(Mod, Name, V) ->
    case persistent_term:get({slop_mod, Mod}, undefined) of
        M when is_map(M) -> persistent_term:put({slop_mod, Mod}, maps:put(Name, V, M));
        _ -> persistent_term:put({slop_mod, Mod}, #{Name => V})
    end,
    V.

-spec module_ensure_init(atom()) -> term().
module_ensure_init(Mod) ->
    case persistent_term:get({slop_mod, Mod}, undefined) of
        undefined -> Mod:'$__init__'();
        M -> M
    end.

module_ensure_init_safe(Mod) ->
    case persistent_term:get({slop_mod, Mod}, undefined) of
        undefined ->
            try
                _ = Mod:'$__attr__'('__name__'),
                ok
            catch
                _:_ -> error
            end;
        _ -> ok
    end.

-spec set_argv([binary()]) -> ok.
set_argv(Args) -> persistent_term:put(slop_argv, Args), ok.

%%====================================================================
%% with statement
%%====================================================================

with_enter({'$slop_file', _} = F) -> F;
with_enter(Mgr) when is_map(Mgr) ->
    case Mgr of
        #{'$class' := C} ->
            case method_lookup(C, '__enter__') of
                {ok, M} -> invoke({'$bound', M, Mgr}, [], #{});
                error -> Mgr
            end;
        _ -> Mgr
    end;
with_enter(Mgr) -> Mgr.

with_exit({'$slop_file', _} = F, _ExcInfo) ->
    _ = slop_file:close(F, [], #{}),
    false;
with_exit(Mgr, ExcInfo) when is_map(Mgr) ->
    case Mgr of
        #{'$class' := C} ->
            case method_lookup(C, '__exit__') of
                {ok, M} ->
                    R = invoke({'$bound', M, Mgr}, [ExcInfo], #{}),
                    truthy(R);
                error -> false
            end;
        _ -> false
    end;
with_exit(_Mgr, _ExcInfo) -> false.

%%====================================================================
%% Format spec (f-strings and format())
%%====================================================================

-spec format_spec(term(), binary()) -> binary().
format_spec(V, <<>>) -> to_str(V);
format_spec(V, Spec) when is_binary(Spec) ->
    {Align, Fill, Rest1} = parse_align(Spec),
    {Sign, Rest2} = parse_sign(Rest1),
    {Width, Rest3} = take_number(Rest2),
    {Prec, Rest4} = case Rest3 of
                        <<".", R/binary>> ->
                            {P, R2} = take_number(R),
                            {P, R2};
                        _ -> {none, Rest3}
                    end,
    Type = Rest4,
    S = format_typed(V, Type, Prec, Sign),
    apply_align(S, Width, Align, Fill).

parse_align(<<F, A, Rest/binary>>) when A =:= $<; A =:= $>; A =:= $^; A =:= $= ->
    {A, <<F>>, Rest};
parse_align(<<A, Rest/binary>>) when A =:= $<; A =:= $>; A =:= $^; A =:= $= ->
    {A, <<" ">>, Rest};
parse_align(Rest) -> {$<, <<" ">>, Rest}.

parse_sign(<<S, Rest/binary>>) when S =:= $+; S =:= $-; S =:= $\s -> {S, Rest};
parse_sign(Rest) -> {none, Rest}.

take_number(S) -> take_number(S, none).
take_number(<<C, Rest/binary>>, Acc) when C >= $0, C =< $9 ->
    D = C - $0,
    NewAcc = case Acc of none -> D; _ -> Acc * 10 + D end,
    take_number(Rest, NewAcc);
take_number(Rest, Acc) -> {Acc, Rest}.

format_typed(V, <<>>, Prec, _Sign) ->
    S = to_str(V),
    apply_prec(S, Prec);
format_typed(V, <<"s">>, Prec, _Sign) -> apply_prec(to_str(V), Prec);
format_typed(V, <<"r">>, _Prec, _Sign) -> to_repr(V);
format_typed(V, <<"d">>, _Prec, Sign) when is_integer(V) ->
    format_int_sign(V, Sign, fun integer_to_binary/1);
format_typed(V, <<"x">>, _Prec, Sign) when is_integer(V) ->
    format_int_sign(V, Sign, fun(I) -> list_to_binary(string:lowercase(integer_to_list(I, 16))) end);
format_typed(V, <<"X">>, _Prec, Sign) when is_integer(V) ->
    format_int_sign(V, Sign, fun(I) -> list_to_binary(integer_to_list(I, 16)) end);
format_typed(V, <<"o">>, _Prec, Sign) when is_integer(V) ->
    format_int_sign(V, Sign, fun(I) -> list_to_binary(integer_to_list(I, 8)) end);
format_typed(V, <<"b">>, _Prec, Sign) when is_integer(V) ->
    format_int_sign(V, Sign, fun(I) -> list_to_binary(integer_to_list(I, 2)) end);
format_typed(V, <<"f">>, Prec, Sign) when is_number(V) ->
    P = case Prec of none -> 6; _ -> Prec end,
    format_float_sign(float(V), Sign, fun(F) -> float_to_binary(F, [{decimals, P}]) end);
format_typed(V, <<"e">>, Prec, Sign) when is_number(V) ->
    P = case Prec of none -> 6; _ -> Prec end,
    format_float_sign(float(V), Sign, fun(F) -> float_to_binary(F, [{scientific, P}]) end);
format_typed(V, <<"%">>, Prec, _Sign) when is_number(V) ->
    P = case Prec of none -> 6; _ -> Prec end,
    S = float_to_binary(float(V) * 100, [{decimals, P}]),
    <<S/binary, "%">>;
format_typed(V, <<"g">>, Prec, _Sign) when is_number(V) ->
    _ = Prec,
    to_str(V);
format_typed(V, <<"c">>, _Prec, _Sign) when is_integer(V) ->
    unicode:characters_to_binary([V]);
format_typed(V, T, _Prec, _Sign) ->
    raise_exc('ValueError', <<"unknown format code '", T/binary, "' for value ",
              (to_repr(V))/binary>>).

apply_prec(S, none) -> S;
apply_prec(S, P) -> binary:part(S, 0, erlang:min(P, byte_size(S))).

format_int_sign(V, _Sign, F) when V < 0 ->
    <<"-", (F(-V))/binary>>;
format_int_sign(V, $+, F) -> <<"+", (F(V))/binary>>;
format_int_sign(V, $\s, F) -> <<" ", (F(V))/binary>>;
format_int_sign(V, _, F) -> F(V).

format_float_sign(V, _Sign, F) when V < 0 ->
    <<"-", (F(-V))/binary>>;
format_float_sign(V, $+, F) -> <<"+", (F(V))/binary>>;
format_float_sign(V, $\s, F) -> <<" ", (F(V))/binary>>;
format_float_sign(V, _, F) -> F(V).

apply_align(S, none, _Align, _Fill) -> S;
apply_align(S, Width, Align, Fill) ->
    Len = length(unicode:characters_to_list(S)),
    case Len >= Width of
        true -> S;
        false ->
            Pad = Width - Len,
            case Align of
                $< -> pad_right(S, Pad, Fill);
                $= -> pad_right(S, Pad, Fill);
                $> -> pad_left(S, Pad, Fill);
                $^ ->
                    L = Pad div 2,
                    R = Pad - L,
                    pad_left(pad_right(S, R, Fill), L, Fill)
            end
    end.

pad_left(S, N, Fill) ->
    Padding = binary:copy(Fill, N),
    <<Padding/binary, S/binary>>.

pad_right(S, N, Fill) ->
    Padding = binary:copy(Fill, N),
    <<S/binary, Padding/binary>>.

%% printf-style % formatting
format_percent(Fmt, Args) ->
    ArgList = case Args of
                  T when is_tuple(T), (not ?TAGGED(T)) -> tuple_to_list(T);
                  M when is_map(M) -> [M];
                  L when is_list(L) -> [L];
                  X -> [X]
              end,
    format_percent_(Fmt, ArgList, []).

format_percent_(<<>>, _Args, Acc) -> iolist_to_binary(lists:reverse(Acc));
format_percent_(<<"%%", Rest/binary>>, Args, Acc) ->
    format_percent_(Rest, Args, [<<"%">> | Acc]);
format_percent_(<<"%s", Rest/binary>>, [A | Args], Acc) ->
    format_percent_(Rest, Args, [to_str(A) | Acc]);
format_percent_(<<"%r", Rest/binary>>, [A | Args], Acc) ->
    format_percent_(Rest, Args, [to_repr(A) | Acc]);
format_percent_(<<"%d", Rest/binary>>, [A | Args], Acc) when is_integer(A) ->
    format_percent_(Rest, Args, [integer_to_binary(A) | Acc]);
format_percent_(<<"%i", Rest/binary>>, [A | Args], Acc) when is_integer(A) ->
    format_percent_(Rest, Args, [integer_to_binary(A) | Acc]);
format_percent_(<<"%f", Rest/binary>>, [A | Args], Acc) when is_number(A) ->
    format_percent_(Rest, Args, [float_to_binary(float(A), [{decimals, 6}]) | Acc]);
format_percent_(<<"%x", Rest/binary>>, [A | Args], Acc) when is_integer(A) ->
    format_percent_(Rest, Args, [list_to_binary(integer_to_list(A, 16)) | Acc]);
format_percent_(<<"%(", _/binary>> = F, [M | Args], Acc) when is_map(M) ->
    case binary:match(F, <<")s">>) of
        {Idx, 2} ->
            KeyBin = binary:part(F, 2, Idx - 2),
            Key = binary_to_atom(KeyBin, utf8),
            V = maps:get(Key, M, maps:get(KeyBin, M, <<>>)),
            Rest = binary:part(F, Idx + 2, byte_size(F) - Idx - 2),
            format_percent_(Rest, Args, [to_str(V) | Acc]);
        nomatch ->
            raise_exc('ValueError', <<"incomplete format key">>)
    end;
format_percent_(<<C, Rest/binary>>, Args, Acc) ->
    format_percent_(Rest, Args, [<<C>> | Acc]);
format_percent_(<<>>, [_ | _], _Acc) ->
    raise_exc('TypeError', <<"not all arguments converted during string formatting">>).

%%====================================================================
%% Builtins (protocol: (PosArgs :: list(), KwArgs :: map()))
%%====================================================================

builtins() ->
    [print, len, str, repr, int, float, bool, list, tuple, dict, set,
     frozenset, range, enumerate, zip, map, filter, sorted, reversed, sum,
     min, max, abs, all, any, chr, ord, hex, oct, bin, round, divmod, pow,
     hash, id, callable, hasattr, getattr, setattr, isinstance, issubclass,
     type, input, open, argv, exit].

get_builtin(getattr) -> {slop_rt, getattr_wrap};
get_builtin(setattr) -> {slop_rt, setattr_wrap};
get_builtin(Name) ->
    case lists:member(Name, builtins()) of
        true -> {slop_rt, Name};
        false -> error
    end.

print(Pos, Kw) ->
    Sep = maps:get(sep, Kw, <<" ">>),
    End = maps:get('end', Kw, <<"\n">>),
    Strs = [to_str(P) || P <- Pos],
    Out = join_iolist(Strs, Sep),
    io:put_chars([Out, End]),
    ?NIL.

len([X], _) -> length_of(X);
len(_, _) -> raise_exc('TypeError', <<"len() takes exactly one argument">>).

length_of(X) when is_binary(X) -> length(unicode:characters_to_list(X));
length_of(X) when is_list(X) -> length(X);
length_of(X) when is_tuple(X) ->
    case is_record_tag(X) of
        true ->
            case X of
                {'$set', S} -> map_size(S);
                _ -> raise_exc('TypeError', <<"object has no len()">>)
            end;
        false -> tuple_size(X)
    end;
length_of(X) when is_map(X) ->
    case X of
        #{'$class' := C} ->
            case method_lookup(C, '__len__') of
                {ok, M} ->
                    R = invoke({'$bound', M, X}, [], #{}),
                    case is_integer(R) of
                        true -> R;
                        false -> raise_exc('TypeError', <<"__len__ should return int">>)
                    end;
                error ->
                    raise_exc('TypeError', <<"object of type '",
                              (exc_class_name(C))/binary, "' has no len()">>)
            end;
        _ -> map_size(X)
    end;
length_of(X) ->
    raise_exc('TypeError', <<"object of type '", (to_str(type_of(X)))/binary,
              "' has no len()">>).

str(Pos, Kw) -> instantiate_builtin('str', Pos, Kw).
atom([B], _) when is_binary(B) -> binary_to_atom(B, utf8);
atom([A], _) when is_atom(A) -> A;
atom(_, _) -> raise_exc('TypeError', <<"atom() expects a string">>).

erl_mod(M) when is_atom(M) -> {'$erl_mod', M}.

%% **dict in calls: keyword names are atoms; convert string keys
kw_from_dict(M) when is_map(M) ->
    maps:fold(fun(K, V, Acc) when is_binary(K) ->
                      maps:put(binary_to_atom(K, utf8), V, Acc);
                 (K, V, Acc) when is_atom(K) ->
                      maps:put(K, V, Acc);
                 (K, _V, _Acc) ->
                      raise_exc('TypeError', <<"keywords must be strings, got ",
                                               (to_str(type_of(K)))/binary>>)
              end, #{}, M);
kw_from_dict(X) ->
    raise_exc('TypeError', <<"** argument must be a dict, got ", (to_str(type_of(X)))/binary>>).

%% ---- concurrency builtins ----
%% spawn(f) / spawn(f, args): run f(*args) in a new process; returns a task
%% handle. join(task) waits for completion, returning the result or
%% re-raising the task's exception. send/recv pass any SlopLang value as a
%% BEAM message.

spawn_task([F], _) -> spawn_task_1(F, []);
spawn_task([F, Args], _) when is_list(Args) -> spawn_task_1(F, Args);
spawn_task(_, _) -> raise_exc('TypeError', <<"spawn() expects a callable and optional arg list">>).

spawn_task_1(F, Args) ->
    Parent = self(),
    {Pid, Ref} = spawn_monitor(fun() ->
        Result =
            try invoke(F, Args, #{}) of
                R -> {ok, R}
            catch
                throw:{'$slop_exc', _, _} = E -> {error, E};
                Cl:Rs -> {error, {Cl, Rs}}
            end,
        Parent ! {'$slop_done', self(), Result}
    end),
    {'$task', Pid, Ref}.

join([{'$task', Pid, Ref}], _) ->
    receive
        {'$slop_done', Pid, {ok, R}} ->
            demonitor(Ref, [flush]),
            R;
        {'$slop_done', Pid, {error, {'$slop_exc', C, I}}} ->
            demonitor(Ref, [flush]),
            throw({'$slop_exc', C, I});
        {'$slop_done', Pid, {error, {Cl, Rs}}} ->
            demonitor(Ref, [flush]),
            raise_exc('RuntimeError', iolist_to_binary(
                io_lib:format("task crashed: ~p:~p", [Cl, Rs])));
        {'DOWN', Ref, process, Pid, Reason} ->
            raise_exc('RuntimeError', iolist_to_binary(
                io_lib:format("task died: ~p", [Reason])))
    end;
join(_, _) -> raise_exc('TypeError', <<"join() expects a task">>).

sleep([Ms], _) when is_integer(Ms), Ms >= 0 -> timer:sleep(Ms), ?NIL;
sleep(_, _) -> raise_exc('TypeError', <<"sleep() expects milliseconds">>).

send_msg([{'$task', Pid, _}, Msg], _) -> Pid ! Msg, ?NIL;
send_msg([Pid, Msg], _) when is_pid(Pid) -> Pid ! Msg, ?NIL;
send_msg(_, _) -> raise_exc('TypeError', <<"send() expects a pid or task and a message">>).

recv_msg([], _) ->
    receive M -> M end;
recv_msg([Timeout], _) when is_integer(Timeout), Timeout >= 0 ->
    receive M -> M
    after Timeout -> ?NIL
    end;
recv_msg(_, _) -> raise_exc('TypeError', <<"recv() expects an optional timeout">>).

self_pid([], _) -> self().

monotonic([], _) -> erlang:monotonic_time(millisecond).


repr([X], _) -> to_repr(X);
repr(_, _) -> raise_exc('TypeError', <<"repr() takes exactly one argument">>).
int(Pos, Kw) -> instantiate_builtin('int', Pos, Kw).
float(Pos, Kw) -> instantiate_builtin('float', Pos, Kw).
bool(Pos, Kw) -> instantiate_builtin('bool', Pos, Kw).
list(Pos, Kw) -> instantiate_builtin('list', Pos, Kw).
tuple(Pos, Kw) -> instantiate_builtin('tuple', Pos, Kw).
dict(Pos, Kw) -> instantiate_builtin('dict', Pos, Kw).
set(Pos, Kw) -> instantiate_builtin('set', Pos, Kw).
frozenset(Pos, Kw) -> instantiate_builtin('frozenset', Pos, Kw).

range(Pos, _Kw) ->
    {Start, Stop, Step} = case Pos of
                              [S] -> {0, S, 1};
                              [S, E] -> {S, E, 1};
                              [S, E, St] -> {S, E, St};
                              _ -> raise_exc('TypeError', <<"range expected 1 to 3 arguments">>)
                          end,
    case Step of
        0 -> raise_exc('ValueError', <<"range() arg 3 must not be zero">>);
        _ -> ok
    end,
    case is_integer(Start) andalso is_integer(Stop) andalso is_integer(Step) of
        true -> range_list(Start, Stop, Step);
        false -> raise_exc('TypeError', <<"range() arguments must be integers">>)
    end.

range_list(S, E, Step) when Step > 0, S >= E -> [];
range_list(S, E, Step) when Step < 0, S =< E -> [];
range_list(S, E, Step) when Step > 0 ->
    lists:seq(S, E - 1, Step);
range_list(S, E, Step) when Step < 0 ->
    NegStep = -Step,
    lists:reverse(lists:seq(E + 1, S, NegStep)).

enumerate([X], _) -> enumerate_(X, 0);
enumerate([X, Start], _) -> enumerate_(X, Start);
enumerate(_, _) -> raise_exc('TypeError', <<"enumerate() takes 1 or 2 arguments">>).

enumerate_(X, Start) ->
    {Pairs, _} = lists:mapfoldl(fun(V, I) -> {{I, V}, I + 1} end, Start, iter(X)),
    Pairs.

zip([], _) -> [];
zip(Args, _) when is_list(Args) ->
    Lists = [iter(A) || A <- Args],
    zip_lists(Lists).

zip_lists(Lists) ->
    case lists:any(fun(L) -> L =:= [] end, Lists) of
        true -> [];
        false ->
            Heads = [hd(L) || L <- Lists],
            Tails = [tl(L) || L <- Lists],
            [list_to_tuple(Heads) | zip_lists(Tails)]
    end.

map([F, X], _) -> [invoke(F, [V], #{}) || V <- iter(X)];
map([F | Xs], _) when length(Xs) >= 2 ->
    Lists = [iter(X) || X <- Xs],
    [invoke(F, Hs, #{}) || Hs <- zip_lists_tuples(Lists)];
map(_, _) -> raise_exc('TypeError', <<"map() requires at least 2 arguments">>).

zip_lists_tuples(Lists) ->
    case lists:any(fun(L) -> L =:= [] end, Lists) of
        true -> [];
        false ->
            Heads = [hd(L) || L <- Lists],
            Tails = [tl(L) || L <- Lists],
            [Heads | zip_lists_tuples(Tails)]
    end.

filter([?NIL, X], _) -> [V || V <- iter(X), truthy(V)];
filter([F, X], _) -> [V || V <- iter(X), truthy(invoke(F, [V], #{}))];
filter(_, _) -> raise_exc('TypeError', <<"filter() requires 2 arguments">>).

sorted([X], Kw) -> sorted_(X, Kw);
sorted(_, _) -> raise_exc('TypeError', <<"sorted() takes 1 argument">>).

sorted_(X, Kw) ->
    KeyF = maps:get(key, Kw, ?NIL),
    Rev = truthy(maps:get(reverse, Kw, false)),
    L = iter(X),
    Cmp = fun(A, B) ->
                  KA = case KeyF of ?NIL -> A; _ -> invoke(KeyF, [A], #{}) end,
                  KB = case KeyF of ?NIL -> B; _ -> invoke(KeyF, [B], #{}) end,
                  cmp("<", KA, KB)
          end,
    S = lists:sort(Cmp, L),
    case Rev of true -> lists:reverse(S); false -> S end.

reversed([X], _) -> lists:reverse(iter(X));
reversed(_, _) -> raise_exc('TypeError', <<"reversed() takes 1 argument">>).

sum([X], _) -> sum_(X, 0);
sum([X, Start], _) -> sum_(X, Start);
sum(_, _) -> raise_exc('TypeError', <<"sum() takes 1 or 2 arguments">>).

sum_(X, Start) -> lists:foldl(fun(V, Acc) -> binop("+", Acc, V) end, Start, iter(X)).

min([X], Kw) -> min_max(X, Kw, min);
min(Args, Kw) when length(Args) >= 2 -> min_max(Args, Kw, min);
min(_, _) -> raise_exc('TypeError', <<"min() requires arguments">>).

max([X], Kw) -> min_max(X, Kw, max);
max(Args, Kw) when length(Args) >= 2 -> min_max(Args, Kw, max);
max(_, _) -> raise_exc('TypeError', <<"max() requires arguments">>).

min_max(X, Kw, Which) ->
    KeyF = maps:get(key, Kw, ?NIL),
    L = iter(X),
    case L of
        [] ->
            case maps:find(default, Kw) of
                {ok, D} -> D;
                error -> raise_exc('ValueError', <<"min()/max() arg is an empty sequence">>)
            end;
        [H | T] ->
            Key = fun(V) -> case KeyF of ?NIL -> V; _ -> invoke(KeyF, [V], #{}) end end,
            Op = case Which of min -> "<"; max -> ">" end,
            lists:foldl(fun(V, Best) ->
                                case cmp(Op, Key(V), Key(Best)) of
                                    true -> V;
                                    false -> Best
                                end
                        end, H, T)
    end.

abs([X], _) when is_number(X) -> erlang:abs(X);
abs([X], _) ->
    case maybe_dunder(X, '__abs__', []) of
        {ok, V} -> V;
        error -> raise_exc('TypeError', <<"bad operand type for abs()">>)
    end;
abs(_, _) -> raise_exc('TypeError', <<"abs() takes exactly one argument">>).

all([X], _) -> lists:all(fun truthy/1, iter(X));
all(_, _) -> raise_exc('TypeError', <<"all() takes exactly one argument">>).

any([X], _) -> lists:any(fun truthy/1, iter(X));
any(_, _) -> raise_exc('TypeError', <<"any() takes exactly one argument">>).

chr([I], _) when is_integer(I), I >= 0, I =< 16#10FFFF ->
    unicode:characters_to_binary([I]);
chr(_, _) -> raise_exc('ValueError', <<"chr() arg not in range">>).

ord([C], _) when is_binary(C) ->
    case unicode:characters_to_list(C) of
        [CP] -> CP;
        _ -> raise_exc('TypeError', <<"ord() expected a character">>)
    end;
ord(_, _) -> raise_exc('TypeError', <<"ord() expected a character">>).

hex([I], _) when is_integer(I) ->
    case I < 0 of
        true -> list_to_binary("-0x" ++ integer_to_list(-I, 16));
        false -> list_to_binary("0x" ++ integer_to_list(I, 16))
    end;
hex(_, _) -> raise_exc('TypeError', <<"hex() requires an integer">>).

oct([I], _) when is_integer(I) ->
    case I < 0 of
        true -> list_to_binary("-0o" ++ integer_to_list(-I, 8));
        false -> list_to_binary("0o" ++ integer_to_list(I, 8))
    end;
oct(_, _) -> raise_exc('TypeError', <<"oct() requires an integer">>).

bin([I], _) when is_integer(I) ->
    case I < 0 of
        true -> list_to_binary("-0b" ++ integer_to_list(-I, 2));
        false -> list_to_binary("0b" ++ integer_to_list(I, 2))
    end;
bin(_, _) -> raise_exc('TypeError', <<"bin() requires an integer">>).

round([X], _) -> round2(X, 0);
round([X, N], _) when is_integer(N) -> round2(X, N);
round(_, _) -> raise_exc('TypeError', <<"round() takes 1 or 2 arguments">>).

round2(X, 0) when is_integer(X) -> X;
round2(X, 0) when is_float(X) -> round_half_even(X);
round2(X, N) when is_number(X) ->
    M = int_pow(10, erlang:abs(N)),
    case N >= 0 of
        true -> round_half_even(X * M) / M;
        false -> round_half_even(X / M) * M
    end;
round2(X, _) ->
    raise_exc('TypeError', <<"round() argument must be a number, not '",
              (to_str(type_of(X)))/binary, "'">>).

round_half_even(X) ->
    F = erlang:floor(X),
    Diff = X - F,
    if
        Diff < 0.5 -> F;
        Diff > 0.5 -> F + 1;
        true ->
            case F rem 2 of
                0 -> F;
                _ -> F + 1
            end
    end.

divmod([A, B], _) when is_number(A), is_number(B) ->
    {floordiv(A, B), pymod(A, B)};
divmod(_, _) -> raise_exc('TypeError', <<"divmod() takes 2 arguments">>).

pow([A, B], _) -> pypow(A, B);
pow([A, B, M], _) when is_integer(A), is_integer(B), is_integer(M), B >= 0 ->
    mod_pow(A, B, M);
pow(_, _) -> raise_exc('TypeError', <<"pow() takes 2 or 3 arguments">>).

mod_pow(_, 0, M) -> pymod(1, M);
mod_pow(A, B, M) ->
    R = mod_pow_(pymod(A, M), B, M, 1),
    R.

mod_pow_(_, 0, M, Acc) -> pymod(Acc, M);
mod_pow_(A, B, M, Acc) when B rem 2 =:= 1 ->
    mod_pow_(pymod(A * A, M), B div 2, M, pymod(Acc * A, M));
mod_pow_(A, B, M, Acc) ->
    mod_pow_(pymod(A * A, M), B div 2, M, Acc).

hash([X], _) -> erlang:phash2(X);
hash(_, _) -> raise_exc('TypeError', <<"hash() takes exactly one argument">>).

id([X], _) -> erlang:phash2(X);
id(_, _) -> raise_exc('TypeError', <<"id() takes exactly one argument">>).

callable([X], _) -> callable_(X);
callable(_, _) -> raise_exc('TypeError', <<"callable() takes exactly one argument">>).

callable_(X) when is_function(X, 2) -> true;
callable_({'$bound', _, _}) -> true;
callable_({'$tbound', _, _, _}) -> true;
callable_({'$static', _}) -> true;
callable_(A) when is_atom(A) ->
    is_slop_class(A) orelse lists:member(A, builtin_classes());
callable_(M) when is_map(M) ->
    case M of
        #{'$class' := C} -> method_lookup(C, '__call__') =/= error;
        _ -> false
    end;
callable_(_) -> false.

hasattr([X, Name], _) when is_atom(Name) ->
    getattr(X, Name, ?NIL) =/= ?NIL orelse has_attr_check(X, Name);
hasattr([X, Name], _) when is_binary(Name) ->
    hasattr([X, binary_to_atom(Name, utf8)], #{});
hasattr(_, _) -> raise_exc('TypeError', <<"hasattr() takes 2 arguments">>).

has_attr_check(X, Name) ->
    try
        _ = getattr(X, Name),
        true
    catch
        _:_ -> false
    end.

getattr_wrap([X, Name], _) when is_atom(Name) -> getattr(X, Name);
getattr_wrap([X, Name, Default], _) when is_atom(Name) -> getattr(X, Name, Default);
getattr_wrap([X, Name], _) when is_binary(Name) -> getattr(X, binary_to_atom(Name, utf8));
getattr_wrap([X, Name, Default], _) when is_binary(Name) ->
    getattr(X, binary_to_atom(Name, utf8), Default);
getattr_wrap(_, _) -> raise_exc('TypeError', <<"getattr() takes 2 or 3 arguments">>).

setattr_wrap([X, Name, V], _) when is_atom(Name) -> setattr(X, Name, V);
setattr_wrap([X, Name, V], _) when is_binary(Name) ->
    setattr(X, binary_to_atom(Name, utf8), V);
setattr_wrap(_, _) -> raise_exc('TypeError', <<"setattr() takes 3 arguments">>).

isinstance([X, C], _) -> isinstance_(X, C);
isinstance(_, _) -> raise_exc('TypeError', <<"isinstance() takes 2 arguments">>).

isinstance_(X, C) when is_tuple(C), (not ?TAGGED(C)) ->
    lists:any(fun(Ci) -> isinstance_(X, Ci) end, tuple_to_list(C));
isinstance_(X, C) when is_atom(C) ->
    case lists:member(C, builtin_type_classes()) of
        true -> isinstance_builtin(X, C);
        false ->
            case is_slop_class(C) orelse is_builtin_exception(C) of
                true ->
                    case X of
                        #{'$class' := XC} -> lists:member(C, mro(XC));
                        _ -> false
                    end;
                false ->
                    raise_exc('TypeError', <<"isinstance() arg 2 must be a type">>)
            end
    end;
isinstance_(_, _) ->
    raise_exc('TypeError', <<"isinstance() arg 2 must be a type">>).

isinstance_builtin(X, 'int') -> is_integer(X);
isinstance_builtin(X, 'float') -> is_float(X);
isinstance_builtin(X, 'str') -> is_binary(X);
isinstance_builtin(X, 'bool') -> X =:= true orelse X =:= false;
isinstance_builtin(X, 'list') -> is_list(X);
isinstance_builtin(X, 'tuple') -> is_tuple(X) andalso (not is_record_tag(X));
isinstance_builtin(X, 'dict') -> is_map(X) andalso (not is_map_key('$class', X));
isinstance_builtin(X, 'set') -> is_set_val(X);
isinstance_builtin(X, 'frozenset') -> is_set_val(X);
isinstance_builtin(X, 'function') -> is_function(X, 2) orelse is_bound(X);
isinstance_builtin(X, 'NoneType') -> X =:= ?NIL;
isinstance_builtin(_, 'object') -> true;
isinstance_builtin(_, _) -> false.

is_set_val({'$set', _}) -> true;
is_set_val(_) -> false.

is_bound({'$bound', _, _}) -> true;
is_bound({'$tbound', _, _, _}) -> true;
is_bound(_) -> false.

issubclass([C, B], _) when is_atom(C), is_atom(B) ->
    case (is_slop_class(C) orelse lists:member(C, builtin_classes())) of
        true -> lists:member(B, mro(C));
        false -> raise_exc('TypeError', <<"issubclass() arg 1 must be a class">>)
    end;
issubclass([C, Bs], _) when is_atom(C), is_tuple(Bs), (not ?TAGGED(Bs)) ->
    lists:any(fun(B) -> issubclass([C, B], #{}) end, tuple_to_list(Bs));
issubclass(_, _) -> raise_exc('TypeError', <<"issubclass() arguments must be classes">>).

type([X], _) -> type_of(X);
type(_, _) -> raise_exc('TypeError', <<"type() takes 1 argument">>).

input([], _) -> input_(<<"">>);
input([Prompt], _) -> input_(to_str(Prompt));
input(_, _) -> raise_exc('TypeError', <<"input() takes at most 1 argument">>).

input_(Prompt) ->
    case io:get_line(Prompt) of
        eof -> raise_exc('EOFError', <<"EOF when reading a line">>);
        Line -> string:trim(unicode:characters_to_binary(Line), trailing, "\n")
    end.

open(Pos, Kw) -> slop_file:open(Pos, Kw).

argv([], _) ->
    persistent_term:get(slop_argv, []);
argv(_, _) -> raise_exc('TypeError', <<"argv() takes no arguments">>).

exit([], _) -> halt(0);
exit([Code], _) when is_integer(Code) -> halt(Code);
exit(_, _) -> raise_exc('TypeError', <<"exit() takes at most 1 integer argument">>).

%% statement-position method-call rebind: `recv.m(...)` rebinds recv to the
%% call result only when the result has the same collection/object kind as the
%% receiver (lists, dicts, sets, same-class instances). Value-returning calls
%% (`st.pop()` -> int) leave the binding alone.
rebind(Old, New) ->
    case same_kind(Old, New) of
        true -> New;
        false -> Old
    end.

same_kind(A, B) when is_list(A), is_list(B) -> true;
same_kind({'$set', _}, {'$set', _}) -> true;
same_kind(A, B) when is_map(A), is_map(B) ->
    case {maps:get('$class', A, none), maps:get('$class', B, none)} of
        {none, none} -> true;
        {C, C} when C =/= none -> true;
        _ -> false
    end;
same_kind(_, _) -> false.
