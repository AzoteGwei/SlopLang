defmodule Slop.Lexer do
  @moduledoc """
  Indentation-aware tokenizer for SlopLang source.

  Produces tokens of the shape {kind, line, value} where kind is one of:
  :name, :int, :float, :str, :fstring, :op, :kw, :newline, :indent, :dedent, :eof
  """

  @keywords ~w(and as assert break class continue def del elif else except
    finally for from global if import in is lambda match case None True False
    not or pass raise return try while with nonlocal yield async await)

  @ops3 ~w(**= //= <<= >>= ...)
  @ops2 ~w(** // << >> == != <= >= += -= *= /= %= &= |= ^= := -> && ||)
  @ops1 String.graphemes("()[]{},:;.@=+-*/%<>|&^~")

  defstruct src: "", line: 1, indents: [0], depth: 0, tokens: [], at_line_start: true

  def tokenize(src) when is_binary(src) do
    case run(%__MODULE__{src: src}) do
      {:error, _, _} = err -> err
      st -> {:ok, finalize(st)}
    end
  end

  defp finalize(st) do
    toks =
      if st.at_line_start do
        st.tokens
      else
        [{:newline, st.line, nil} | st.tokens]
      end

    toks = Enum.reduce(st.indents, toks, fn
      0, acc -> acc
      _, acc -> [{:dedent, st.line, nil} | acc]
    end)

    Enum.reverse([{:eof, st.line, nil} | toks])
  end

  defp emit(st, tok), do: %{st | tokens: [tok | st.tokens]}

  defp err(line, msg), do: {:error, line, msg}

  # ---------------- main loop ----------------

  defp run(%{src: ""} = st), do: st

  # newline: end of logical line (unless inside brackets)
  defp run(%{src: "\r\n" <> rest} = st), do: run(%{st | src: "\n" <> rest})
  defp run(%{src: "\n" <> rest, depth: 0} = st) do
    st = if st.at_line_start, do: st, else: emit(st, {:newline, st.line, nil})
    run(%{st | src: rest, line: st.line + 1, at_line_start: true})
  end

  defp run(%{src: "\n" <> rest} = st) do
    run(%{st | src: rest, line: st.line + 1})
  end

  # explicit line continuation
  defp run(%{src: "\\\r\n" <> rest} = st), do: run(%{st | src: rest, line: st.line + 1})
  defp run(%{src: "\\\n" <> rest} = st), do: run(%{st | src: rest, line: st.line + 1})

  # comments
  defp run(%{src: "#" <> rest} = st) do
    rest = skip_to_eol(rest)
    run(%{st | src: rest})
  end

  # whitespace within a line
  defp run(%{src: <<c, rest::binary>>} = st) when c in [?\s, ?\t] and not (st.at_line_start and st.depth == 0) do
    run(%{st | src: rest})
  end

  # indentation handling at line start
  defp run(%{at_line_start: true, depth: 0} = st) do
    {indent, rest} = measure_indent(st.src, 0)

    case rest do
      "" ->
        %{st | src: ""}

      "\r\n" <> _ ->
        run(%{st | src: rest})

      "\n" <> _ ->
        run(%{st | src: rest})

      "#" <> _ ->
        run(%{st | src: rest})

      _ ->
        case handle_indent(st, indent) do
          {:error, _, _} = e -> e
          st -> run(%{st | src: rest, at_line_start: false})
        end
    end
  end

  # numbers
  defp run(%{src: <<c, _::binary>>} = st) when c >= ?0 and c <= ?9 do
    case lex_number(st.src, st.line) do
      {:ok, tok, rest} -> run(emit(%{st | src: rest}, tok))
      {:error, _, _} = e -> e
    end
  end

  defp run(%{src: <<?., c, _::binary>>} = st) when c >= ?0 and c <= ?9 do
    case lex_number("0" <> st.src, st.line) do
      {:ok, tok, rest} -> run(emit(%{st | src: rest}, tok))
      {:error, _, _} = e -> e
    end
  end

  # strings / fstrings / names
  defp run(%{src: <<c, _::binary>>} = st) when c == ?' or c == ?" do
    case lex_string(st.src, st.line, []) do
      {:ok, tok, rest} -> run(emit(%{st | src: rest}, tok))
      {:error, _, _} = e -> e
    end
  end

  defp run(%{src: <<c, _::binary>>} = st) when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or c == ?_ do
    {word, rest} = take_ident(st.src, "")
    down = String.downcase(word)

    cond do
      down in ~w(r f b fr rf rb br bf) and String.starts_with?(rest, ["'", "\""]) ->
        flags = String.graphemes(String.downcase(word))
        case lex_string(rest, st.line, flags) do
          {:ok, tok, rest2} -> run(emit(%{st | src: rest2}, tok))
          {:error, _, _} = e -> e
        end

      word in @keywords ->
        run(emit(%{st | src: rest}, {:kw, st.line, word}))

      true ->
        run(emit(%{st | src: rest}, {:name, st.line, word}))
    end
  end

  # operators
  defp run(st) do
    {op3, op2, op1} = {@ops3, @ops2, @ops1}

    cond do
      match = Enum.find(op3, &String.starts_with?(st.src, &1)) ->
        run(emit(%{st | src: String.slice(st.src, 3..-1//1)}, {:op, st.line, match}))

      match = Enum.find(op2, &String.starts_with?(st.src, &1)) ->
        run(emit(%{st | src: String.slice(st.src, 2..-1//1)}, {:op, st.line, match}))

      match = Enum.find(op1, &String.starts_with?(st.src, &1)) ->
        st = %{st | src: String.slice(st.src, 1..-1//1)}
        st = update_depth(st, match)
        run(emit(st, {:op, st.line, match}))

      true ->
        <<c, _::binary>> = st.src
        err(st.line, "unexpected character #{inspect(<<c>>)}")
    end
  end

  defp update_depth(st, op) when op in ["(", "[", "{"], do: %{st | depth: st.depth + 1}
  defp update_depth(st, op) when op in [")", "]", "}"], do: %{st | depth: max(st.depth - 1, 0)}
  defp update_depth(st, _), do: st

  defp skip_to_eol(<<"\n", _::binary>> = rest), do: rest
  defp skip_to_eol(""), do: ""
  defp skip_to_eol(<<_, rest::binary>>), do: skip_to_eol(rest)

  defp measure_indent(<<c, rest::binary>>, acc) when c == ?\s, do: measure_indent(rest, acc + 1)
  defp measure_indent(<<c, rest::binary>>, acc) when c == ?\t, do: measure_indent(rest, acc + (8 - rem(acc, 8)))
  defp measure_indent(rest, acc), do: {acc, rest}

  defp handle_indent(%{indents: [top | _]} = st, indent) when indent > top do
    %{st | indents: [indent | st.indents]} |> emit({:indent, st.line, nil})
  end

  defp handle_indent(%{indents: [top | _]} = st, indent) when indent == top, do: st

  defp handle_indent(%{indents: indents} = st, indent) do
    {pops, rest_stack} = Enum.split_while(indents, &(&1 > indent))

    if rest_stack == [] or hd(rest_stack) != indent do
      err(st.line, "inconsistent dedent")
    else
      st = %{st | indents: rest_stack}
      Enum.reduce(1..length(pops), st, fn _, acc -> emit(acc, {:dedent, st.line, nil}) end)
    end
  end

  defp take_ident(<<c, rest::binary>>, acc)
       when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or (c >= ?0 and c <= ?9) or c == ?_ do
    take_ident(rest, <<acc::binary, c>>)
  end

  defp take_ident(rest, acc), do: {acc, rest}

  # ---------------- numbers ----------------

  defp lex_number(<<"0x", rest::binary>>, line), do: based_int(rest, line, 16)
  defp lex_number(<<"0X", rest::binary>>, line), do: based_int(rest, line, 16)
  defp lex_number(<<"0o", rest::binary>>, line), do: based_int(rest, line, 8)
  defp lex_number(<<"0O", rest::binary>>, line), do: based_int(rest, line, 8)
  defp lex_number(<<"0b", rest::binary>>, line), do: based_int(rest, line, 2)
  defp lex_number(<<"0B", rest::binary>>, line), do: based_int(rest, line, 2)

  defp lex_number(src, line) do
    {intpart, rest} = take_digits(src, "")

    {fracpart, rest2} =
      case rest do
        <<".", c, _::binary>> = r when c >= ?0 and c <= ?9 ->
          {f, r2} = take_digits(String.slice(r, 1..-1//1), "")
          {f, r2}

        <<".", c, _::binary>> when c != ?. ->
          {"", String.slice(rest, 1..-1//1)}

        _ ->
          {nil, rest}
      end

    {exppart, rest3} =
      case rest2 do
        <<e, _::binary>> = r when e in [?e, ?E] ->
          case take_exponent(r) do
            {:ok, ex, r2} -> {ex, r2}
            :none -> {nil, rest2}
          end

        _ ->
          {nil, rest2}
      end

    cond do
      fracpart != nil or exppart != nil ->
        frac = if fracpart in [nil, ""], do: "0", else: fracpart
        str = intpart <> "." <> frac
        str = if exppart, do: str <> "e" <> exppart, else: str
        str = String.replace(str, "_", "")
        case Float.parse(str) do
          {val, ""} -> {:ok, {:float, line, val}, rest3}
          _ -> err(line, "invalid float literal #{str}")
        end

      true ->
        clean = String.replace(intpart, "_", "")
        {:ok, {:int, line, String.to_integer(clean)}, rest}
    end
  end

  defp based_int(src, line, base) do
    {digits, rest} = take_based_digits(src, base, "")

    if digits == "" do
      err(line, "invalid based integer literal")
    else
      {:ok, {:int, line, String.to_integer(String.replace(digits, "_", ""), base)}, rest}
    end
  end

  defp take_digits(<<c, rest::binary>>, acc) when (c >= ?0 and c <= ?9) or c == ?_,
    do: take_digits(rest, <<acc::binary, c>>)

  defp take_digits(rest, acc), do: {acc, rest}

  defp take_based_digits(<<c, rest::binary>>, base, acc) do
    valid =
      case base do
        16 -> (c >= ?0 and c <= ?9) or (c >= ?a and c <= ?f) or (c >= ?A and c <= ?F) or c == ?_
        8 -> (c >= ?0 and c <= ?7) or c == ?_
        2 -> c == ?0 or c == ?1 or c == ?_
      end

    if valid, do: take_based_digits(rest, base, <<acc::binary, c>>), else: {acc, rest}
  end

  defp take_based_digits(rest, _base, acc), do: {acc, rest}

  defp take_exponent(<<e, rest::binary>>) when e in [?e, ?E] do
    {sign, rest2} =
      case rest do
        <<s, r::binary>> when s in [?+, ?-] -> {<<s>>, r}
        _ -> {"", rest}
      end

    {digits, rest3} = take_digits(rest2, "")

    if digits == "" do
      :none
    else
      {:ok, sign <> digits, rest3}
    end
  end

  # ---------------- strings ----------------

  # flags: subset of ["r","f","b"]
  defp lex_string(src, line, flags) do
    {quote, qlen} =
      cond do
        String.starts_with?(src, "'''") -> {"'''", 3}
        String.starts_with?(src, ~S(""")) -> {~S("""), 3}
        String.starts_with?(src, "'") -> {"'", 1}
        true -> {~S("), 1}
      end

    body = String.slice(src, qlen..-1//1)
    raw? = "r" in flags
    fstr? = "f" in flags

    case scan_string(body, quote, line, raw?, fstr?, "") do
      {:ok, content, rest} ->
        kind = if fstr?, do: :fstring, else: :str
        value = if raw? or fstr?, do: content, else: unescape(content, line)
        {:ok, {kind, line, {value, flags}}, rest}

      {:error, _, _} = e ->
        e
    end
  end

  defp scan_string("", _q, line, _raw, _f, _acc), do: err(line, "unterminated string literal")

  defp scan_string(src, quote, line, raw?, fstr?, acc) do
    qlen = byte_size(quote)

    cond do
      String.starts_with?(src, quote) ->
        {:ok, acc, String.slice(src, qlen..-1//1)}

      String.starts_with?(src, "\\") and not raw? ->
        case src do
          <<_, c, rest::binary>> ->
            scan_string(rest, quote, line, raw?, fstr?, acc <> "\\" <> <<c>>)

          _ ->
            err(line, "unterminated string literal")
        end

      String.starts_with?(src, "\\") and raw? ->
        case src do
          <<_, c, rest::binary>> -> scan_string(rest, quote, line, raw?, fstr?, acc <> "\\" <> <<c>>)
          _ -> err(line, "unterminated string literal")
        end

      fstr? and String.starts_with?(src, "{") ->
        # possible expression start: skip balanced braces, watching for nested strings
        case skip_braced(src, line) do
          {:ok, chunk, rest} -> scan_string(rest, quote, line, raw?, fstr?, acc <> chunk)
          :literal -> scan_string(String.slice(src, 1..-1//1), quote, line, raw?, fstr?, acc <> "{")
          {:error, _, _} = e -> e
        end

      String.starts_with?(src, "\n") and byte_size(quote) == 1 ->
        err(line, "unterminated string literal (newline in string)")

      true ->
        <<c, rest::binary>> = src
        scan_string(rest, quote, line, raw?, fstr?, acc <> <<c>>)
    end
  end

  # returns {:ok, chunk_including_braces, rest} | :literal (for {{) | error
  defp skip_braced("{{" <> rest, _line), do: {:ok, "{{", rest}

  defp skip_braced("{" <> _ = src, line) do
    case brace_scan(src, 0, line, "") do
      {:ok, chunk, rest} -> {:ok, chunk, rest}
      {:error, _, _} = e -> e
    end
  end

  defp brace_scan("", _d, line, _acc), do: err(line, "unterminated '{' in f-string")

  defp brace_scan("{" <> rest, d, line, acc), do: brace_scan(rest, d + 1, line, acc <> "{")

  defp brace_scan("}" <> rest, 1, _line, acc), do: {:ok, acc <> "}", rest}
  defp brace_scan("}" <> rest, d, line, acc), do: brace_scan(rest, d - 1, line, acc <> "}")

  defp brace_scan(<<q, _::binary>> = src, d, line, acc) when q == ?' or q == ?" do
    {quote, qlen} =
      cond do
        String.starts_with?(src, "'''") -> {"'''", 3}
        String.starts_with?(src, ~S(""")) -> {~S("""), 3}
        q == ?' -> {"'", 1}
        true -> {~S("), 1}
      end

    body = String.slice(src, qlen..-1//1)

    case scan_string(body, quote, line, false, false, "") do
      {:ok, content, rest} ->
        brace_scan(rest, d, line, acc <> String.slice(src, 0, qlen) <> content <> quote)

      {:error, _, _} = e ->
        e
    end
  end

  defp brace_scan(<<c, rest::binary>>, d, line, acc), do: brace_scan(rest, d, line, acc <> <<c>>)

  defp unescape(str, line), do: unescape(str, line, "")

  defp unescape("", _line, acc), do: acc

  defp unescape("\\" <> rest, line, acc) do
    case rest do
      "n" <> r -> unescape(r, line, acc <> "\n")
      "t" <> r -> unescape(r, line, acc <> "\t")
      "r" <> r -> unescape(r, line, acc <> "\r")
      "0" <> r -> unescape(r, line, acc <> <<0>>)
      "a" <> r -> unescape(r, line, acc <> <<7>>)
      "b" <> r -> unescape(r, line, acc <> <<8>>)
      "f" <> r -> unescape(r, line, acc <> <<12>>)
      "v" <> r -> unescape(r, line, acc <> <<11>>)
      "\\" <> r -> unescape(r, line, acc <> "\\")
      "'" <> r -> unescape(r, line, acc <> "'")
      "\"" <> r -> unescape(r, line, acc <> "\"")
      "\n" <> r -> unescape(r, line, acc)
      "x" <> r -> hex_escape(r, 2, line, acc)
      "u" <> r -> hex_escape(r, 4, line, acc)
      "U" <> r -> hex_escape(r, 8, line, acc)
      <<c, r::binary>> -> unescape(r, line, acc <> "\\" <> <<c>>)
      "" -> acc <> "\\"
    end
  end

  defp unescape(<<c, rest::binary>>, line, acc), do: unescape(rest, line, acc <> <<c>>)

  defp hex_escape(src, n, line, acc) do
    hexs = String.slice(src, 0, n)
    rest = String.slice(src, n..-1//1)

    case Integer.parse(hexs || "", 16) do
      {val, ""} when byte_size(hexs) == n ->
        unescape(rest, line, acc <> <<val::utf8>>)

      _ ->
        unescape(src, line, acc)
    end
  end
end
