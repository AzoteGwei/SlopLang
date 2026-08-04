defmodule Slop.Parser do
  @moduledoc """
  Recursive-descent parser producing the SlopLang AST.

  AST nodes are tuples whose first element is a tag and whose second
  element is the source line.
  """

  defstruct toks: []

  # ---------------- entry ----------------

  def parse(src) when is_binary(src) do
    case Slop.Lexer.tokenize(src) do
      {:ok, toks} ->
        case module(%__MODULE__{toks: toks}) do
          {:ok, ast, _st} -> {:ok, ast}
          {:error, _, _} = e -> e
        end

      {:error, _, _} = e ->
        e
    end
  end

  def parse_expression(src) when is_binary(src) do
    case Slop.Lexer.tokenize(src) do
      {:ok, toks} ->
        st = %__MODULE__{toks: toks}

        with {:ok, e, st} <- expr(st),
             {:ok, st} <- skip_newlines(st),
             {:ok, _st} <- expect_eof(st) do
          {:ok, e}
        else
          {:error, _, _} = e -> e
        end

      {:error, _, _} = e ->
        e
    end
  end

  defp module(st) do
    case stmts(st, [:eof]) do
      {:ok, body, st} ->
        case st.toks do
          [{:eof, _, _} | _] -> {:ok, {:module, 1, body}, st}
          [{t, line, v} | _] -> err(line, "unexpected #{t} #{inspect(v)}")
        end

      e ->
        e
    end
  end

  # ---------------- token helpers ----------------

  defp peek(%{toks: [t | _]}), do: t
  defp peek(%{toks: []}), do: {:eof, 0, nil}

  defp peek2(%{toks: [_, t | _]}), do: t
  defp peek2(%{toks: _}), do: {:eof, 0, nil}

  defp line_of(%{toks: [{_, line, _} | _]}), do: line
  defp line_of(_), do: 0

  defp advance(%{toks: [_ | rest]} = st), do: %{st | toks: rest}

  defp err(line, msg), do: {:error, line, msg}

  defp take(st, kind) do
    case peek(st) do
      {^kind, _, _} = t -> {:ok, t, advance(st)}
      {k, line, v} -> err(line, "expected #{kind}, got #{k} #{inspect(v)}")
    end
  end

  defp take_kw(st, kw) do
    case peek(st) do
      {:kw, _, ^kw} = t -> {:ok, t, advance(st)}
      {k, line, v} -> err(line, "expected '#{kw}', got #{k} #{inspect(v)}")
    end
  end

  defp take_op(st, op) do
    case peek(st) do
      {:op, _, ^op} = t -> {:ok, t, advance(st)}
      {k, line, v} -> err(line, "expected '#{op}', got #{k} #{inspect(v)}")
    end
  end

  defp maybe_kw(st, kw) do
    case peek(st) do
      {:kw, _, ^kw} -> {true, advance(st)}
      _ -> {false, st}
    end
  end

  defp maybe_op(st, op) do
    case peek(st) do
      {:op, _, ^op} -> {true, advance(st)}
      _ -> {false, st}
    end
  end

  defp kw?(st, kw), do: match?({:kw, _, ^kw}, peek(st))
  defp op?(st, op), do: match?({:op, _, ^op}, peek(st))
  defp newline?(st), do: match?({:newline, _, _}, peek(st))
  defp eof?(st), do: match?({:eof, _, _}, peek(st))

  defp skip_newlines(st) do
    case peek(st) do
      {:newline, _, _} -> skip_newlines(advance(st))
      _ -> {:ok, st}
    end
  end

  defp expect_eof(st) do
    case peek(st) do
      {:eof, _, _} -> {:ok, st}
      {k, line, v} -> err(line, "unexpected #{k} #{inspect(v)}")
    end
  end

  # ---------------- statements ----------------

  # parse statements until one of the stop kinds is reached
  defp stmts(st, stops) do
    stmts(st, stops, [])
  end

  defp stmts(st, stops, acc) do
    case peek(st) do
      {:newline, _, _} ->
        stmts(advance(st), stops, acc)

      {k, _, _} ->
        cond do
          k in stops ->
            {:ok, Enum.reverse(acc), st}

          match?({:kw, _, "nonlocal"}, peek(st)) ->
            {_, line, _} = peek(st)
            err(line, "nonlocal is not supported; closures capture by value in SlopLang")

          match?({:kw, _, kw} when kw in ["yield", "async", "await"], peek(st)) ->
            {:kw, line, kw} = peek(st)
            err(line, "#{kw} is not supported in SlopLang; see 'Rejected designs' in docs/semantics.md")

          true ->
            case stmt(st) do
              {:ok, s, st} -> stmts(st, stops, [s | acc])
              e -> e
            end
        end
    end
  end

  defp stmt(st) do
    case peek(st) do
      {:kw, _, kw} when kw in ~w(if while for def class try with import from
                                   global raise return break continue pass del assert) ->
        compound_or_simple(st)

      {:kw, _, "match"} ->
        # `match` is a soft keyword: `match = ...` (and `match.x = ...`)
        # is an ordinary statement; `match subj:` a match. Note
        # `match(...)` stays a match statement (same as Python's
        # subject-preference rule).
        case peek2(st) do
          {:op, _, op} when op in ["=", "."] -> simple_stmt_line(st)
          _ -> compound_or_simple(st)
        end

      {:op, _, "@"} ->
        decorated(st)

      _ ->
        simple_stmt_line(st)
    end
  end

  # a simple statement possibly followed by ';'-separated peers, ended by newline/eof/dedent
  defp simple_stmt_line(st) do
    case simple_stmt(st) do
      {:ok, s, st} ->
        case peek(st) do
          {:op, _, ";"} ->
            case simple_stmt_line(advance(st)) do
              {:ok, {:block, line, ss}, st} -> {:ok, {:block, line, [s | ss]}, st}
              {:ok, other, st} -> {:ok, {:block, elem(other, 1), [s, other]}, st}
              e -> e
            end

          {:newline, _, _} ->
            {:ok, s, advance(st)}

          {:dedent, _, _} ->
            {:ok, s, st}

          {:eof, _, _} ->
            {:ok, s, st}

          {k, line, v} ->
            err(line, "unexpected #{k} #{inspect(v)} after statement")
        end

      e ->
        e
    end
  end

  defp simple_stmt(st) do
    case peek(st) do
      {:kw, line, "pass"} -> {:ok, {:pass, line}, advance(st)}
      {:kw, line, "break"} -> {:ok, {:break, line}, advance(st)}
      {:kw, line, "continue"} -> {:ok, {:continue, line}, advance(st)}

      {:kw, line, "return"} ->
        st = advance(st)

        if newline?(st) or op?(st, ";") or match?({:dedent, _, _}, peek(st)) or eof?(st) do
          {:ok, {:return, line, nil}, st}
        else
          with {:ok, e, st} <- expr_or_tuple(st), do: {:ok, {:return, line, e}, st}
        end

      {:kw, line, "raise"} ->
        st = advance(st)

        if newline?(st) or op?(st, ";") do
          {:ok, {:raise, line, nil, nil}, st}
        else
          with {:ok, e, st} <- expr(st) do
            {from, st} =
              case maybe_kw(st, "from") do
                {true, st2} ->
                  case expr(st2) do
                    {:ok, f, st3} -> {f, st3}
                    _ -> {nil, st2}
                  end

                _ ->
                  {nil, st}
              end

            {:ok, {:raise, line, e, from}, st}
          end
        end

      {:kw, line, "del"} ->
        with {:ok, targets, st} <- target_list(advance(st)),
             do: {:ok, {:del, line, targets}, st}

      {:kw, line, "global"} ->
        with {:ok, names, st} <- name_list(advance(st)),
             do: {:ok, {:global, line, names}, st}

      {:kw, line, "assert"} ->
        st = advance(st)

        with {:ok, test, st} <- expr(st) do
          case maybe_op(st, ",") do
            {true, st} ->
              with {:ok, msg, st} <- expr(st), do: {:ok, {:assert, line, test, msg}, st}

            _ ->
              {:ok, {:assert, line, test, nil}, st}
          end
        end

      {:kw, _, "import"} ->
        import_stmt(st)

      {:kw, _, "from"} ->
        from_stmt(st)

      _ ->
        expr_stmt(st)
    end
  end

  defp name_list(st) do
    case take(st, :name) do
      {:ok, {:name, _, n}, st} ->
        case maybe_op(st, ",") do
          {true, st} ->
            with {:ok, rest, st} <- name_list(st), do: {:ok, [n | rest], st}

          _ ->
            {:ok, [n], st}
        end

      _ ->
        {_, line, _} = peek(st)
        err(line, "expected name")
    end
  end

  defp target_list(st) do
    with {:ok, t, st} <- target(st) do
      case maybe_op(st, ",") do
        {true, st} ->
          with {:ok, rest, st} <- target_list(st), do: {:ok, [t | rest], st}

        _ ->
          {:ok, [t], st}
      end
    end
  end

  defp target(st) do
    case peek(st) do
      {:name, line, n} ->
        st = advance(st)

        case peek(st) do
          {:op, _, op} when op in [".", "["] ->
            with {:ok, e, st} <- postfix_rest(st, {:name, line, n}) do
              case e do
                {:attr, _, _, _} -> {:ok, e, st}
                {:subscript, _, _, _} -> {:ok, e, st}
                _ -> {:ok, e, st}
              end
            end

          _ ->
            {:ok, {:name, line, n}, st}
        end

      {:op, line, "("} ->
        st = advance(st)

        with {:ok, ts, st} <- target_list(st),
             {:ok, _, st} <- take_op(st, ")"),
             do: {:ok, {:tuple, line, ts}, st}

      {:op, line, "["} ->
        st = advance(st)

        with {:ok, ts, st} <- target_list(st),
             {:ok, _, st} <- take_op(st, "]"),
             do: {:ok, {:list, line, ts}, st}

      _ ->
        # attribute or subscript target
        with {:ok, e, st} <- postfix_expr(st) do
          case e do
            {:attr, _, _, _} -> {:ok, e, st}
            {:subscript, _, _, _} -> {:ok, e, st}
            _ ->
              {_, line, _} = peek(st)
              err(line, "invalid assignment target")
          end
        end
    end
  end

  # expression statement / assignment / augmented assignment / annotated assignment
  defp expr_stmt(st) do
    case peek(st) do
      {:op, line, "*"} ->
        # starred assignment target: *a, b = ...
        st = advance(st)

        with {:ok, t, st} <- target(st) do
          star = {:starred, line, t}

          with {:ok, rest, st} <- tuple_rest(st, [star], line) do
            case take_op(st, "=") do
              {:ok, _, st} ->
                with {:ok, val, st} <- expr_or_tuple(st),
                     do: {:ok, {:assign, line, [rest], val}, st}

              _ ->
                {_, l2, _} = peek(st)
                err(l2, "expected '=' after starred target")
            end
          end
        end

      _ ->
        expr_stmt2(st)
    end
  end

  defp expr_stmt2(st) do
    with {:ok, e, st} <- expr_or_tuple(st) do
      line = elem(e, 1)

      cond do
        op?(st, "=") ->
          st = advance(st)
          with {:ok, val, st} <- expr_or_tuple(st) do
            assign_rest(st, [e], val, line)
          end

        aug = aug_op(st) ->
          st = advance(st)
          with {:ok, val, st} <- expr_or_tuple(st),
               do: {:ok, {:augassign, line, e, aug, val}, st}

        op?(st, ":") and match?({:name, _, _}, e) ->
          st = advance(st)

          with {:ok, ann, st} <- expr(st) do
            case maybe_op(st, "=") do
              {true, st} ->
                with {:ok, val, st} <- expr_or_tuple(st),
                     do: {:ok, {:annassign, line, e, ann, val}, st}

              _ ->
                {:ok, {:annassign, line, e, ann, nil}, st}
            end
          end

        true ->
          {:ok, {:exprstmt, line, e}, st}
      end
    end
  end

  defp assign_rest(st, targets, val, line) do
    case maybe_op(st, "=") do
      {true, st} ->
        with {:ok, val2, st} <- expr_or_tuple(st),
             do: assign_rest(st, targets ++ [val], val2, line)

      _ ->
        {:ok, {:assign, line, targets, val}, st}
    end
  end

  @aug_ops ~w(+= -= *= /= //= %= **= &= |= ^= <<= >>=)
  defp aug_op(st) do
    case peek(st) do
      {:op, _, op} when op in @aug_ops -> String.trim_trailing(op, "=")
      _ -> nil
    end
  end

  defp expr_or_tuple(st) do
    with {:ok, e, st} <- expr(st) do
      if op?(st, ",") do
        line = elem(e, 1)
        tuple_rest(st, [e], line)
      else
        {:ok, e, st}
      end
    end
  end

  defp tuple_rest(st, acc, line) do
    case peek(st) do
      {:op, _, ","} ->
        st = advance(st)

        case peek(st) do
          {:newline, _, _} -> tuple_rest(st, acc, line)
          {:op, _, op} when op in [")", "]", "=", ";"] -> tuple_rest(st, acc, line)
          {:kw, _, "in"} -> tuple_rest(st, acc, line)
          {:dedent, _, _} -> tuple_rest(st, acc, line)
          {:eof, _, _} -> tuple_rest(st, acc, line)
          _ ->
            case peek(st) do
              {:op, sline, "*"} ->
                st = advance(st)

                with {:ok, t, st} <- target(st),
                     do: tuple_rest(st, acc ++ [{:starred, sline, t}], line)

              _ ->
                with {:ok, e, st} <- expr(st), do: tuple_rest(st, acc ++ [e], line)
            end
        end

      _ ->
        {:ok, {:tuple, line, acc}, st}
    end
  end

  # ---------------- imports ----------------

  defp import_stmt(st) do
    {:kw, line, _} = peek(st)
    st = advance(st)

    with {:ok, mods, st} <- dotted_as_list(st),
         do: {:ok, {:import, line, mods}, st}
  end

  defp dotted_as_list(st) do
    with {:ok, mod, st} <- dotted_name(st) do
      {asname, st} =
        case maybe_kw(st, "as") do
          {true, st} ->
            case take(st, :name) do
              {:ok, {:name, _, n}, st} -> {n, st}
              _ -> {nil, st}
            end

          _ ->
            {nil, st}
        end

      case maybe_op(st, ",") do
        {true, st} ->
          with {:ok, rest, st} <- dotted_as_list(st),
               do: {:ok, [{mod, asname} | rest], st}

        _ ->
          {:ok, [{mod, asname}], st}
      end
    end
  end

  defp dotted_name(st) do
    case take(st, :name) do
      {:ok, {:name, _, n}, st} -> dotted_name(st, n)
      _ ->
        {_, line, _} = peek(st)
        err(line, "expected module name")
    end
  end

  defp dotted_name(st, acc) do
    case op?(st, ".") do
      true ->
        st = advance(st)

        case take(st, :name) do
          {:ok, {:name, _, n}, st} -> dotted_name(st, acc <> "." <> n)
          _ -> {:ok, acc, st}
        end

      false ->
        {:ok, acc, st}
    end
  end

  defp from_stmt(st) do
    {:kw, line, _} = peek(st)
    st = advance(st)

    # relative imports: count leading dots
    {dots, st} = count_dots(st, 0)

    {mod, st} =
      case peek(st) do
        {:name, _, _} ->
          case dotted_name(st) do
            {:ok, m, st} -> {m, st}
            _ -> {"", st}
          end

        _ ->
          {"", st}
      end

    mod = String.duplicate(".", dots) <> mod

    case take_kw(st, "import") do
      {:ok, _, st} ->
        cond do
          op?(st, "*") ->
            {:ok, {:from, line, mod, :star}, advance(st)}

          op?(st, "(") ->
            st = advance(st)

            with {:ok, names, st} <- import_names(st),
                 {:ok, _, st} <- take_op(st, ")"),
                 do: {:ok, {:from, line, mod, names}, st}

          true ->
            with {:ok, names, st} <- import_names(st),
                 do: {:ok, {:from, line, mod, names}, st}
        end

      _ ->
        {_, l2, _} = peek(st)
        err(l2, "expected 'import'")
    end
  end

  defp count_dots(st, n) do
    case op?(st, ".") do
      true -> count_dots(advance(st), n + 1)
      false -> {n, st}
    end
  end

  defp import_names(st) do
    case take(st, :name) do
      {:ok, {:name, _, n}, st} ->
        {asname, st} =
          case maybe_kw(st, "as") do
            {true, st} ->
              case take(st, :name) do
                {:ok, {:name, _, a}, st} -> {a, st}
                _ -> {nil, st}
              end

            _ ->
              {nil, st}
          end

        case maybe_op(st, ",") do
          {true, st} ->
            case peek(st) do
              {:op, _, ")"} -> {:ok, [{n, asname}], st}
              {:newline, _, _} ->
                case import_names(advance(st)) do
                  {:ok, r, s} -> {:ok, [{n, asname} | r], s}
                  e -> e
                end

              _ ->
                with {:ok, rest, st} <- import_names(st),
                     do: {:ok, [{n, asname} | rest], st}
            end

          _ ->
            {:ok, [{n, asname}], st}
        end

      _ ->
        {_, line, _} = peek(st)
        err(line, "expected name in import list")
    end
  end

  # ---------------- compound statements ----------------

  defp compound_or_simple(st) do
    case peek(st) do
      {:kw, _, "if"} -> if_stmt(st)
      {:kw, _, "while"} -> while_stmt(st)
      {:kw, _, "for"} -> for_stmt(st)
      {:kw, _, "def"} -> def_stmt(st, [])
      {:kw, _, "class"} -> class_stmt(st, [])
      {:kw, _, "try"} -> try_stmt(st)
      {:kw, _, "with"} -> with_stmt(st)
      {:kw, _, "match"} -> match_stmt(st)
      _ -> simple_stmt_line(st)
    end
  end

  # suite: either "stmt..." on same line, or NEWLINE INDENT stmts DEDENT
  defp suite(st) do
    case peek(st) do
      {:newline, _, _} ->
        st = advance(st)

        case peek(st) do
          {:indent, _, _} ->
            st = advance(st)

            with {:ok, body, st} <- stmts(st, [:dedent]),
                 {:ok, _, st} <- take(st, :dedent),
                 do: {:ok, body, st}

          {k, line, v} ->
            err(line, "expected indented block, got #{k} #{inspect(v)}")
        end

      _ ->
        with {:ok, s, st} <- simple_stmt_line(st), do: {:ok, [s], st}
    end
  end

  defp if_stmt(st) do
    {:kw, line, _} = peek(st)
    st = advance(st)

    with {:ok, cond_e, st} <- expr(st),
         {:ok, _, st} <- take_op(st, ":"),
         {:ok, body, st} <- suite(st) do
      orelse_result =
        case peek(st) do
          {:kw, _, "elif"} -> if_stmt(st)
          {:kw, _, "else"} ->
            st = advance(st)

            with {:ok, _, st} <- take_op(st, ":"),
                 {:ok, b, st} <- suite(st),
                 do: {:ok, b, st}

          _ -> {:ok, [], st}
        end

      case orelse_result do
        {:ok, {:if, _, _, _, _} = nested, st} -> {:ok, {:if, line, cond_e, body, [nested]}, st}
        {:ok, orelse, st} -> {:ok, {:if, line, cond_e, body, orelse}, st}
        e -> e
      end
    end
  end

  defp while_stmt(st) do
    {:kw, line, _} = peek(st)
    st = advance(st)

    with {:ok, cond_e, st} <- expr(st),
         {:ok, _, st} <- take_op(st, ":"),
         {:ok, body, st} <- suite(st) do
      case peek(st) do
        {:kw, _, "else"} ->
          st = advance(st)

          with {:ok, _, st} <- take_op(st, ":"),
               {:ok, b, st} <- suite(st),
               do: {:ok, {:while, line, cond_e, body, b}, st}

        _ ->
          {:ok, {:while, line, cond_e, body, []}, st}
      end
    end
  end

  defp for_stmt(st) do
    {:kw, line, _} = peek(st)
    st = advance(st)

    with {:ok, target, st} <- target_list(st),
         {:ok, _, st} <- take_kw(st, "in"),
         {:ok, iter, st} <- expr_or_tuple(st),
         {:ok, _, st} <- take_op(st, ":"),
         {:ok, body, st} <- suite(st) do
      target =
        case target do
          [t] -> t
          ts -> {:tuple, line, ts}
        end

      case peek(st) do
        {:kw, _, "else"} ->
          st = advance(st)

          with {:ok, _, st} <- take_op(st, ":"),
               {:ok, b, st} <- suite(st),
               do: {:ok, {:for, line, target, iter, body, b}, st}

        _ ->
          {:ok, {:for, line, target, iter, body, []}, st}
      end
    end
  end

  defp decorated(st) do
    {:op, line, _} = peek(st)
    st = advance(st)

    with {:ok, deco, st} <- expr(st),
         {:ok, _, st} <- take(st, :newline) do
      case peek(st) do
        {:op, _, "@"} ->
          with {:ok, inner, st} <- decorated(st) do
            {:ok, put_decorators(inner, [deco | get_decorators(inner)]), st}
          end

        {:kw, _, "def"} ->
          with {:ok, d, st} <- def_stmt(st, [deco]), do: {:ok, d, st}

        {:kw, _, "class"} ->
          with {:ok, c, st} <- class_stmt(st, [deco]), do: {:ok, c, st}

        _ ->
          err(line, "expected def or class after decorator")
      end
    end
  end

  defp get_decorators({:def, _, _, _, _, decos, _}), do: decos
  defp get_decorators({:class, _, _, _, _, decos}), do: decos

  defp put_decorators({:def, line, name, params, body, decos, ann}, d2),
    do: {:def, line, name, params, body, d2 ++ decos, ann}

  defp put_decorators({:class, line, name, bases, body, decos}, d2),
    do: {:class, line, name, bases, body, d2 ++ decos}

  # soft keywords are valid def names (re.match, etc.)
  defp take_def_name(st) do
    case peek(st) do
      {:kw, line, "match"} -> {:ok, {:name, line, "match"}, advance(st)}
      _ -> take(st, :name)
    end
  end

  defp def_stmt(st, decos) do
    {:kw, line, _} = peek(st)
    st = advance(st)

    with {:ok, {:name, _, name}, st} <- take_def_name(st),
         {:ok, _, st} <- take_op(st, "("),
         {:ok, params, st} <- params(st),
         {:ok, _, st} <- take_op(st, ")") do
      {ann, st} =
        case maybe_op(st, "->") do
          {true, st} ->
            case expr(st) do
              {:ok, a, st} -> {a, st}
              _ -> {nil, st}
            end

          _ ->
            {nil, st}
        end

      with {:ok, _, st} <- take_op(st, ":"),
           {:ok, body, st} <- suite(st),
           do: {:ok, {:def, line, name, params, body, decos, ann}, st}
    end
  end

  # params: positional (with defaults), *vararg, kwonly, **kwarg
  defp params(st) do
    params(st, %{pos: [], vararg: nil, kwonly: [], kwarg: nil}, :pos)
  end

  defp params(st, acc, mode) do
    case peek(st) do
      {:op, _, ")"} ->
        {:ok, %{acc | pos: Enum.reverse(acc.pos), kwonly: Enum.reverse(acc.kwonly)}, st}

      {:op, _, ","} ->
        params(advance(st), acc, mode)

      {:newline, _, _} ->
        params(advance(st), acc, mode)

      {:op, _, "*"} ->
        st = advance(st)

        case peek(st) do
          {:name, _, n} ->
            st = advance(st)
            {ann, st} = maybe_annotation(st)
            params(st, %{acc | vararg: {n, ann}}, :kwonly)

          _ ->
            params(st, acc, :kwonly)
        end

      {:op, _, "**"} ->
        st = advance(st)

        case take(st, :name) do
          {:ok, {:name, _, n}, st} ->
            {ann, st} = maybe_annotation(st)
            params(st, %{acc | kwarg: {n, ann}}, :done)

          _ ->
            {_, line, _} = peek(st)
            err(line, "expected name after **")
        end

      {:op, _, "/"} ->
        params(advance(st), acc, mode)

      {:name, _, n} ->
        st = advance(st)
        {ann, st} = maybe_annotation(st)

        defres =
          case maybe_op(st, "=") do
            {true, st} ->
              case expr(st) do
                {:ok, d, st} -> {:ok, d, st}
                {:error, _, _} = e -> e
              end

            _ ->
              {:ok, nil, st}
          end

        case defres do
          {:error, _, _} = e ->
            e

          {:ok, default, st} ->
            p = {n, default, ann}

            case mode do
              :pos -> params(st, %{acc | pos: [p | acc.pos]}, mode)
              :kwonly -> params(st, %{acc | kwonly: [p | acc.kwonly]}, mode)
              :done -> err(line_of(st), "no parameters allowed after **kwargs")
            end
        end

      {k, line, v} ->
        err(line, "unexpected #{k} #{inspect(v)} in parameter list")
    end
  end

  defp maybe_annotation(st) do
    case maybe_op(st, ":") do
      {true, st} ->
        case expr(st) do
          {:ok, a, st} -> {a, st}
          _ -> {nil, st}
        end

      _ ->
        {nil, st}
    end
  end

  defp class_stmt(st, decos) do
    {:kw, line, _} = peek(st)
    st = advance(st)

    with {:ok, {:name, _, name}, st} <- take(st, :name) do
      bases_res =
        case maybe_op(st, "(") do
          {true, st} -> class_bases(st, [])
          _ -> {:ok, [], st}
        end

      with {:ok, bases, st} <- bases_res,
           {:ok, _, st} <- take_op(st, ":"),
           {:ok, body, st} <- suite(st),
           do: {:ok, {:class, line, name, bases, body, decos}, st}
    end
  end

  defp class_bases(st, acc) do
    case peek(st) do
      {:op, _, ")"} -> {:ok, Enum.reverse(acc), advance(st)}
      {:op, _, ","} -> class_bases(advance(st), acc)
      {:newline, _, _} -> class_bases(advance(st), acc)
      {:name, _, n} ->
        case peek2(st) do
          {:op, _, "="} ->
            st = advance(advance(st))

            with {:ok, e, st} <- expr(st),
                 do: class_bases(st, [{:kw, n, e} | acc])

          _ ->
            with {:ok, e, st} <- expr(st), do: class_bases(st, [e | acc])
        end

      _ ->
        with {:ok, e, st} <- expr(st), do: class_bases(st, [e | acc])
    end
  end

  defp try_stmt(st) do
    {:kw, line, _} = peek(st)
    st = advance(st)

    with {:ok, _, st} <- take_op(st, ":"),
         {:ok, body, st} <- suite(st) do
      try_rest(st, line, body, [])
    end
  end

  defp try_rest(st, line, body, handlers) do
    case peek(st) do
      {:kw, _, "except"} ->
        st = advance(st)

        {exc_type, name, st} =
          cond do
            op?(st, ":") ->
              {nil, nil, st}

            true ->
              case expr(st) do
                {:ok, t, st} ->
                  case maybe_kw(st, "as") do
                    {true, st} ->
                      case take(st, :name) do
                        {:ok, {:name, _, n}, st} -> {t, n, st}
                        _ -> {t, nil, st}
                      end

                    _ ->
                      {t, nil, st}
                  end

                _ ->
                  {nil, nil, st}
              end
          end

        with {:ok, _, st} <- take_op(st, ":"),
             {:ok, hbody, st} <- suite(st) do
          try_rest(st, line, body, handlers ++ [{exc_type, name, hbody}])
        end

      {:kw, _, "else"} when handlers != [] ->
        st = advance(st)

        with {:ok, _, st} <- take_op(st, ":"),
             {:ok, orelse, st} <- suite(st) do
          try_finally(st, line, body, handlers, orelse, [])
        end

      {:kw, _, "finally"} ->
        st = advance(st)

        with {:ok, _, st} <- take_op(st, ":"),
             {:ok, fin, st} <- suite(st),
             do: {:ok, {:try, line, body, handlers, [], fin}, st}

      _ when handlers != [] ->
        {:ok, {:try, line, body, handlers, [], []}, st}

      _ ->
        {_, l2, _} = peek(st)
        err(l2, "expected 'except' or 'finally'")
    end
  end

  defp try_finally(st, line, body, handlers, orelse, _ignore) do
    case peek(st) do
      {:kw, _, "finally"} ->
        st = advance(st)

        with {:ok, _, st} <- take_op(st, ":"),
             {:ok, fin, st} <- suite(st),
             do: {:ok, {:try, line, body, handlers, orelse, fin}, st}

      _ ->
        {:ok, {:try, line, body, handlers, orelse, []}, st}
    end
  end

  defp with_stmt(st) do
    {:kw, line, _} = peek(st)
    st = advance(st)

    with {:ok, items, st} <- with_items(st, []),
       {:ok, _, st} <- take_op(st, ":"),
       {:ok, body, st} <- suite(st),
       do: {:ok, {:with, line, items, body}, st}
  end

  defp with_items(st, acc) do
    with {:ok, ctx, st} <- expr(st) do
      {name, st} =
        case maybe_kw(st, "as") do
          {true, st} ->
            case take(st, :name) do
              {:ok, {:name, _, n}, st} -> {n, st}
              _ -> {nil, st}
            end

          _ ->
            {nil, st}
        end

      case maybe_op(st, ",") do
        {true, st} -> with_items(st, acc ++ [{ctx, name}])
        _ -> {:ok, acc ++ [{ctx, name}], st}
      end
    end
  end

  # ---------------- match ----------------

  defp match_stmt(st) do
    {:kw, line, _} = peek(st)
    st = advance(st)

    with {:ok, subj, st} <- expr_or_tuple(st),
         {:ok, _, st} <- take_op(st, ":"),
         {:ok, _, st} <- take(st, :newline),
         {:ok, _, st} <- take(st, :indent) do
      match_cases(st, line, subj, [])
    end
  end

  defp match_cases(st, line, subj, acc) do
    case peek(st) do
      {:kw, cline, "case"} ->
        st = advance(st)

        with {:ok, pat, st} <- pattern(st) do
          {guard, st} =
            case maybe_kw(st, "if") do
              {true, st} ->
                case expr(st) do
                  {:ok, g, st} -> {g, st}
                  _ -> {nil, st}
                end

              _ ->
                {nil, st}
            end

          with {:ok, _, st} <- take_op(st, ":"),
               {:ok, body, st} <- suite(st) do
            match_cases(st, line, subj, acc ++ [{pat, guard, body, cline}])
          end
        end

      {:dedent, _, _} ->
        {:ok, {:match, line, subj, acc}, advance(st)}

      {k, l2, v} ->
        err(l2, "expected 'case', got #{k} #{inspect(v)}")
    end
  end

  defp pattern(st) do
    with {:ok, p, st} <- single_pattern(st) do
      case op?(st, "|") do
        true ->
          st = advance(st)

          with {:ok, ps, st} <- pattern(st) do
            case ps do
              {:p_or, _, list} -> {:ok, {:p_or, elem(p, 1), [p | list]}, st}
              _ -> {:ok, {:p_or, elem(p, 1), [p, ps]}, st}
            end
          end

        _ ->
          case maybe_kw(st, "as") do
            {true, st} ->
              case take(st, :name) do
                {:ok, {:name, _, n}, st} -> {:ok, {:p_as, elem(p, 1), p, n}, st}
                _ -> {:ok, p, st}
              end

            _ ->
              {:ok, p, st}
          end
      end
    end
  end

  defp single_pattern(st) do
    case peek(st) do
      {:op, line, "_"} ->
        # shouldn't happen: _ is a name
        {:ok, {:p_wild, line}, advance(st)}

      {:name, line, "_"} ->
        {:ok, {:p_wild, line}, advance(st)}

      {:name, line, n} ->
        st = advance(st)

        cond do
          # class pattern Name(...)
          op?(st, "(") ->
            st = advance(st)

            with {:ok, kwps, st} <- class_patterns(st, []),
                 {:ok, _, st} <- take_op(st, ")"),
                 do: {:ok, {:p_class, line, {:name, line, n}, kwps}, st}

          # value pattern a.b.c
          op?(st, ".") ->
            with {:ok, e, st} <- dotted_value(st, {:name, line, n}),
                 do: {:ok, {:p_value, line, e}, st}

          true ->
            {:ok, {:p_capture, line, n}, st}
        end

      {:int, line, v} ->
        {:ok, {:p_lit, line, v}, advance(st)}

      {:float, line, v} ->
        {:ok, {:p_lit, line, v}, advance(st)}

      {:str, line, {v, _}} ->
        {:ok, {:p_lit, line, v}, advance(st)}

      {:kw, line, kw} when kw in ["None", "True", "False"] ->
        v = case kw do
          "None" -> nil
          "True" -> true
          "False" -> false
        end

        {:ok, {:p_lit, line, v}, advance(st)}

      {:op, line, "-"} ->
        st = advance(st)

        case peek(st) do
          {:int, _, v} -> {:ok, {:p_lit, line, -v}, advance(st)}
          {:float, _, v} -> {:ok, {:p_lit, line, -v}, advance(st)}
          _ -> err(line, "expected number after '-' in pattern")
        end

      {:op, line, "("} ->
        st = advance(st)
        pattern_seq(st, line, :p_tuple, ")")

      {:op, line, "["} ->
        st = advance(st)
        pattern_seq(st, line, :p_seq, "]")

      {:op, line, "{"} ->
        st = advance(st)
        map_pattern(st, line, [])

      {k, line, v} ->
        err(line, "unexpected #{k} #{inspect(v)} in pattern")
    end
  end

  defp dotted_value(st, acc) do
    case op?(st, ".") do
      true ->
        st = advance(st)

        case take(st, :name) do
          {:ok, {:name, line, n}, st} -> dotted_value(st, {:attr, line, acc, n})
          _ -> {:ok, acc, st}
        end

      false ->
        {:ok, acc, st}
    end
  end

  defp class_patterns(st, acc) do
    case peek(st) do
      {:op, _, ")"} -> {:ok, Enum.reverse(acc), st}
      {:op, _, ","} -> class_patterns(advance(st), acc)
      {:newline, _, _} -> class_patterns(advance(st), acc)
      {:name, line, n} ->
        st = advance(st)

        case maybe_op(st, "=") do
          {true, st} ->
            with {:ok, p, st} <- pattern(st),
                 do: class_patterns(st, [{n, p} | acc])

          _ ->
            # positional class pattern: not supported
            err(line, "positional class patterns are not supported; use Name(attr=pattern)")
        end

      {k, line, v} ->
        err(line, "unexpected #{k} #{inspect(v)} in class pattern")
    end
  end

  defp pattern_seq(st, line, tag, closer) do
    case peek(st) do
      {:op, _, ^closer} ->
        {:ok, {tag, line, [], nil}, advance(st)}

      _ ->
        pattern_seq_items(st, line, tag, closer, [], nil)
    end
  end

  defp pattern_seq_items(st, line, tag, closer, acc, star_idx) do
    case peek(st) do
      {:op, _, ^closer} ->
        {:ok, {tag, line, Enum.reverse(acc), star_idx}, advance(st)}

      {:op, _, ","} ->
        pattern_seq_items(advance(st), line, tag, closer, acc, star_idx)

      {:newline, _, _} ->
        pattern_seq_items(advance(st), line, tag, closer, acc, star_idx)

      {:op, sline, "*"} ->
        st = advance(st)

        case take(st, :name) do
          {:ok, {:name, _, n}, st} ->
            idx = length(acc)
            pattern_seq_items(st, line, tag, closer, [{:p_capture, sline, n} | acc], idx)

          _ ->
            err(sline, "expected name after '*' in pattern")
        end

      _ ->
        with {:ok, p, st} <- pattern(st),
             do: pattern_seq_items(st, line, tag, closer, [p | acc], star_idx)
    end
  end

  defp map_pattern(st, line, acc) do
    case peek(st) do
      {:op, _, "}"} ->
        {:ok, {:p_map, line, Enum.reverse(acc), nil}, advance(st)}

      {:op, _, ","} ->
        map_pattern(advance(st), line, acc)

      {:newline, _, _} ->
        map_pattern(advance(st), line, acc)

      {:op, _, "**"} ->
        st = advance(st)

        case take(st, :name) do
          {:ok, {:name, _, n}, st} ->
            case take_op(st, "}") do
              {:ok, _, st} -> {:ok, {:p_map, line, Enum.reverse(acc), n}, st}
              _ ->
                {_, l2, _} = peek(st)
                err(l2, "expected '}' after **name")
            end

          _ ->
            {_, l2, _} = peek(st)
            err(l2, "expected name after '**'")
        end

      _ ->
        with {:ok, k, st} <- map_key(st),
             {:ok, _, st} <- take_op(st, ":"),
             {:ok, p, st} <- pattern(st),
             do: map_pattern(st, line, [{k, p} | acc])
    end
  end

  defp map_key(st) do
    case peek(st) do
      {:str, line, {v, _}} -> {:ok, {:p_lit, line, v}, advance(st)}
      {:int, line, v} -> {:ok, {:p_lit, line, v}, advance(st)}
      {:kw, line, kw} when kw in ["None", "True", "False"] ->
        v = case kw, do: ("None" -> nil; "True" -> true; "False" -> false)
        {:ok, {:p_lit, line, v}, advance(st)}
      {:name, line, n} ->
        st = advance(st)
        with {:ok, e, st} <- dotted_value(st, {:name, line, n}),
             do: {:ok, {:p_value, line, e}, st}
      {k, line, v} -> err(line, "invalid mapping key #{k} #{inspect(v)}")
    end
  end

  # ---------------- expressions ----------------

  def expr(st) do
    case peek(st) do
      {:kw, line, "lambda"} -> lambda(st, line)
      _ -> ifexp(st)
    end
  end

  defp lambda(st, line) do
    st = advance(st)

    with {:ok, params, st} <- lambda_params(st, %{pos: [], vararg: nil, kwonly: [], kwarg: nil}),
         {:ok, _, st} <- take_op(st, ":"),
         {:ok, body, st} <- expr(st),
         do: {:ok, {:lambda, line, params, body}, st}
  end

  defp lambda_params(st, acc) do
    case peek(st) do
      {:op, _, ":"} ->
        {:ok, %{acc | pos: Enum.reverse(acc.pos), kwonly: Enum.reverse(acc.kwonly)}, st}

      {:op, _, ","} ->
        lambda_params(advance(st), acc)

      {:op, _, "*"} ->
        st = advance(st)

        case peek(st) do
          {:name, _, n} -> lambda_params(advance(st), %{acc | vararg: {n, nil}})
          _ -> lambda_params(st, acc)
        end

      {:op, _, "**"} ->
        st = advance(st)

        case take(st, :name) do
          {:ok, {:name, _, n}, st} -> lambda_params(advance(st), %{acc | kwarg: {n, nil}})
          _ ->
            {_, line, _} = peek(st)
            err(line, "expected name after **")
        end

      {:name, _, n} ->
        st = advance(st)

        {default, st} =
          case maybe_op(st, "=") do
            {true, st} ->
              case expr(st) do
                {:ok, d, st} -> {d, st}
                _ -> {nil, st}
              end

            _ ->
              {nil, st}
          end

        lambda_params(st, %{acc | pos: [{n, default, nil} | acc.pos]})

      {k, line, v} ->
        err(line, "unexpected #{k} #{inspect(v)} in lambda parameters")
    end
  end

  defp ifexp(st) do
    with {:ok, then_e, st} <- or_expr(st) do
      case kw?(st, "if") do
        true ->
          st = advance(st)

          with {:ok, cond_e, st} <- or_expr(st),
               {:ok, _, st} <- take_kw(st, "else"),
               {:ok, else_e, st} <- expr(st),
               do: {:ok, {:ifexp, elem(then_e, 1), cond_e, then_e, else_e}, st}

        false ->
          {:ok, then_e, st}
      end
    end
  end

  defp or_expr(st) do
    with {:ok, l, st} <- and_expr(st) do
      case kw?(st, "or") do
        true ->
          st = advance(st)

          with {:ok, r, st} <- or_expr(st),
               do: {:ok, {:boolop, elem(l, 1), "or", l, r}, st}

        false ->
          {:ok, l, st}
      end
    end
  end

  defp and_expr(st) do
    with {:ok, l, st} <- not_expr(st) do
      case kw?(st, "and") do
        true ->
          st = advance(st)

          with {:ok, r, st} <- and_expr(st),
               do: {:ok, {:boolop, elem(l, 1), "and", l, r}, st}

        false ->
          {:ok, l, st}
      end
    end
  end

  defp not_expr(st) do
    case peek(st) do
      {:kw, line, "not"} ->
        st = advance(st)

        with {:ok, e, st} <- not_expr(st),
             do: {:ok, {:unary, line, "not", e}, st}

      _ ->
        comparison(st)
    end
  end

  @cmp_ops ~w(< > == != <= >=)

  defp comparison(st) do
    with {:ok, l, st} <- bor_expr(st) do
      comparison_rest(st, l, [])
    end
  end

  defp comparison_rest(st, l, acc) do
    op =
      case peek(st) do
        {:op, _, op} when op in @cmp_ops -> op
        {:kw, _, "in"} -> "in"
        {:kw, _, "is"} ->
          case peek2(st) do
            {:kw, _, "not"} -> "is not"
            _ -> "is"
          end

        {:kw, _, "not"} ->
          case peek2(st) do
            {:kw, _, "in"} -> "not in"
            _ -> nil
          end

        _ -> nil
      end

    if op do
      st = advance(st)

      st =
        case op do
          "is not" -> advance(st)
          "not in" -> advance(st)
          _ -> st
        end

      with {:ok, r, st} <- bor_expr(st),
           do: comparison_rest(st, r, acc ++ [{op, l, r}])
    else
      case acc do
        [] -> {:ok, l, st}
        _ ->
          line = elem(l, 1)
          {:ok, {:compare, line, acc}, st}
      end
    end
  end

  defp bor_expr(st) do
    with {:ok, l, st} <- bxor_expr(st), do: bin_chain(st, l, ["|"], &bxor_expr/1)
  end

  defp bxor_expr(st) do
    with {:ok, l, st} <- band_expr(st), do: bin_chain(st, l, ["^"], &band_expr/1)
  end

  defp band_expr(st) do
    with {:ok, l, st} <- shift_expr(st), do: bin_chain(st, l, ["&"], &shift_expr/1)
  end

  defp shift_expr(st) do
    with {:ok, l, st} <- arith_expr(st), do: bin_chain(st, l, ["<<", ">>"], &arith_expr/1)
  end

  defp arith_expr(st) do
    with {:ok, l, st} <- term_expr(st), do: bin_chain(st, l, ["+", "-"], &term_expr/1)
  end

  defp term_expr(st) do
    with {:ok, l, st} <- unary_expr(st), do: bin_chain(st, l, ["*", "/", "//", "%"], &unary_expr/1)
  end

  defp bin_chain(st, l, ops, sub) do
    case peek(st) do
      {:op, _, op} ->
        if op in ops do
          st = advance(st)

          with {:ok, r, st} <- sub.(st),
               do: bin_chain(st, {:binop, elem(l, 1), op, l, r}, ops, sub)
        else
          {:ok, l, st}
        end

      _ ->
        {:ok, l, st}
    end
  end

  defp unary_expr(st) do
    case peek(st) do
      {:kw, line, kw} when kw in ["await", "yield"] ->
        err(line, "#{kw} is not supported in SlopLang; see 'Rejected designs' in docs/semantics.md")

      {:op, line, op} when op in ["-", "+", "~"] ->
        st = advance(st)

        with {:ok, e, st} <- unary_expr(st),
             do: {:ok, {:unary, line, op, e}, st}

      _ ->
        power_expr(st)
    end
  end

  defp power_expr(st) do
    with {:ok, base, st} <- postfix_expr(st) do
      case op?(st, "**") do
        true ->
          st = advance(st)

          with {:ok, exp, st} <- unary_expr(st),
               do: {:ok, {:binop, elem(base, 1), "**", base, exp}, st}

        false ->
          {:ok, base, st}
      end
    end
  end

  defp postfix_expr(st) do
    with {:ok, e, st} <- atom_expr(st), do: postfix_rest(st, e)
  end

  defp postfix_rest(st, e) do
    case peek(st) do
      {:op, _, "("} ->
        st = advance(st)

        with {:ok, {args, kwargs}, st} <- call_args(st),
             {:ok, _, st} <- take_op(st, ")"),
             do: postfix_rest(st, {:call, elem(e, 1), e, args, kwargs})

      {:op, _, "["} ->
        st = advance(st)

        with {:ok, idx, st} <- subscript(st),
             {:ok, _, st} <- take_op(st, "]"),
             do: postfix_rest(st, {:subscript, elem(e, 1), e, idx})

      {:op, _, "."} ->
        st = advance(st)

        case take(st, :name) do
          {:ok, {:name, line, n}, st} ->
            postfix_rest(st, {:attr, line, e, n})

          _ ->
            # keywords are fine as attribute names (re.match, obj.class...)
            case peek(st) do
              {:kw, line, n} ->
                postfix_rest(advance(st), {:attr, line, e, n})

              _ ->
                {_, line, _} = peek(st)
                err(line, "expected attribute name after '.'")
            end
        end

      _ ->
        {:ok, e, st}
    end
  end

  # args: positional (possibly *e), keyword k=v, **e
  defp call_args(st) do
    call_args(st, [], [])
  end

  defp call_args(st, args, kwargs) do
    case peek(st) do
      {:op, _, ")"} ->
        {:ok, {Enum.reverse(args), Enum.reverse(kwargs)}, st}

      {:op, _, ","} ->
        call_args(advance(st), args, kwargs)

      {:newline, _, _} ->
        call_args(advance(st), args, kwargs)

      {:op, line, "*"} ->
        st = advance(st)

        with {:ok, e, st} <- expr(st),
             do: call_args(st, [{:star, line, e} | args], kwargs)

      {:op, line, "**"} ->
        st = advance(st)

        with {:ok, e, st} <- expr(st),
             do: call_args(st, args, [{:kwstar, line, e} | kwargs])

      {:name, _, n} ->
        case peek2(st) do
          {:op, _, "="} ->
            st = advance(advance(st))

            with {:ok, e, st} <- expr(st),
                 do: call_args(st, args, [{:kw, n, e} | kwargs])

          _ ->
            arg_expr(st, args, kwargs)
        end

      _ ->
        arg_expr(st, args, kwargs)
    end
  end

  defp arg_expr(st, args, kwargs) do
    with {:ok, e, st} <- expr(st) do
      # generator expression as sole argument
      case peek(st) do
        {:kw, _, "for"} ->
          with {:ok, clauses, st} <- comp_clauses(st, []),
               do: {:ok, {[{:genexp, elem(e, 1), e, clauses} | args], kwargs}, st}

        _ ->
          call_args(st, [e | args], kwargs)
      end
    end
  end

  defp subscript(st) do
    # index or slice
    case peek(st) do
      {:op, line, ":"} ->
        st = advance(st)

        with {:ok, hi, st} <- maybe_expr(st),
             do: slice_tail(st, line, nil, hi)

      _ ->
        with {:ok, e, st} <- expr(st) do
          case op?(st, ":") do
            true ->
              st = advance(st)

              with {:ok, hi, st} <- maybe_expr(st),
                   do: slice_tail(st, elem(e, 1), e, hi)

            false ->
              case op?(st, ",") do
                true ->
                  # multi-index e1, e2 -> tuple index
                  line = elem(e, 1)
                  with {:ok, rest, st} <- subscript_rest(st, []),
                       do: {:ok, {:tuple, line, [e | rest]}, st}

                false ->
                  {:ok, e, st}
              end
          end
        end
    end
  end

  defp subscript_rest(st, acc) do
    case maybe_op(st, ",") do
      {false, st} -> {:ok, Enum.reverse(acc), st}
      {true, st} ->
        case op?(st, "]") do
          true -> {:ok, Enum.reverse(acc), st}
          false ->
            with {:ok, e, st} <- expr(st), do: subscript_rest(st, [e | acc])
        end
    end
  end

  defp maybe_expr(st) do
    case peek(st) do
      {:op, _, ":"} -> {:ok, nil, st}
      {:op, _, "]"} -> {:ok, nil, st}
      _ ->
        case expr(st) do
          {:ok, e, st} -> {:ok, e, st}
          _ -> {:ok, nil, st}
        end
    end
  end

  defp slice_tail(st, line, lo, hi) do
    case maybe_op(st, ":") do
      {true, st} ->
        with {:ok, step, st} <- maybe_expr(st),
             do: {:ok, {:slice, line, lo, hi, step}, st}

      _ ->
        {:ok, {:slice, line, lo, hi, nil}, st}
    end
  end

  # ---------------- atoms ----------------

  defp atom_expr(st) do
    case peek(st) do
      {:int, line, v} -> {:ok, {:lit, line, v}, advance(st)}
      {:float, line, v} -> {:ok, {:lit, line, v}, advance(st)}
      {:str, line, {v, _flags}} ->
        st = advance(st)
        adjacent_strings(st, {:lit, line, v})

      {:fstring, line, {content, flags}} ->
        st = advance(st)
        fstring(st, line, content, flags)

      {:kw, line, "None"} -> {:ok, {:lit, line, nil}, advance(st)}
      {:kw, line, "True"} -> {:ok, {:lit, line, true}, advance(st)}
      {:kw, line, "False"} -> {:ok, {:lit, line, false}, advance(st)}

      # soft keyword: usable as a plain name in expression position
      {:kw, line, "match"} -> {:ok, {:name, line, "match"}, advance(st)}

      {:kw, _, "not"} -> not_expr(st)

      {:name, line, n} ->
        st = advance(st)

        case maybe_op(st, ":=") do
          {true, st} ->
            with {:ok, v, st} <- expr(st),
                 do: {:ok, {:namedexpr, line, n, v}, st}

          _ ->
            {:ok, {:name, line, n}, st}
        end

      {:op, line, "("} ->
        st = advance(st)
        paren(st, line)

      {:op, line, "["} ->
        st = advance(st)
        list_expr(st, line)

      {:op, line, "{"} ->
        st = advance(st)
        dict_or_set(st, line)

      {:op, line, "..."} ->
        {:ok, {:lit, line, :ellipsis}, advance(st)}

      {k, line, v} ->
        err(line, "unexpected #{k} #{inspect(v)}")
    end
  end

  defp adjacent_strings(st, acc) do
    case peek(st) do
      {:str, _, {v, _}} ->
        adjacent_strings(advance(st), {:lit, elem(acc, 1), elem(acc, 2) <> v})

      {:fstring, line, {content, flags}} ->
        case fstring(advance(st), line, content, flags) do
          {:ok, f, st} ->
            # merge: "a" f"b" -> concat at runtime
            {:ok, {:binop, elem(acc, 1), "+", acc, f}, st}

          e ->
            e
        end

      _ ->
        {:ok, acc, st}
    end
  end

  defp paren(st, line) do
    case peek(st) do
      {:op, _, ")"} ->
        {:ok, {:tuple, line, []}, advance(st)}

      {:kw, _, "for"} ->
        err(line, "expected expression before 'for'")

      _ ->
        with {:ok, e, st} <- expr(st) do
          case peek(st) do
            {:op, _, ","} ->
              with {:ok, rest, st} <- tuple_items(st, []),
                   {:ok, _, st} <- take_op(st, ")"),
                   do: {:ok, {:tuple, line, [e | rest]}, st}

            {:kw, _, "for"} ->
              with {:ok, clauses, st} <- comp_clauses(st, []),
                   {:ok, _, st} <- take_op(st, ")"),
                   do: {:ok, {:genexp, line, e, clauses}, st}

            {:op, _, ")"} ->
              {:ok, e, advance(st)}

            {k, l2, v} ->
              err(l2, "expected ',' or ')', got #{k} #{inspect(v)}")
          end
        end
    end
  end

  defp tuple_items(st, acc) do
    case maybe_op(st, ",") do
      {false, st} ->
        {:ok, Enum.reverse(acc), st}

      {true, st} ->
        case peek(st) do
          {:op, _, ")"} -> {:ok, Enum.reverse(acc), st}
          {:newline, _, _} -> tuple_items(advance(st), acc)
          {:op, line, "*"} ->
            st = advance(st)

            with {:ok, e, st} <- expr(st),
                 do: tuple_items(st, [{:starred, line, e} | acc])

          _ ->
            with {:ok, e, st} <- expr(st),
                 do: tuple_items(st, [e | acc])
        end
    end
  end

  defp list_expr(st, line) do
    case peek(st) do
      {:op, _, "]"} ->
        {:ok, {:list, line, []}, advance(st)}

      {:op, sline, "*"} ->
        st = advance(st)

        with {:ok, e, st} <- expr(st),
             do: list_rest(st, line, [{:starred, sline, e}])

      _ ->
        with {:ok, e, st} <- expr(st) do
          case peek(st) do
            {:kw, _, "for"} ->
              with {:ok, clauses, st} <- comp_clauses(st, []),
                   {:ok, _, st} <- take_op(st, "]"),
                   do: {:ok, {:listcomp, line, e, clauses}, st}

            _ ->
              list_rest(st, line, [e])
          end
        end
    end
  end

  defp list_rest(st, line, acc) do
    case peek(st) do
      {:op, _, "]"} ->
        {:ok, {:list, line, Enum.reverse(acc)}, advance(st)}

      {:op, _, ","} ->
        st = advance(st)

        case peek(st) do
          {:op, _, "]"} -> {:ok, {:list, line, Enum.reverse(acc)}, advance(st)}
          {:newline, _, _} -> list_rest(advance(st), line, acc)
          {:op, sline, "*"} ->
            st = advance(st)

            with {:ok, e, st} <- expr(st),
                 do: list_rest(st, line, [{:starred, sline, e} | acc])

          _ ->
            with {:ok, e, st} <- expr(st),
                 do: list_rest(st, line, [e | acc])
        end

      {:newline, _, _} ->
        list_rest(advance(st), line, acc)

      {k, l2, v} ->
        err(l2, "expected ',' or ']', got #{k} #{inspect(v)}")
    end
  end

  defp dict_or_set(st, line) do
    case peek(st) do
      {:op, _, "}"} ->
        {:ok, {:dict, line, []}, advance(st)}

      {:op, sline, "**"} ->
        st = advance(st)

        with {:ok, e, st} <- expr(st),
             do: dict_rest(st, line, [{:kwstar, sline, e}])

      _ ->
        with {:ok, e, st} <- expr(st) do
          case peek(st) do
            {:op, _, ":"} ->
              st = advance(st)

              with {:ok, v, st} <- expr(st) do
                case peek(st) do
                  {:kw, _, "for"} ->
                    with {:ok, clauses, st} <- comp_clauses(st, []),
                         {:ok, _, st} <- take_op(st, "}"),
                         do: {:ok, {:dictcomp, line, e, v, clauses}, st}

                  _ ->
                    dict_rest(st, line, [{:pair, e, v}])
                end
              end

            {:kw, _, "for"} ->
              with {:ok, clauses, st} <- comp_clauses(st, []),
                   {:ok, _, st} <- take_op(st, "}"),
                   do: {:ok, {:setcomp, line, e, clauses}, st}

            _ ->
              set_rest(st, line, [e])
          end
        end
    end
  end

  defp dict_rest(st, line, acc) do
    case peek(st) do
      {:op, _, "}"} ->
        {:ok, {:dict, line, Enum.reverse(acc)}, advance(st)}

      {:op, _, ","} ->
        st = advance(st)

        case peek(st) do
          {:op, _, "}"} -> {:ok, {:dict, line, Enum.reverse(acc)}, advance(st)}
          {:newline, _, _} -> dict_rest(advance(st), line, acc)
          {:op, sline, "**"} ->
            st = advance(st)

            with {:ok, e, st} <- expr(st),
                 do: dict_rest(st, line, [{:kwstar, sline, e} | acc])

          _ ->
            with {:ok, k, st} <- expr(st),
                 {:ok, _, st} <- take_op(st, ":"),
                 {:ok, v, st} <- expr(st),
                 do: dict_rest(st, line, [{:pair, k, v} | acc])
        end

      {:newline, _, _} ->
        dict_rest(advance(st), line, acc)

      {k, l2, v} ->
        err(l2, "expected ',' or '}', got #{k} #{inspect(v)}")
    end
  end

  defp set_rest(st, line, acc) do
    case peek(st) do
      {:op, _, "}"} ->
        {:ok, {:set, line, Enum.reverse(acc)}, advance(st)}

      {:op, _, ","} ->
        st = advance(st)

        case peek(st) do
          {:op, _, "}"} -> {:ok, {:set, line, Enum.reverse(acc)}, advance(st)}
          {:newline, _, _} -> set_rest(advance(st), line, acc)
          _ ->
            with {:ok, e, st} <- expr(st),
                 do: set_rest(st, line, [e | acc])
        end

      {:newline, _, _} ->
        set_rest(advance(st), line, acc)

      {k, l2, v} ->
        err(l2, "expected ',' or '}', got #{k} #{inspect(v)}")
    end
  end

  defp comp_clauses(st, acc) do
    case peek(st) do
      {:kw, _, "for"} ->
        st = advance(st)

        with {:ok, target, st} <- target_list(st),
             {:ok, _, st} <- take_kw(st, "in"),
             {:ok, iter, st} <- or_expr(st) do
          target =
            case target do
              [t] -> t
              ts -> {:tuple, 0, ts}
            end

          comp_clauses(st, acc ++ [{:for, target, iter}])
        end

      {:kw, _, "if"} ->
        st = advance(st)

        with {:ok, c, st} <- or_expr(st),
             do: comp_clauses(st, acc ++ [{:if, c}])

      _ ->
        {:ok, acc, st}
    end
  end

  # ---------------- f-strings ----------------

  # content is the raw string body; flags subset of ["r","f","b"]
  defp fstring(st, line, content, flags) do
    case split_fstring(content, line) do
      {:ok, raw_parts} ->
        parts =
          Enum.map(raw_parts, fn
            {:lit, s} ->
              s = if "r" in flags, do: s, else: unescape_lit(s)
              {:str, s}

            {:expr, src, conv, spec} ->
              case Slop.Parser.parse_expression(src) do
                {:ok, e} ->
                  spec_parts =
                    case spec do
                      nil -> nil
                      "" -> nil
                      s ->
                        case split_fstring(s, line) do
                          {:ok, sp} ->
                            Enum.map(sp, fn
                              {:lit, l} -> {:str, l}
                              {:expr, s2, c2, nil} ->
                                case Slop.Parser.parse_expression(s2) do
                                  {:ok, e2} -> {:expr, e2, c2, nil}
                                  _ -> {:expr, {:lit, line, s2}, nil, nil}
                                end
                            end)

                          _ ->
                            [{:str, s}]
                        end
                    end

                  {:expr, e, conv, spec_parts}

                {:error, l2, msg} ->
                  throw({:fstring_error, l2, msg})
              end
          end)

        {:ok, {:fstring, line, parts}, st}

      {:error, _, _} = e ->
        e
    end
  catch
    {:fstring_error, l2, msg} -> err(l2, "in f-string: #{msg}")
  end

  # split into literal and expression parts
  defp split_fstring(content, line) do
    split_fstring(content, line, "", [])
  end

  defp split_fstring("", _line, cur, acc) do
    acc = if cur == "", do: acc, else: [{:lit, cur} | acc]
    {:ok, Enum.reverse(acc)}
  end

  defp split_fstring("{{" <> rest, line, cur, acc),
    do: split_fstring(rest, line, cur <> "{", acc)

  defp split_fstring("}}" <> rest, line, cur, acc),
    do: split_fstring(rest, line, cur <> "}", acc)

  defp split_fstring("{" <> rest, line, cur, acc) do
    acc = if cur == "", do: acc, else: [{:lit, cur} | acc]

    case find_brace(rest, 1, "") do
      {:ok, inner, after_brace} ->
        {expr_src, conv, spec} = parse_fstring_inner(inner)

        split_fstring(after_brace, line, "", [{:expr, String.trim(expr_src), conv, spec} | acc])

      :error ->
        err(line, "unmatched '{' in f-string")
    end
  end

  defp split_fstring(<<c, rest::binary>>, line, cur, acc),
    do: split_fstring(rest, line, cur <> <<c>>, acc)

  defp find_brace("", _depth, _acc), do: :error
  defp find_brace("{" <> rest, depth, acc), do: find_brace(rest, depth + 1, acc <> "{")
  defp find_brace("}" <> rest, 1, acc), do: {:ok, acc, rest}
  defp find_brace("}" <> rest, depth, acc), do: find_brace(rest, depth - 1, acc <> "}")

  defp find_brace(<<q, _::binary>> = src, depth, acc) when q == ?' or q == ?" do
    qlen = if String.slice(src, 0, 3) in ["'''", ~S(""")], do: 3, else: 1
    quote = String.slice(src, 0, qlen)
    body = String.slice(src, qlen..-1//1)

    case find_quote_end(body, quote, "") do
      {:ok, s, rest} -> find_brace(rest, depth, acc <> quote <> s <> quote)
      :error -> :error
    end
  end

  defp find_brace(<<c, rest::binary>>, depth, acc), do: find_brace(rest, depth, acc <> <<c>>)

  defp find_quote_end("", _q, _acc), do: :error

  defp find_quote_end(src, q, acc) do
    cond do
      String.starts_with?(src, q) -> {:ok, acc, String.slice(src, byte_size(q)..-1//1)}
      String.starts_with?(src, "\\") ->
        <<_, c, rest::binary>> = src
        find_quote_end(rest, q, acc <> "\\" <> <<c>>)

      true ->
        <<c, rest::binary>> = src
        find_quote_end(rest, q, acc <> <<c>>)
    end
  end

  # parse "expr[!conv][:spec]"
  defp parse_fstring_inner(inner) do
    {before_spec, spec} = split_top(inner, ?:)

    {expr_src, conv} =
      case split_bang(before_spec) do
        {e, nil} -> {e, nil}
        {e, c} -> {e, c}
      end

    {expr_src, conv, spec}
  end

  # split on top-level char (not inside brackets/strings)
  defp split_top(s, char) do
    split_top(s, char, 0, "")
  end

  defp split_top("", _char, _depth, acc), do: {acc, nil}

  defp split_top(<<c, rest::binary>>, char, depth, acc) do
    cond do
      c == char and depth == 0 ->
        {acc, rest}

      c in [?(, ?[, ?{] ->
        split_top(rest, char, depth + 1, acc <> <<c>>)

      c in [?), ?], ?}] ->
        split_top(rest, char, depth - 1, acc <> <<c>>)

      c == ?' or c == ?" ->
        qlen = if String.slice(<<c, rest::binary>>, 0, 3) in ["'''", ~S(""")], do: 3, else: 1
        quote = String.slice(<<c, rest::binary>>, 0, qlen)
        body = String.slice(rest, qlen - 1..-1//1)

        case find_quote_end(body, quote, "") do
          {:ok, s2, rest2} -> split_top(rest2, char, depth, acc <> quote <> s2 <> quote)
          :error -> split_top(rest, char, depth, acc <> <<c>>)
        end

      true ->
        split_top(rest, char, depth, acc <> <<c>>)
    end
  end

  defp split_bang(s) do
    case :binary.match(s, "!") do
      :nomatch -> {s, nil}
      {idx, 1} ->
        e = String.slice(s, 0, idx)
        c = String.slice(s, idx + 1, 1)

        if c in ["r", "s", "a"] do
          {e, c}
        else
          {s, nil}
        end
    end
  end

  defp unescape_lit(s) do
    # reuse lexer unescape by lexing a synthetic quoted string
    case Slop.Lexer.tokenize("\"#{s}\"") do
      {:ok, [{:str, _, {v, _}} | _]} -> v
      _ -> s
    end
  end
end
