%% slop_file.erl - SlopLang file objects: {'$slop_file', IoDevice}.
-module(slop_file).
-export([open/2, read/3, readline/3, readlines/3, write/3, writelines/3,
         close/3, flush/3, seek/3, tell/3, '__enter__'/3, '__exit__'/3]).

-import(slop_rt, [raise_exc/2, to_str/1]).

open(Pos, Kw) ->
    {Path, Mode} = case Pos of
                       [P] -> {to_str(P), maps:get(mode, Kw, <<"r">>)};
                       [P, M] -> {to_str(P), to_str(M)};
                       _ -> raise_exc('TypeError', <<"open() takes 1 or 2 arguments">>)
                   end,
    Modes = mode_flags(Mode),
    case file:open(Path, Modes) of
        {ok, Io} -> {'$slop_file', Io};
        {error, enoent} ->
            raise_exc('FileNotFoundError',
                      <<"No such file or directory: '", Path/binary, "'">>);
        {error, Reason} ->
            raise_exc('OSError', iolist_to_binary(
                      io_lib:format("~s: '~s'", [atom_to_list(Reason), binary_to_list(Path)])))
    end.

mode_flags(Mode) ->
    Base = case Mode of
               <<"r">> -> [read];
               <<"w">> -> [write];
               <<"a">> -> [append];
               <<"r+">> -> [read, write];
               <<"w+">> -> [read, write];
               <<"a+">> -> [read, append];
               <<"rb">> -> [read, raw, binary];
               <<"wb">> -> [write, raw, binary];
               <<"ab">> -> [append, raw, binary];
               _ -> raise_exc('ValueError', <<"invalid mode: '", Mode/binary, "'">>)
           end,
    Base.

read({'$slop_file', Io}, Pos, _Kw) ->
    case Pos of
        [] -> read_all(Io);
        [N] when is_integer(N), N >= 0 ->
            case file:read(Io, N) of
                {ok, Data} -> iolist_to_binary(Data);
                eof -> <<>>;
                {error, R} -> raise_exc('OSError', atom_to_binary(R, utf8))
            end;
        _ -> raise_exc('TypeError', <<"read() takes at most one integer argument">>)
    end.

read_all(Io) ->
    case file:read(Io, 65536) of
        {ok, Data} ->
            Rest = read_all(Io),
            iolist_to_binary([Data, Rest]);
        eof -> <<>>;
        {error, R} -> raise_exc('OSError', atom_to_binary(R, utf8))
    end.

readline({'$slop_file', Io}, _, _) ->
    case file:read_line(Io) of
        {ok, Data} -> iolist_to_binary(Data);
        eof -> <<>>;
        {error, R} -> raise_exc('OSError', atom_to_binary(R, utf8))
    end.

readlines({'$slop_file', _} = F, _, _) ->
    readlines_(F, []).

readlines_(F, Acc) ->
    case readline(F, [], #{}) of
        <<>> -> lists:reverse(Acc);
        Line -> readlines_(F, [Line | Acc])
    end.

write({'$slop_file', Io} = F, [Data], _Kw) ->
    case file:write(Io, to_str(Data)) of
        ok -> F;
        {error, R} -> raise_exc('OSError', atom_to_binary(R, utf8))
    end;
write(_, _, _) -> raise_exc('TypeError', <<"write() takes exactly one argument">>).

writelines({'$slop_file', _} = F, [Lines], _Kw) ->
    lists:foreach(fun(L) -> _ = write(F, [L], #{}) end, slop_rt:iter(Lines)),
    F;
writelines(_, _, _) -> raise_exc('TypeError', <<"writelines() takes exactly one argument">>).

close({'$slop_file', Io}, _, _) ->
    file:close(Io),
    nil.

flush({'$slop_file', Io} = F, _, _) ->
    _ = Io,
    F.

seek({'$slop_file', Io}, [Offset], _Kw) when is_integer(Offset) ->
    case file:position(Io, {bof, Offset}) of
        {ok, Pos} -> Pos;
        {error, R} -> raise_exc('OSError', atom_to_binary(R, utf8))
    end;
seek(_, _, _) -> raise_exc('TypeError', <<"seek() takes an integer argument">>).

tell({'$slop_file', Io}, _, _) ->
    case file:position(Io, cur) of
        {ok, Pos} -> Pos;
        {error, R} -> raise_exc('OSError', atom_to_binary(R, utf8))
    end.

'__enter__'({'$slop_file', _} = F, _, _) -> F.
'__exit__'({'$slop_file', _} = F, _, _) ->
    _ = close(F, [], #{}),
    false.
