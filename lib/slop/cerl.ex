defmodule Slop.Cerl do
  @moduledoc "Thin constructors over :cerl for readable codegen."
  alias :cerl, as: C

  def lit(x), do: C.abstract(x)
  def var(n) when is_integer(n), do: C.c_var(n)
  def var(n) when is_atom(n), do: C.c_var(n)
  def call(m, f, args), do: C.c_call(lit(m), lit(f), args)
  def apply_(fexpr, args), do: C.c_apply(fexpr, args)
  def seq(a, b), do: C.c_seq(a, b)
  def seqs([]), do: lit(nil)
  def seqs([e]), do: e
  def seqs([a | rest]), do: C.c_seq(a, seqs(rest))
  def let_(vars, arg, body), do: C.c_let(vars, arg, body)
  def letrec(defs, body), do: C.c_letrec(defs, body)
  def case_(arg, clauses), do: C.c_case(arg, clauses)
  def clause(pats, guard, body), do: C.c_clause(pats, guard, body)
  def clause(pats, body), do: C.c_clause(pats, lit(true), body)
  def fun(args, body), do: C.c_fun(args, body)
  def fname(n, a), do: C.c_fname(n, a)
  def tuple(l), do: C.c_tuple(l)
  def cons(h, t), do: C.c_cons(h, t)
  def nil_(), do: C.c_nil()

  def list_lit(items), do: Enum.reduce(Enum.reverse(items), nil_(), &cons(&1, &2))

  # BEAM map literals require keys in Erlang term order; out-of-order keys
  # break beam_kernel_to_ssa on OTP 24
  def map_lit(pairs) do
    sorted = Enum.sort_by(pairs, fn {k, _} -> k end, &term_lte/2)
    C.ann_c_map([], lit(%{}), Enum.map(sorted, fn {k, v} -> C.c_map_pair(lit(k), v) end))
  end

  defp term_lte(a, b) do
    :erlang.term_to_binary(a) <= :erlang.term_to_binary(b)
  end

  def map_update(arg, pairs) do
    C.ann_c_map([], arg, Enum.map(pairs, fn {k, v} -> C.c_map_pair(lit(k), v) end))
  end

  def try_(arg, vars, body, evars, handler), do: C.c_try(arg, vars, body, evars, handler)

  def reraise(cls, reason, st), do: C.c_primop(lit(:raw_raise), [cls, reason, st])

  def make_fun(m, f, a), do: call(:erlang, :make_fun, [lit(m), lit(f), lit(a)])

  def truthy(e), do: call(:slop_rt, :truthy, [e])

  # case truthy(cond) of true -> then_e; false -> else_e end
  def if_truthy(cond, then_e, else_e) do
    case_(truthy(cond), [
      clause([lit(true)], then_e),
      clause([lit(false)], else_e)
    ])
  end

  # let <v> = arg in body  (single fresh var convenience)
  def bind1(var, arg, body), do: let_([var], arg, body)

  # destructure a tuple via element/2 calls: binds vars[i] = element(i+1, tuple_var)
  def destructure(tuple_expr, n, body_fn) when n >= 1 do
    tv = var_counter_ref()
    # build nested lets: let T = tuple_expr in let V1 = element(1,T) ... in body
    vars = for _ <- 1..n, do: fresh()

    inner =
      Enum.zip(vars, 1..n)
      |> Enum.reverse()
      |> Enum.reduce(body_fn.(vars), fn {v, i}, acc ->
        let_([v], call(:erlang, :element, [lit(i), tv]), acc)
      end)

    let_([tv], tuple_expr, inner)
  end

  # a tiny process-local counter so nested calls get distinct fresh vars
  defp var_counter_ref do
    n = Process.get(:slop_cerl_counter, 0) + 1
    Process.put(:slop_cerl_counter, n)
    var(n)
  end

  def fresh do
    n = Process.get(:slop_cerl_counter, 0) + 1
    Process.put(:slop_cerl_counter, n)
    var(n)
  end

  def reset_counter do
    Process.put(:slop_cerl_counter, 0)
    :ok
  end
end
