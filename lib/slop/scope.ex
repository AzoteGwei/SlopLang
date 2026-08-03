defmodule Slop.Scope do
  @moduledoc """
  Static scope analysis: which names are assigned in a suite of statements
  (respecting Python's rule that any assignment in a function body makes the
  name local unless declared global).
  """

  # assigned names in a list of statements (not descending into nested def/class bodies)
  def assigned(stmts) do
    Enum.reduce(stmts, MapSet.new(), &stmt_assigned/2)
  end

  defp stmt_assigned({:assign, _, targets, value}, acc) do
    acc = Enum.reduce(targets, acc, fn t, a -> target_names(t, a) end)
    expr_names(value, acc)
  end

  defp stmt_assigned({:augassign, _, target, _, value}, acc) do
    acc |> then(&target_root(target, &1)) |> then(&expr_names(value, &1))
  end

  defp stmt_assigned({:annassign, _, target, ann, value}, acc) do
    acc = target_root(target, acc)
    acc = expr_names(ann, acc)

    if value, do: expr_names(value, acc), else: acc
  end

  defp stmt_assigned({:exprstmt, _, {:call, _, {:attr, _, {:name, _, root}, _}, _, _} = e}, acc) do
    # statement-level method call rebinds the root name to the call result
    acc = MapSet.put(acc, root)
    expr_names(e, acc)
  end

  defp stmt_assigned({:exprstmt, _, e}, acc), do: expr_names(e, acc)
  defp stmt_assigned({:return, _, e}, acc), do: if(e, do: expr_names(e, acc), else: acc)
  defp stmt_assigned({:pass, _}, acc), do: acc
  defp stmt_assigned({:break, _}, acc), do: acc
  defp stmt_assigned({:continue, _}, acc), do: acc

  defp stmt_assigned({:if, _, c, body, orelse}, acc) do
    acc = expr_names(c, acc)
    acc = assigned(body) |> MapSet.union(acc)
    assigned(orelse) |> MapSet.union(acc)
  end

  defp stmt_assigned({:while, _, c, body, orelse}, acc) do
    acc = expr_names(c, acc)
    acc = assigned(body) |> MapSet.union(acc)
    assigned(orelse) |> MapSet.union(acc)
  end

  defp stmt_assigned({:for, _, target, iter, body, orelse}, acc) do
    acc = target_names(target, acc)
    acc = expr_names(iter, acc)
    acc = assigned(body) |> MapSet.union(acc)
    assigned(orelse) |> MapSet.union(acc)
  end

  defp stmt_assigned({:def, _, name, _, _, _, _}, acc), do: MapSet.put(acc, name)
  defp stmt_assigned({:class, _, name, _, _, _}, acc), do: MapSet.put(acc, name)

  defp stmt_assigned({:import, _, mods}, acc) do
    Enum.reduce(mods, acc, fn {mod, asname}, a ->
      MapSet.put(a, asname || hd(String.split(mod, ".")))
    end)
  end

  defp stmt_assigned({:from, _, _, names}, acc) when is_list(names) do
    Enum.reduce(names, acc, fn {n, asname}, a -> MapSet.put(a, asname || n) end)
  end

  defp stmt_assigned({:from, _, _, :star}, acc), do: acc

  defp stmt_assigned({:global, _, _}, acc), do: acc

  defp stmt_assigned({:raise, _, e, from}, acc) do
    acc = if(e, do: expr_names(e, acc), else: acc)
    if(from, do: expr_names(from, acc), else: acc)
  end

  defp stmt_assigned({:try, _, body, handlers, orelse, fin}, acc) do
    acc = assigned(body) |> MapSet.union(acc)

    acc =
      Enum.reduce(handlers, acc, fn {_, name, hbody}, a ->
        a = if(name, do: MapSet.put(a, name), else: a)
        MapSet.union(assigned(hbody), a)
      end)

    acc = MapSet.union(assigned(orelse), acc)
    MapSet.union(assigned(fin), acc)
  end

  defp stmt_assigned({:match, _, subj, cases}, acc) do
    acc = expr_names(subj, acc)

    Enum.reduce(cases, acc, fn {pat, guard, body, _}, a ->
      a = pattern_names(pat, a)
      a = if(guard, do: expr_names(guard, a), else: a)
      MapSet.union(assigned(body), a)
    end)
  end

  defp stmt_assigned({:assert, _, t, m}, acc) do
    acc = expr_names(t, acc)
    if(m, do: expr_names(m, acc), else: acc)
  end

  defp stmt_assigned({:del, _, targets}, acc) do
    Enum.reduce(targets, acc, fn
      {:name, _, n}, a -> MapSet.put(a, n)
      t, a -> target_root(t, a)
    end)
  end

  defp stmt_assigned({:with, _, items, body}, acc) do
    acc =
      Enum.reduce(items, acc, fn {ctx, name}, a ->
        a = if(name, do: MapSet.put(a, name), else: a)
        expr_names(ctx, a)
      end)

    MapSet.union(assigned(body), acc)
  end

  defp stmt_assigned(_, acc), do: acc

  # all names bound by a target (for assignment/unpack purposes)
  def target_names(target, acc \\ MapSet.new())

  def target_names({:name, _, n}, acc), do: MapSet.put(acc, n)

  def target_names({:tuple, _, ts}, acc),
    do: Enum.reduce(ts, acc, &target_names/2)

  def target_names({:list, _, ts}, acc),
    do: Enum.reduce(ts, acc, &target_names/2)

  def target_names({:starred, _, t}, acc), do: target_names(t, acc)
  def target_names({:attr, _, obj, _}, acc), do: target_root(obj, acc)
  def target_names({:subscript, _, obj, _}, acc), do: target_root(obj, acc)
  def target_names(_, acc), do: acc

  # just the root name of an assignable chain
  defp target_root({:name, _, n}, acc), do: MapSet.put(acc, n)
  defp target_root({:attr, _, obj, _}, acc), do: target_root(obj, acc)
  defp target_root({:subscript, _, obj, _}, acc), do: target_root(obj, acc)
  defp target_root({:tuple, _, ts}, acc), do: Enum.reduce(ts, acc, &target_names/2)
  defp target_root({:list, _, ts}, acc), do: Enum.reduce(ts, acc, &target_names/2)
  defp target_root({:starred, _, t}, acc), do: target_names(t, acc)
  defp target_root(_, acc), do: acc

  def pattern_names(pat, acc \\ MapSet.new())

  def pattern_names({:p_capture, _, n}, acc), do: MapSet.put(acc, n)
  def pattern_names({:p_wild, _}, acc), do: acc
  def pattern_names({:p_lit, _, _}, acc), do: acc
  def pattern_names({:p_value, _, e}, acc), do: expr_names(e, acc)

  def pattern_names({:p_seq, _, elems, _}, acc),
    do: Enum.reduce(elems, acc, &pattern_names/2)

  def pattern_names({:p_tuple, _, elems, _}, acc),
    do: Enum.reduce(elems, acc, &pattern_names/2)

  def pattern_names({:p_map, _, pairs, rest}, acc) do
    acc = Enum.reduce(pairs, acc, fn {_k, p}, a -> pattern_names(p, a) end)
    if(rest, do: MapSet.put(acc, rest), else: acc)
  end

  def pattern_names({:p_class, _, class_e, kwps}, acc) do
    acc = expr_names(class_e, acc)
    Enum.reduce(kwps, acc, fn {_k, p}, a -> pattern_names(p, a) end)
  end

  def pattern_names({:p_or, _, ps}, acc), do: Enum.reduce(ps, acc, &pattern_names/2)
  def pattern_names({:p_as, _, p, n}, acc), do: MapSet.put(pattern_names(p, acc), n)

  # walrus (namedexpr) names inside expressions
  def expr_names(e, acc \\ MapSet.new())

  def expr_names({:namedexpr, _, n, v}, acc) do
    expr_names(v, MapSet.put(acc, n))
  end

  def expr_names({:binop, _, _, l, r}, acc), do: expr_names(r, expr_names(l, acc))
  def expr_names({:boolop, _, _, l, r}, acc), do: expr_names(r, expr_names(l, acc))
  def expr_names({:unary, _, _, e}, acc), do: expr_names(e, acc)

  def expr_names({:compare, _, ops}, acc) do
    Enum.reduce(ops, acc, fn {_, l, r}, a -> expr_names(r, expr_names(l, a)) end)
  end

  def expr_names({:ifexp, _, c, t, e}, acc),
    do: expr_names(e, expr_names(t, expr_names(c, acc)))

  def expr_names({:call, _, f, args, kwargs}, acc) do
    acc = expr_names(f, acc)

    acc =
      Enum.reduce(args, acc, fn
        {:star, _, e}, a -> expr_names(e, a)
        e, a -> expr_names(e, a)
      end)

    Enum.reduce(kwargs, acc, fn
      {:kw, _, e}, a -> expr_names(e, a)
      {:kwstar, _, e}, a -> expr_names(e, a)
    end)
  end

  def expr_names({:attr, _, o, _}, acc), do: expr_names(o, acc)

  def expr_names({:subscript, _, o, idx}, acc) do
    acc = expr_names(o, acc)

    case idx do
      {:slice, _, lo, hi, st} ->
        acc = if(lo, do: expr_names(lo, acc), else: acc)
        acc = if(hi, do: expr_names(hi, acc), else: acc)
        if(st, do: expr_names(st, acc), else: acc)

      _ ->
        expr_names(idx, acc)
    end
  end

  def expr_names({:list, _, elems}, acc), do: elem_names(elems, acc)
  def expr_names({:tuple, _, elems}, acc), do: elem_names(elems, acc)
  def expr_names({:set, _, elems}, acc), do: elem_names(elems, acc)

  def expr_names({:dict, _, pairs}, acc) do
    Enum.reduce(pairs, acc, fn
      {:pair, k, v}, a -> expr_names(v, expr_names(k, a))
      {:kwstar, _, e}, a -> expr_names(e, a)
    end)
  end

  def expr_names({:lambda, _, _params, _body}, acc), do: acc

  def expr_names({tag, _, e, clauses}, acc)
      when tag in [:listcomp, :setcomp, :genexp] do
    acc = expr_names(e, acc)

    Enum.reduce(clauses, acc, fn
      {:for, _t, iter}, a -> expr_names(iter, a)
      {:if, c}, a -> expr_names(c, a)
    end)
  end

  def expr_names({:dictcomp, _, k, v, clauses}, acc) do
    acc = expr_names(v, expr_names(k, acc))

    Enum.reduce(clauses, acc, fn
      {:for, _t, iter}, a -> expr_names(iter, a)
      {:if, c}, a -> expr_names(c, a)
    end)
  end

  def expr_names({:fstring, _, parts}, acc) do
    Enum.reduce(parts, acc, fn
      {:str, _}, a -> a
      {:expr, e, _conv, spec}, a ->
        a = expr_names(e, a)

        if spec do
          Enum.reduce(spec, a, fn
            {:str, _}, a2 -> a2
            {:expr, e2, _, _}, a2 -> expr_names(e2, a2)
          end)
        else
          a
        end
    end)
  end

  def expr_names(_, acc), do: acc

  defp elem_names(elems, acc) do
    Enum.reduce(elems, acc, fn
      {:starred, _, e}, a -> expr_names(e, a)
      e, a -> expr_names(e, a)
    end)
  end
end
