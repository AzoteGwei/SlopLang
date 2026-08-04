%% Minimal HTTP/1.1 development server for SlopLang, built on gen_tcp with
%% OTP's built-in HTTP packet parsing. Each accepted connection is handled
%% in its own spawned process, so requests are served concurrently.
%%
%% The handler is a SlopLang callable (Pos/Kw protocol) receiving a request
%% dict with binary keys: method, path, query, headers (dict), body.
%% It must return a dict with keys: status (int), headers (dict), body
%% (str/binary).
%%
%% 0BSD — part of the SlopLang runtime.
-module(slop_http).
-export([start/3, start/2, wait/0]).

start(Port, Handler) ->
    start("127.0.0.1", Port, Handler).

start(Host, Port, Handler) when is_binary(Host), is_integer(Port) ->
    {ok, Addr} = inet:parse_address(binary_to_list(Host)),
    Opts = [binary, {packet, http_bin}, {active, false}, {reuseaddr, true},
            {backlog, 128}, {ip, Addr}, {nodelay, true}],
    case gen_tcp:listen(Port, Opts) of
        {ok, LSock} ->
            {ok, RealPort} = inet:port(LSock),
            Pid = spawn_link(fun() -> accept_loop(LSock, Handler) end),
            {ok, RealPort, Pid};
        {error, Reason} ->
            {error, Reason}
    end.

%% block forever (dev-server semantics: run() never returns)
wait() ->
    receive
        stop -> ok
    end.

accept_loop(LSock, Handler) ->
    case gen_tcp:accept(LSock) of
        {ok, Sock} ->
            spawn(fun() -> handle_conn(Sock, Handler) end),
            accept_loop(LSock, Handler);
        {error, closed} ->
            ok;
        {error, _} ->
            timer:sleep(10),
            accept_loop(LSock, Handler)
    end.

handle_conn(Sock, Handler) ->
    try
        case read_request(Sock) of
            {ok, Req} ->
                Resp = slop_rt:invoke(Handler, [Req], #{}),
                send_response(Sock, Resp);
            {error, _} ->
                send_raw(Sock, 400, <<"Bad Request">>, #{}, <<"bad request\n">>)
        end
    catch
        throw:{'$slop_exc', C, I} ->
            Sl = slop_rt:print_exc(C, I),
            send_raw(Sock, 500, <<"Internal Server Error">>, #{},
                     [<<"uncaught SlopLang exception\n">>, Sl]);
        _:_ ->
            send_raw(Sock, 500, <<"Internal Server Error">>, #{}, <<"internal error\n">>)
    after
        gen_tcp:close(Sock)
    end.

read_request(Sock) ->
    case gen_tcp:recv(Sock, 0, 10000) of
        {ok, {http_request, Method, {abs_path, FullPath}, _Ver}} ->
            case read_headers(Sock, #{}) of
                {ok, Headers} ->
                    case read_body(Sock, Headers) of
                        {ok, Body} ->
                            {Path, Query} = split_path(FullPath),
                            {ok, #{<<"method">> => method_bin(Method),
                                   <<"path">> => Path,
                                   <<"query">> => Query,
                                   <<"headers">> => Headers,
                                   <<"body">> => Body}};
                        Error -> Error
                    end;
                Error -> Error
            end;
        {ok, {http_error, _}} ->
            {error, bad_request};
        {error, Reason} ->
            {error, Reason}
    end.

read_headers(Sock, Acc) ->
    case gen_tcp:recv(Sock, 0, 10000) of
        {ok, {http_header, _, Name, _, Value}} ->
            K = header_name(Name),
            read_headers(Sock, maps:put(K, Value, Acc));
        {ok, http_eoh} ->
            {ok, Acc};
        {ok, {http_error, _}} ->
            {error, bad_header};
        {error, Reason} ->
            {error, Reason}
    end.

header_name(A) when is_atom(A) -> atom_to_binary(A, utf8);
header_name(B) when is_binary(B) -> B.

read_body(Sock, Headers) ->
    Len = case maps:get(<<"Content-Length">>, Headers, nil) of
        nil -> 0;
        B -> try binary_to_integer(B) catch _:_ -> 0 end
    end,
    inet:setopts(Sock, [{packet, raw}]),
    case Len of
        0 -> {ok, <<>>};
        _ -> gen_tcp:recv(Sock, Len, 10000)
    end.

split_path(Full) ->
    case binary:split(Full, <<"?">>) of
        [P] -> {P, <<>>};
        [P, Q] -> {P, Q}
    end.

method_bin(M) when is_atom(M) ->
    list_to_binary(string:uppercase(atom_to_list(M)));
method_bin(B) when is_binary(B) ->
    B.

send_response(Sock, Resp) when is_map(Resp) ->
    Status = maps:get(<<"status">>, Resp, 200),
    Headers = maps:get(<<"headers">>, Resp, #{}),
    Body = maps:get(<<"body">>, Resp, <<>>),
    send_raw(Sock, Status, reason(Status), Headers, Body).

send_raw(Sock, Status, Reason, Headers, Body) ->
    Bin = iolist_to_binary(Body),
    Hs0 = maps:merge(#{<<"Content-Type">> => <<"text/html; charset=utf-8">>}, Headers),
    Hs = maps:merge(Hs0, #{<<"Content-Length">> => integer_to_binary(byte_size(Bin)),
                           <<"Connection">> => <<"close">>}),
    Lines = [[K, ": ", V, "\r\n"] || {K, V} <- maps:to_list(Hs)],
    Data = [<<"HTTP/1.1 ">>, integer_to_binary(Status), " ", Reason, "\r\n",
            Lines, "\r\n", Bin],
    gen_tcp:send(Sock, Data).

reason(200) -> <<"OK">>;
reason(201) -> <<"Created">>;
reason(204) -> <<"No Content">>;
reason(301) -> <<"Moved Permanently">>;
reason(302) -> <<"Found">>;
reason(303) -> <<"See Other">>;
reason(304) -> <<"Not Modified">>;
reason(400) -> <<"Bad Request">>;
reason(401) -> <<"Unauthorized">>;
reason(403) -> <<"Forbidden">>;
reason(404) -> <<"Not Found">>;
reason(405) -> <<"Method Not Allowed">>;
reason(409) -> <<"Conflict">>;
reason(418) -> <<"I'm a teapot">>;
reason(500) -> <<"Internal Server Error">>;
reason(502) -> <<"Bad Gateway">>;
reason(503) -> <<"Service Unavailable">>;
reason(N) -> <<"Status ", (integer_to_binary(N))/binary>>.
