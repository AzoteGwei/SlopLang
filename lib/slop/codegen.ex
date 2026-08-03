defmodule Slop.Codegen do
  @moduledoc """
  Translates the SlopLang AST into Core Erlang (cerl) forms.

  Conventions:
  - every SlopLang function becomes a BEAM function of arity 3:
    (ArgsList, KwargsMap, DefaultsTuple); call sites use wrapper funs of
    arity 2 so the runtime protocol is always fun(Pos, Kw).
  - locals are SSA-renamed cerl variables; branching constructs merge
    variable versions by returning tuples destructured via element/2.
  - `return`/`break`/`continue` are implemented as tagged throws caught
    by the nearest enclosing function/loop.
  """
  import Slop.Cerl, except: [reraise: 3]
  alias Slop.Scope

  defmodule CompileError do
    defexception [:message, :line]
  end

  @builtin_classes ~w(int float str bool list tuple dict set frozenset object
    function module NoneType
    BaseException Exception ArithmeticError ZeroDivisionError LookupError
    IndexError KeyError ValueError TypeError RuntimeError AttributeError
    NameError UnboundLocalError StopIteration NotImplementedError OSError
    FileNotFoundError AssertionError ImportError EOFError)a

  # nested lets from a list of {var, expr} bindings
  defp bind_lets([], body), do: body
  defp bind_lets([{v, e} | rest], body), do: let_([v], e, bind_lets(rest, body))

  # =====================================================================
  # module compilation
  # =====================================================================

  # returns {:ok, cerl_module, exports :: [String.t]}
  def compile_module({:module, _, stmts}, modname, opts \\ []) do
    Slop.Cerl.reset_counter()
    mod_atom = String.to_atom(modname)

    mod_bindings = scan_mod_bindings(stmts)

    ctx = %{
      mod: mod_atom,
      modname: modname,
      env: %{},
      locals: nil,
      globals_decl: MapSet.new(),
      loop: nil,
      class: nil,
      is_method: false,
      self_name: nil,
      ret_id: nil,
      exc_info: nil,
      mod_bindings: mod_bindings,
      defs: [],
      opts: opts,
      main?: Keyword.get(opts, :main?, false)
    }

    # pre-compile top-level function defs
    {ctx, top_defs} =
      Enum.reduce(stmts, {ctx, []}, fn
        {:def, _, name, params, body, _decos, _ann}, {c, acc} ->
          {defc, defn} = compile_fundef(c, name, params, body, nil)
          {defc, acc ++ [defn]}

        _, acc ->
          acc
      end)

    {init_body, ctx} = compile_init(ctx, stmts)

    init_def = {fname(:"$__init__", 0), fun([], init_body)}

    name_var = fresh()
    attr_def =
      {fname(:"$__attr__", 1), fun([name_var], compile_attr_lookup(name_var))}

    mod_info0 =
      {fname(:module_info, 0), fun([], call(:erlang, :get_module_info, [lit(mod_atom)]))}

    mi1_arg = fresh()

    mod_info1 =
      {fname(:module_info, 1),
       fun([mi1_arg], call(:erlang, :get_module_info, [lit(mod_atom), mi1_arg]))}

    all_defs = top_defs ++ ctx.defs ++ [init_def, attr_def, mod_info0, mod_info1]

    exports = [
      fname(:"$__init__", 0),
      fname(:"$__attr__", 1),
      fname(:module_info, 0),
      fname(:module_info, 1)
    ]

    mod_form = :cerl.c_module(lit(mod_atom), exports, [], all_defs)

    exports_list =
      mod_bindings
      |> Map.keys()
      |> Enum.reject(&String.starts_with?(&1, "_"))

    {:ok, mod_form, exports_list}
  end

  defp compile_attr_lookup(name_var) do
    init_result = fresh()
    v = fresh()

    let_([init_result], apply_(fname(:"$__init__", 0), []),
      case_(
        call(:maps, :find, [name_var, init_result]),
        [
          clause([tuple([lit(:ok), v])], v),
          clause(
            [fresh()],
            call(:slop_rt, :raise_exc, [
              lit(:AttributeError),
              call(:erlang, :++, [
                call(:erlang, :atom_to_binary, [name_var, lit(:utf8)]),
                lit(<<"' is not defined in this module">>)
              ])
            ])
          )
        ]
      )
    )
  end

  defp compile_init(ctx, stmts) do
    {suite_expr, ctx} = compile_stmts(%{ctx | locals: nil}, stmts)

    m = fresh()

    get_map = call(:persistent_term, :get, [lit({:slop_mod, ctx.mod}), lit(:undefined)])

    fun_body =
      case_(get_map, [
        clause(
          [lit(:undefined)],
          seq(
            call(:persistent_term, :put, [lit({:slop_mod, ctx.mod}), map_lit([])]),
            seq(
              suite_expr,
              call(:persistent_term, :get, [lit({:slop_mod, ctx.mod}), map_lit([])])
            )
          )
        ),
        clause([m], m)
      ])

    {fun_body, ctx}
  end

  defp scan_mod_bindings(stmts) do
    Enum.reduce(stmts, %{}, fn
      {:def, _, name, _, _, _, _}, acc ->
        Map.put(acc, name, :fun)

      {:class, _, name, _, _, _}, acc ->
        Map.put(acc, name, :class)

      {:import, _, mods}, acc ->
        Enum.reduce(mods, acc, fn {mod, asname}, a ->
          Map.put(a, asname || hd(String.split(mod, ".")), {:module, String.to_atom(mod)})
        end)

      {:from, _, _mod, names}, acc when is_list(names) ->
        Enum.reduce(names, acc, fn {n, asname}, a -> Map.put(a, asname || n, :value) end)

      {:assign, _, targets, _}, acc ->
        Enum.reduce(targets, acc, fn t, a ->
          Scope.target_names(t)
          |> Enum.reduce(a, fn n, a2 -> Map.put(a2, n, :value) end)
        end)

      {:annassign, _, {:name, _, n}, _, _}, acc ->
        Map.put(acc, n, :value)

      {:augassign, _, {:name, _, n}, _, _}, acc ->
        Map.put(acc, n, :value)

      _, acc ->
        acc
    end)
  end

  # =====================================================================
  # function definitions
  # =====================================================================

  # returns {ctx, {fname, c_fun}} - a module-level BEAM def
  # class_info: nil | {fq_class_atom, static?}
  defp compile_fundef(ctx, name, params, body, class_info) do
    {beam_name, is_method} =
      case class_info do
        nil -> {String.to_atom(name), false}
        {fq, static?} -> {String.to_atom("#{fq}.#{name}"), not static?}
      end

    fname3 = fname(beam_name, 3)
    ret_id = fresh_id()

    a_var = fresh()
    k_var = fresh()
    d_var = fresh()

    locals =
      params_names(params)
      |> MapSet.union(Scope.assigned(body))

    globals_decl = globals_declared(body)

    inner_ctx = %{
      ctx
      | env: %{},
        locals: locals,
        globals_decl: globals_decl,
        loop: nil,
        class: class_info && elem(class_info, 0),
        is_method: is_method,
        self_name: method_self_name(params, is_method),
        ret_id: ret_id,
        exc_info: nil
    }

    core_body = emit_param_bind(inner_ctx, a_var, k_var, d_var, params, body)

    wrapped = wrap_ret(core_body, ret_id)

    {ctx, {fname3, fun([a_var, k_var, d_var], wrapped)}}
  end

  # wraps a function body to catch its tagged return-throw
  defp wrap_ret(core_body, ret_id) do
    c_v = fresh()
    r_v = fresh()
    st_v = fresh()
    res_v = fresh()
    val = fresh()

    try_(
      core_body,
      [res_v],
      res_v,
      [c_v, r_v, st_v],
      case_(
        tuple([c_v, r_v]),
        [
          clause([tuple([lit(:throw), tuple([lit(:"$ret"), lit(ret_id), val])])], val),
          clause([fresh()], Slop.Cerl.reraise(c_v, r_v, st_v))
        ]
      )
    )
  end

  defp method_self_name(%{pos: [{n, _, _} | _]}, true), do: n
  defp method_self_name(_, _), do: nil

  defp globals_declared(body) do
    Enum.reduce(body, MapSet.new(), fn
      {:global, _, names}, acc -> MapSet.union(acc, MapSet.new(names))
      _, acc -> acc
    end)
  end

  defp params_names(%{pos: pos, vararg: va, kwonly: kwo, kwarg: kw}) do
    s = MapSet.new(Enum.map(pos, &elem(&1, 0)))
    s = if va, do: MapSet.put(s, elem(va, 0)), else: s
    s = MapSet.union(s, MapSet.new(Enum.map(kwo, &elem(&1, 0))))
    if kw, do: MapSet.put(s, elem(kw, 0)), else: s
  end

  # emits: case slop_rt:bind_params(...) of {vals, va, kr} -> body end
  defp emit_param_bind(ctx, a_var, k_var, d_var, params, body_stmts) do
    spec = params_spec(params)

    all_named = params.pos ++ params.kwonly
    val_vars = for _ <- all_named, do: fresh()
    va_var = fresh()
    kr_var = fresh()

    bind_call = call(:slop_rt, :bind_params, [spec, d_var, a_var, k_var])

    env_ctx = bind_params_env(ctx, params, val_vars, va_var, kr_var)
    {body_expr, end_ctx} = compile_stmts(env_ctx, body_stmts)

    implicit =
      if ctx.is_method and ctx.self_name do
        case end_ctx.env[ctx.self_name] do
          {:local, v, _} -> v
          _ -> lit(nil)
        end
      else
        lit(nil)
      end

    n_params = length(all_named)

    if n_params == 0 and is_nil(params.vararg) and is_nil(params.kwarg) do
      seq(bind_call, seq(body_expr, implicit))
    else
      case_(bind_call, [
        clause([tuple([list_pattern(val_vars), va_var, kr_var])], seq(body_expr, implicit))
      ])
    end
  end

  defp bind_params_env(ctx, params, val_vars, va_var, kr_var) do
    names = Enum.map(params.pos ++ params.kwonly, &elem(&1, 0))

    env =
      Enum.zip(names, val_vars)
      |> Enum.reduce(ctx.env, fn {n, v}, e -> Map.put(e, n, {:local, v, false}) end)

    env =
      case params.vararg do
        nil -> env
        {n, _} -> Map.put(env, n, {:local, va_var, false})
      end

    env =
      case params.kwarg do
        nil -> env
        {n, _} -> Map.put(env, n, {:local, kr_var, false})
      end

    %{ctx | env: env}
  end

  defp params_spec(params) do
    lit(%{
      pos: Enum.map(params.pos, fn {n, d, _} -> {String.to_atom(n), not is_nil(d)} end),
      vararg:
        case params.vararg do
          nil -> nil
          {n, _} -> String.to_atom(n)
        end,
      kwonly: Enum.map(params.kwonly, fn {n, d, _} -> {String.to_atom(n), not is_nil(d)} end),
      kwarg:
        case params.kwarg do
          nil -> nil
          {n, _} -> String.to_atom(n)
        end
    })
  end

  defp list_pattern([]), do: nil_()
  defp list_pattern([v | rest]), do: cons(v, list_pattern(rest))

  # wrapper fun value closing over defaults: fun(A, K) -> fname(A, K, {defaults})
  defp emit_def_wrapper(ctx, fname3, params) do
    a = fresh()
    k = fresh()

    defaults = Enum.filter(params.pos ++ params.kwonly, fn {_, d, _} -> d != nil end)

    {def_exprs, ctx} =
      Enum.map_reduce(defaults, ctx, fn {_, d, _}, c -> compile_expr(c, d) end)

    {fun([a, k], apply_(fname3, [a, k, tuple(def_exprs)])), ctx}
  end

  # =====================================================================
  # statements
  # =====================================================================

  # A statement normally returns {cerl_expr, ctx} and is sequenced before the
  # rest of the suite. Statements that bind merged branch variables (if/while/
  # for/try/match at function level) instead return {{:wrap, cont}, ctx} where
  # cont is a fun taking the rest-of-suite expression, so the destructuring
  # lets enclose everything that follows.
  defp compile_stmts(ctx, []), do: {lit(nil), ctx}

  defp compile_stmts(ctx, [stmt | rest]) do
    {e, ctx2} = compile_stmt(ctx, stmt)
    {rest_e, ctx3} = compile_stmts(ctx2, rest)

    case e do
      {:wrap, cont} when is_function(cont, 1) -> {cont.(rest_e), ctx3}
      _ -> {seq(e, rest_e), ctx3}
    end
  end

  defp compile_stmt(ctx, {:pass, _}), do: {lit(nil), ctx}
  defp compile_stmt(ctx, {:block, _, stmts}), do: compile_stmts(ctx, stmts)

  defp compile_stmt(ctx, {:exprstmt, _, e}), do: compile_exprstmt(ctx, e)

  defp compile_stmt(ctx, {:return, _, e}) do
    {vexpr, ctx} = if e, do: compile_expr(ctx, e), else: {lit(nil), ctx}
    {v, ctx} = ensure_var(ctx, vexpr)
    {call(:erlang, :throw, [tuple([lit(:"$ret"), lit(ctx.ret_id), v])]), ctx}
  end

  defp compile_stmt(ctx, {:break, _}) do
    case ctx.loop do
      nil ->
        raise CompileError, message: "'break' outside loop", line: 0

      {id, state_names, :while} ->
        state = state_vars(ctx, state_names)
        {call(:erlang, :throw, [tuple([lit(:"$brk"), lit(id), tuple(state)])]), ctx}

      {id, state_names, :for} ->
        state = state_vars(ctx, state_names)
        t = Map.get(ctx, :for_rest_var)

        if t do
          {call(:erlang, :throw, [tuple([lit(:"$cnt"), lit(id), tuple([t | state])])]), ctx}
        else
          {call(:erlang, :throw, [tuple([lit(:"$brk"), lit(id), tuple(state)])]), ctx}
        end
    end
  end

  defp compile_stmt(ctx, {:continue, _}) do
    case ctx.loop do
      nil ->
        raise CompileError, message: "'continue' outside loop", line: 0

      {id, state_names, :while} ->
        state = state_vars(ctx, state_names)
        {call(:erlang, :throw, [tuple([lit(:"$cnt"), lit(id), tuple(state)])]), ctx}

      {id, state_names, :for} ->
        state = state_vars(ctx, state_names)
        t = Map.get(ctx, :for_rest_var)
        {call(:erlang, :throw, [tuple([lit(:"$cnt"), lit(id), tuple([t | state])])]), ctx}
    end
  end

  defp compile_stmt(ctx, {:assign, _, targets, value}) do
    {vexpr, ctx} = compile_expr(ctx, value)
    {v, ctx} = ensure_var(ctx, vexpr)

    Enum.reduce(targets, {lit(nil), ctx}, fn t, {acc, c} ->
      {e, c2} = compile_assign(c, t, v)
      {seq(acc, e), c2}
    end)
  end

  defp compile_stmt(ctx, {:annassign, _, target, _ann, value}) do
    case value do
      nil ->
        {lit(nil), ctx}

      _ ->
        {vexpr, ctx} = compile_expr(ctx, value)
        {v, ctx} = ensure_var(ctx, vexpr)
        compile_assign(ctx, target, v)
    end
  end

  defp compile_stmt(ctx, {:augassign, _, target, op, value}) do
    {eexpr, ctx} = compile_expr(ctx, value)

    case target do
      {:name, _, n} ->
        {cur, ctx} = read_name(ctx, n)
        assign_name(ctx, n, call(:slop_rt, :binop, [lit(op), cur, eexpr]))

      {:attr, _, _, attr} ->
        {cur, ctx} = compile_expr(ctx, target)
        newv = call(:slop_rt, :binop, [lit(op), cur, eexpr])
        {nv, ctx} = ensure_var(ctx, newv)
        rebuild(ctx, target, nv)

      {:subscript, _, _, _} ->
        {cur, ctx} = compile_expr(ctx, target)
        newv = call(:slop_rt, :binop, [lit(op), cur, eexpr])
        {nv, ctx} = ensure_var(ctx, newv)
        rebuild(ctx, target, nv)

      _ ->
        {lit(nil), ctx}
    end
  end

  defp compile_stmt(ctx, {:del, _, targets}) do
    Enum.reduce(targets, {lit(nil), ctx}, fn t, {acc, c} ->
      {e, c2} = compile_del(c, t)
      {seq(acc, e), c2}
    end)
  end

  defp compile_del(ctx, {:name, _, n}) do
    cond do
      MapSet.member?(ctx.globals_decl, n) or ctx.locals == nil ->
        {call(:slop_rt, :global_del, [lit(ctx.mod), lit(String.to_atom(n))]), ctx}

      true ->
        {lit(nil), %{ctx | env: Map.delete(ctx.env, n)}}
    end
  end

  defp compile_del(ctx, {:attr, _, obj, attr}) do
    {obj_e, ctx} = compile_expr(ctx, obj)
    {obj_v, ctx} = ensure_var(ctx, obj_e)
    upd = call(:slop_rt, :delattr, [obj_v, lit(String.to_atom(attr))])
    {uv, ctx} = ensure_var(ctx, upd)
    rebuild(ctx, obj, uv)
  end

  defp compile_del(ctx, {:subscript, _, obj, idx}) do
    {obj_e, ctx} = compile_expr(ctx, obj)
    {obj_v, ctx} = ensure_var(ctx, obj_e)
    {idx_e, ctx} = compile_subscript_index(ctx, idx)
    {idx_v, ctx} = ensure_var(ctx, idx_e)
    upd = call(:slop_rt, :delitem, [obj_v, idx_v])
    {uv, ctx} = ensure_var(ctx, upd)
    rebuild(ctx, obj, uv)
  end

  defp compile_del(_ctx, {tag, line, _}) do
    raise CompileError, message: "unsupported del target #{tag}", line: line
  end

  defp compile_stmt(ctx, {:if, _, cond_e, body, orelse}) do
    {condc, ctx} = compile_expr(ctx, cond_e)
    merge = merge_names(ctx, [body, orelse])

    {then_expr, then_ctx} = compile_stmts(ctx, body)
    {else_expr, else_ctx} = compile_stmts(ctx, orelse)

    then_e = seq(then_expr, tuple(Enum.map(merge, &branch_value(ctx, then_ctx, &1))))
    else_e = seq(else_expr, tuple(Enum.map(merge, &branch_value(ctx, else_ctx, &1))))

    res = if_truthy(condc, then_e, else_e)
    merge_after(ctx, res, merge, [then_ctx, else_ctx])
  end

  defp compile_stmt(ctx, {:while, _, cond_e, body, orelse}) do
    id = fresh_id()
    state_names = loop_state_names(ctx, body)
    n = length(state_names)

    param_vars = for _ <- state_names, do: fresh()

    body_env =
      Enum.zip(state_names, param_vars)
      |> Enum.reduce(ctx.env, fn {name, v}, e -> Map.put(e, name, {:local, v, false}) end)

    body_ctx = %{ctx | env: body_env, loop: {id, state_names, :while}}

    {condc, _} = compile_expr(body_ctx, cond_e)
    {body_expr, body_end_ctx} = compile_stmts(body_ctx, body)

    cont_tuple = tuple([lit(:cont)] ++ state_vars(body_end_ctx, state_names))

    # try around the body catching brk/cnt for this loop id
    c_v = fresh()
    r_v = fresh()
    st_v = fresh()
    res_v = fresh()
    try_res = fresh()

    st1 = for _ <- state_names, do: fresh()
    st2 = for _ <- state_names, do: fresh()
    st3 = for _ <- state_names, do: fresh()

    caught =
      case_(tuple([c_v, r_v]), [
        clause(
          [tuple([lit(:throw), tuple([lit(:"$brk"), lit(id), tuple(st1)])])],
          tuple([lit(:brk)] ++ st1)
        ),
        clause(
          [tuple([lit(:throw), tuple([lit(:"$cnt"), lit(id), tuple(st2)])])],
          tuple([lit(:cnt)] ++ st2)
        ),
        clause([fresh()], Slop.Cerl.reraise(c_v, r_v, st_v))
      ])

    loop_fname = fname(:"while$#{id}", n)

    driver =
      case_(try_res, [
        clause([tuple([lit(:cont)] ++ st3)], apply_(loop_fname, st3)),
        clause([tuple([lit(:cnt)] ++ st3)], apply_(loop_fname, st3)),
        clause([tuple([lit(:brk)] ++ st3)], tuple([lit(:done), lit(true)] ++ st3))
      ])

    loop_body =
      if_truthy(
        condc,
        let_([try_res], try_(seq(body_expr, cont_tuple), [res_v], res_v, [c_v, r_v, st_v], caught), driver),
        tuple([lit(:done), lit(false)] ++ param_vars)
      )

    init_vals =
      Enum.map(state_names, fn name ->
        case ctx.env[name] do
          {:local, v, _} -> v
          _ -> lit(:"$unbound")
        end
      end)

    res_var = fresh()
    aft = after_loop_body(ctx, res_var, state_names, orelse)

    cont = fn rest ->
      letrec([{loop_fname, fun(param_vars, loop_body)}],
        let_([res_var], apply_(loop_fname, init_vals), aft.cont.(rest))
      )
    end

    {{:wrap, cont}, aft.ctx}
  end

  defp compile_stmt(ctx, {:for, _, target, iter, body, orelse}) do
    id = fresh_id()
    state_names = loop_state_names(ctx, body)

    param_vars = for _ <- state_names, do: fresh()
    l_var = fresh()
    h_var = fresh()
    t_var = fresh()
    res_v = fresh()
    try_res = fresh()
    c_v = fresh()
    r_v = fresh()
    st_v = fresh()

    body_env =
      Enum.zip(state_names, param_vars)
      |> Enum.reduce(ctx.env, fn {name, v}, e -> Map.put(e, name, {:local, v, false}) end)

    {bind_expr, bind_ctx} =
      compile_assign(%{ctx | env: body_env, loop: nil}, target, h_var)

    body_ctx = %{bind_ctx | loop: {id, state_names, :for}} |> Map.put(:for_rest_var, t_var)

    {body_expr, body_end_ctx} = compile_stmts(body_ctx, body)

    cont_tuple = tuple([lit(:cont), t_var] ++ state_vars(body_end_ctx, state_names))

    n = length(state_names)
    st1 = for _ <- state_names, do: fresh()
    st2 = for _ <- state_names, do: fresh()
    st3 = for _ <- state_names, do: fresh()
    t2a = fresh()
    t2b = fresh()

    caught =
      case_(tuple([c_v, r_v]), [
        clause(
          [tuple([lit(:throw), tuple([lit(:"$brk"), lit(id), tuple(st1)])])],
          tuple([lit(:brk)] ++ st1)
        ),
        clause(
          [tuple([lit(:throw), tuple([lit(:"$cnt"), lit(id), tuple([t2b | st2])])])],
          tuple([lit(:cnt), t2b] ++ st2)
        ),
        clause([fresh()], Slop.Cerl.reraise(c_v, r_v, st_v))
      ])

    loop_fname = fname(:"for$#{id}", n + 1)

    driver =
      case_(try_res, [
        clause([tuple([lit(:cont), t2a] ++ st3)], apply_(loop_fname, [t2a | st3])),
        clause([tuple([lit(:cnt), t2a] ++ st3)], apply_(loop_fname, [t2a | st3])),
        clause([tuple([lit(:brk)] ++ st3)], tuple([lit(:done), lit(true)] ++ st3))
      ])

    loop_fun =
      {loop_fname,
       fun(
         [l_var | param_vars],
         case_(l_var, [
           clause([nil_()], tuple([lit(:done), lit(false)] ++ param_vars)),
           clause(
             [cons(h_var, t_var)],
             let_(
               [try_res],
               try_(
                 seq(bind_expr, seq(body_expr, cont_tuple)),
                 [res_v],
                 res_v,
                 [c_v, r_v, st_v],
                 caught
               ),
               driver
             )
           )
         ])
       )}

    init_vals =
      Enum.map(state_names, fn name ->
        case ctx.env[name] do
          {:local, v, _} -> v
          _ -> lit(:"$unbound")
        end
      end)

    {iter_expr, ctx} = compile_expr(ctx, iter)
    res_var = fresh()
    aft = after_loop_body(ctx, res_var, state_names, orelse)

    cont = fn rest ->
      letrec([loop_fun],
        let_(
          [res_var],
          apply_(loop_fname, [call(:slop_rt, :iter, [iter_expr]) | init_vals]),
          aft.cont.(rest)
        )
      )
    end

    {{:wrap, cont}, aft.ctx}
  end

  # destructure {done, broke?, states...}; run else-suite when not broke
  defp after_loop_body(ctx, res_var, state_names, orelse) do
    n = length(state_names)
    broke_var = fresh()
    vars = for _ <- state_names, do: fresh()

    env_after =
      Enum.zip(state_names, vars)
      |> Enum.reduce(ctx.env, fn {name, v}, e ->
        Map.put(e, name, {:local, v, was_unbound?(ctx, name)})
      end)

    {else_expr, _} = compile_stmts(%{ctx | env: env_after}, orelse)

    inner =
      case_(broke_var, [
        clause([lit(false)], else_expr),
        clause([lit(true)], lit(nil))
      ])

    bindings = [{broke_var, call(:erlang, :element, [lit(2), res_var])}] ++
      (Enum.zip(vars, 3..(n + 2)//1)
       |> Enum.map(fn {v, i} -> {v, call(:erlang, :element, [lit(i), res_var])} end))

    cont = fn rest -> bind_lets(bindings, seq(inner, rest)) end
    %{cont: cont, ctx: %{ctx | env: env_after}}
  end

  defp was_unbound?(ctx, name), do: not match?({:local, _, _}, ctx.env[name])

  defp compile_stmt(ctx, {:def, _line, name, params, body, decos, _ann}) do
    if ctx.locals == nil do
      # module level: wrapper bound as a global
      {wrapper, ctx} = emit_def_wrapper(ctx, fname(String.to_atom(name), 3), params)
      {decorated, ctx} = apply_decorators(ctx, wrapper, decos)
      assign_name(ctx, name, decorated)
    else
      # local def: letrec-bound inline fun (captures environment)
      id = fresh_id()
      lfname = fname(String.to_atom("#{name}$#{id}"), 3)

      a_var = fresh()
      k_var = fresh()
      d_var = fresh()

      locals =
        params_names(params)
        |> MapSet.union(Scope.assigned(body))

      globals_decl = globals_declared(body)

      inner_env =
        ctx.env
        |> Map.drop(MapSet.to_list(locals))
        |> Map.put(name, {:rec, lfname, d_var})

      inner_ctx = %{
        ctx
        | env: inner_env,
          locals: locals,
          globals_decl: globals_decl,
          loop: nil,
          class: nil,
          is_method: false,
          self_name: nil,
          ret_id: fresh_id(),
          exc_info: nil
      }

      core_body = emit_param_bind(inner_ctx, a_var, k_var, d_var, params, body)

      lfun = {lfname, fun([a_var, k_var, d_var], wrap_ret(core_body, inner_ctx.ret_id))}

      a2 = fresh()
      k2 = fresh()

      defaults = Enum.filter(params.pos ++ params.kwonly, fn {_, d, _} -> d != nil end)

      {def_exprs, ctx} =
        Enum.map_reduce(defaults, ctx, fn {_, d, _}, c -> compile_expr(c, d) end)

      wrapper =
        letrec([lfun], fun([a2, k2], apply_(lfname, [a2, k2, tuple(def_exprs)])))

      {decorated, ctx} = apply_decorators(ctx, wrapper, decos)
      assign_name(ctx, name, decorated)
    end
  end

  defp compile_stmt(ctx, {:class, line, name, bases, body, decos}) do
    compile_class_stmt(ctx, line, name, bases, body, decos)
  end

  defp compile_stmt(ctx, {:import, _, mods}) do
    Enum.reduce(mods, {lit(nil), ctx}, fn {mod, asname}, {acc, c} ->
      mod_atom = String.to_atom(mod)
      name = asname || hd(String.split(mod, "."))
      ensure = call(:slop_rt, :module_ensure_init, [lit(mod_atom)])

      if c.locals == nil do
        c = %{c | mod_bindings: Map.put(c.mod_bindings, name, {:module, mod_atom})}

        e =
          seq(
            ensure,
            call(:slop_rt, :global_set, [
              lit(c.mod),
              lit(String.to_atom(name)),
              lit(mod_atom)
            ])
          )

        {seq(acc, e), c}
      else
        c = %{c | env: Map.put(c.env, name, {:module, mod_atom})}
        {seq(acc, ensure), c}
      end
    end)
  end

  defp compile_stmt(ctx, {:from, _, mod, names}) do
    mod_atom = String.to_atom(mod)

    resolved_names =
      case names do
        :star ->
          exports = Keyword.get(ctx.opts, :exports, %{})
          Enum.map(Map.get(exports, mod_atom, []), &{&1, nil})

        list ->
          list
      end

    ensure = call(:slop_rt, :module_ensure_init, [lit(mod_atom)])

    Enum.reduce(resolved_names, {ensure, ctx}, fn {n, asname}, {acc, c} ->
      alias_name = to_string(asname || n)
      n = to_string(n)

      get_expr = call(mod_atom, :"$__attr__", [lit(String.to_atom(n))])
      {bind_code, c} = assign_name(c, alias_name, get_expr)

      {seq(acc, bind_code), c}
    end)
  end

  defp compile_stmt(ctx, {:global, _, _}), do: {lit(nil), ctx}

  defp compile_stmt(ctx, {:raise, _, e, _from}) do
    case e do
      nil ->
        case ctx.exc_info do
          {c, r, st} ->
            {Slop.Cerl.reraise(c, r, st), ctx}

          nil ->
            {call(:slop_rt, :raise_exc, [
               lit(:RuntimeError),
               lit(<<"no active exception to re-raise">>)
             ]), ctx}
        end

      _ ->
        {eexpr, ctx} = compile_expr(ctx, e)
        {call(:slop_rt, :raise_any, [eexpr]), ctx}
    end
  end

  defp compile_stmt(ctx, {:assert, _, test, msg}) do
    {tc, ctx} = compile_expr(ctx, test)

    {msg_expr, ctx} =
      case msg do
        nil -> {lit(nil), ctx}
        _ -> compile_expr(ctx, msg)
      end

    {mv, ctx} = ensure_var(ctx, msg_expr)

    raise_e =
      call(:slop_rt, :raise_exc, [
        lit(:AssertionError),
        if_truthy(call(:slop_rt, :truthy, [mv]), mv, lit(<<"assertion failed">>))
      ])

    {if_truthy(tc, lit(nil), raise_e), ctx}
  end

  defp compile_stmt(ctx, {:try, _, body, handlers, orelse, fin}) do
    compile_try(ctx, body, handlers, orelse, fin)
  end

  defp compile_stmt(ctx, {:match, _, subj, cases}) do
    compile_match(ctx, subj, cases)
  end

  defp compile_stmt(ctx, {:with, _, items, body}) do
    compile_with(ctx, items, body)
  end

  defp compile_stmt(_ctx, {tag, line, _}) do
    raise CompileError, message: "unsupported statement #{tag}", line: line
  end

  # ---------- expression statements (with rebind rule) ----------

  defp compile_exprstmt(ctx, {:call, _, {:attr, _, {:name, _, root}, _attr}, _, _} = e) do
    {call_expr, ctx} = compile_expr(ctx, e)

    case root_binding(ctx, root) do
      :local ->
        assign_name(ctx, root, call_expr)

      :global ->
        {call(:slop_rt, :global_set, [lit(ctx.mod), lit(String.to_atom(root)), call_expr]), ctx}

      :none ->
        {call_expr, ctx}
    end
  end

  defp compile_exprstmt(ctx, e) do
    compile_expr(ctx, e)
  end

  defp root_binding(ctx, root) do
    case ctx.env[root] do
      {:local, _, _} ->
        :local

      {:module, _} ->
        :none

      _ ->
        cond do
          ctx.locals != nil and MapSet.member?(ctx.locals, root) and
              not MapSet.member?(ctx.globals_decl, root) ->
            :local

          match?({:module, _}, ctx.mod_bindings[root]) ->
            :none

          MapSet.member?(ctx.globals_decl, root) or Map.has_key?(ctx.mod_bindings, root) ->
            :global

          true ->
            :none
        end
    end
  end

  # ---------- assignment ----------

  defp compile_assign(ctx, {:name, _, n}, value), do: assign_name(ctx, n, value)
  defp compile_assign(ctx, {:tuple, _, ts}, value), do: unpack_assign(ctx, ts, value)
  defp compile_assign(ctx, {:list, _, ts}, value), do: unpack_assign(ctx, ts, value)

  defp compile_assign(ctx, {:attr, _, _, _} = target, value) do
    rebuild(ctx, target, value)
  end

  defp compile_assign(ctx, {:subscript, _, _, _} = target, value) do
    rebuild(ctx, target, value)
  end

  defp compile_assign(_ctx, {tag, line, _}, _value) do
    raise CompileError, message: "cannot assign to #{tag}", line: line
  end

  # write value into target; produces updated-root code and rebinds the root name
  defp rebuild(ctx, {:name, _, n}, value), do: assign_name(ctx, n, value)

  defp rebuild(ctx, {:attr, _, obj, attr}, value) do
    {obj_e, ctx} = compile_expr(ctx, obj)
    {obj_v, ctx} = ensure_var(ctx, obj_e)
    upd = call(:slop_rt, :setattr, [obj_v, lit(String.to_atom(attr)), value])
    {uv, ctx} = ensure_var(ctx, upd)
    rebuild(ctx, obj, uv)
  end

  defp rebuild(ctx, {:subscript, _, obj, idx}, value) do
    {obj_e, ctx} = compile_expr(ctx, obj)
    {obj_v, ctx} = ensure_var(ctx, obj_e)
    {idx_e, ctx} = compile_subscript_index(ctx, idx)
    {idx_v, ctx} = ensure_var(ctx, idx_e)
    upd = call(:slop_rt, :setitem, [obj_v, idx_v, value])
    {uv, ctx} = ensure_var(ctx, upd)
    rebuild(ctx, obj, uv)
  end

  defp rebuild(_ctx, {tag, line, _}, _value) do
    raise CompileError, message: "cannot assign to #{tag}", line: line
  end

  defp unpack_assign(ctx, ts, value) do
    {shape, leaves} = unpack_shape(ts)

    flat = call(:slop_rt, :unpack, [value, shape])
    leaf_vars = for _ <- leaves, do: fresh()

    body =
      Enum.reduce(Enum.zip(leaves, leaf_vars), {lit(nil), ctx}, fn {leaf, lv}, {acc, c} ->
        {e, c2} = compile_assign(c, leaf, lv)
        {seq(acc, e), c2}
      end)

    {case_(flat, [clause([list_pattern(leaf_vars)], elem(body, 0))]), elem(body, 1)}
  end

  # {shape_literal, [leaf_target_asts in order]}
  defp unpack_shape(ts) do
    {shapes, leaves} =
      Enum.map_reduce(ts, [], fn t, acc ->
        unpack_shape_one(t, acc)
      end)

    {lit(shapes), Enum.reverse(leaves)}
  end

  defp unpack_shape_one({:name, _, n}, acc), do: {:name, [{:name, 0, n} | acc]}

  defp unpack_shape_one({:starred, _, t}, acc) do
    {{:star}, [t | acc]}
  end

  defp unpack_shape_one({:tuple, _, ts}, acc), do: unpack_nested(ts, acc)
  defp unpack_shape_one({:list, _, ts}, acc), do: unpack_nested(ts, acc)

  defp unpack_shape_one(t, acc) do
    # attr/subscript leaf: treated as a simple leaf placeholder
    {:name, [t | acc]}
  end

  defp unpack_nested(ts, acc) do
    {shapes, leaves} =
      Enum.map_reduce(ts, [], fn t, a -> unpack_shape_one(t, a) end)

    {shapes, leaves ++ acc}
  end

  defp assign_name(ctx, name, value_expr) do
    cond do
      MapSet.member?(ctx.globals_decl, name) ->
        {v, ctx} = ensure_var(ctx, value_expr)

        {call(:slop_rt, :global_set, [lit(ctx.mod), lit(String.to_atom(name)), v]), ctx}

      ctx.locals == nil ->
        {v, ctx} = ensure_var(ctx, value_expr)

        {call(:slop_rt, :global_set, [lit(ctx.mod), lit(String.to_atom(name)), v]),
         %{ctx | mod_bindings: Map.put_new(ctx.mod_bindings, name, :value)}}

      true ->
        {v, ctx} = ensure_var(ctx, value_expr)
        {v, %{ctx | env: Map.put(ctx.env, name, {:local, v, false})}}
    end
  end

  defp state_vars(ctx, names) do
    Enum.map(names, fn n ->
      case ctx.env[n] do
        {:local, v, _} -> v
        _ -> lit(:"$unbound")
      end
    end)
  end

  defp merge_names(ctx, suites) do
    if ctx.locals == nil do
      []
    else
      Enum.reduce(suites, MapSet.new(), fn s, acc ->
        MapSet.union(acc, Scope.assigned(s))
      end)
      |> MapSet.intersection(ctx.locals)
      |> MapSet.difference(ctx.globals_decl)
      |> MapSet.to_list()
      |> Enum.sort()
    end
  end

  defp loop_state_names(ctx, body) do
    if ctx.locals == nil do
      []
    else
      Scope.assigned(body)
      |> MapSet.union(Scope.rebind_roots(body))
      |> MapSet.intersection(ctx.locals)
      |> MapSet.difference(ctx.globals_decl)
      |> MapSet.to_list()
      |> Enum.sort()
    end
  end

  defp branch_value(before_ctx, branch_ctx, name) do
    case branch_ctx.env[name] do
      {:local, v, _} ->
        v

      _ ->
        case before_ctx.env[name] do
          {:local, v, _} -> v
          _ -> lit(:"$unbound")
        end
    end
  end

  defp merge_after(before_ctx, result_expr, [], _branch_ctxs), do: {result_expr, before_ctx}

  defp merge_after(before_ctx, result_expr, names, branch_ctxs) do
    t = fresh()
    vars = for _ <- names, do: fresh()

    env =
      Enum.zip(names, vars)
      |> Enum.reduce(before_ctx.env, fn {n, v}, e ->
        unbound? =
          Enum.any?(branch_ctxs, fn bc ->
            not match?({:local, _, _}, bc.env[n]) and
              not match?({:local, _, _}, before_ctx.env[n])
          end)

        Map.put(e, n, {:local, v, unbound?})
      end)

    bindings =
      Enum.zip(vars, 1..length(vars)//1)
      |> Enum.map(fn {v, i} -> {v, call(:erlang, :element, [lit(i), t])} end)

    cont = fn rest -> let_([t], result_expr, bind_lets(bindings, rest)) end
    {{:wrap, cont}, %{before_ctx | env: env}}
  end

  # =====================================================================
  # try/except/finally
  # =====================================================================

  defp compile_try(ctx, body, handlers, orelse, fin) do
    all_suites = [body, orelse | Enum.map(handlers, fn {_, _, b} -> b end)]
    merge = merge_names(ctx, all_suites)

    {body_expr, body_ctx} = compile_stmts(ctx, body)

    body_tagged =
      seq(body_expr, tuple([lit(:body)] ++ Enum.map(merge, &branch_value(ctx, body_ctx, &1))))

    c_v = fresh()
    r_v = fresh()
    st_v = fresh()
    norm_t = fresh()
    nc_v = fresh()
    np_v = fresh()

    {handler_expr, handler_ctxs} =
      compile_except_chain(ctx, handlers, nc_v, np_v, c_v, st_v, r_v, merge, [])

    normalized =
      bind_lets(
        [
          {norm_t, call(:slop_rt, :normalize_exc, [c_v, r_v])},
          {nc_v, call(:erlang, :element, [lit(1), norm_t])},
          {np_v, call(:erlang, :element, [lit(2), norm_t])}
        ],
        handler_expr
      )

    res_v = fresh()

    inner = try_(body_tagged, [res_v], res_v, [c_v, r_v, st_v], normalized)

    tag_var = fresh()
    merge_vars = for _ <- merge, do: fresh()

    env_after =
      Enum.zip(merge, merge_vars)
      |> Enum.reduce(ctx.env, fn {name, v}, e ->
        unbound? =
          not match?({:local, _, _}, ctx.env[name]) and
            Enum.any?([body_ctx | handler_ctxs], fn bc ->
              not match?({:local, _, _}, bc.env[name])
            end)

        Map.put(e, name, {:local, v, unbound?})
      end)

    {else_expr, _} = compile_stmts(%{ctx | env: env_after}, orelse)

    after_expr =
      case_(tag_var, [
        clause([lit(:body)], else_expr),
        clause([lit(:handler)], lit(nil))
      ])

    t = fresh()

    # the whole try + tag destructuring goes in an immediately-applied fun:
    # works around an OTP 24 beam_validator "ambiguous_catch_try_state" bug
    # (a try whose handler rethrows, destructured inside another try's body)
    base_cont = fn rest ->
      apply_(
        fun(
          [],
          let_([t], inner,
            bind_lets(
              [{tag_var, call(:erlang, :element, [lit(1), t])}] ++
                (Enum.zip(merge_vars, 2..(length(merge) + 1)//1)
                 |> Enum.map(fn {v, i} -> {v, call(:erlang, :element, [lit(i), t])} end)),
              seq(after_expr, rest)
            )
          )
        ),
        []
      )
    end

    full_cont =
      case fin do
        [] ->
          base_cont

        _ ->
          {fin_expr, _fin_ctx} = compile_stmts(%{ctx | env: env_after}, fin)

          c2 = fresh()
          r2 = fresh()
          st2 = fresh()
          res2 = fresh()

          fn rest ->
            try_(
              base_cont.(seq(fin_expr, rest)),
              [res2],
              res2,
              [c2, r2, st2],
              seq(fin_expr, Slop.Cerl.reraise(c2, r2, st2))
            )
          end
      end

    {{:wrap, full_cont}, %{ctx | env: env_after}}
  end

  defp compile_except_chain(ctx, [], _nc_v, _np_v, c_v, st_v, r_v, _merge, acc) do
    {Slop.Cerl.reraise(c_v, r_v, st_v), Enum.reverse(acc)}
  end

  defp compile_except_chain(ctx, [{type_ast, name, hbody} | rest], nc_v, np_v, c_v, st_v, r_v, merge, acc) do
    {classes_expr, ctx} = compile_except_types(ctx, type_ast)

    handler_ctx =
      %{ctx | exc_info: {c_v, r_v, st_v}}

    handler_ctx =
      case name do
        nil -> handler_ctx
        _ -> %{handler_ctx | env: Map.put(handler_ctx.env, name, {:local, np_v, false})}
      end

    {hbody_expr, hctx} = compile_stmts(handler_ctx, hbody)

    tagged =
      seq(hbody_expr, tuple([lit(:handler)] ++ Enum.map(merge, &branch_value(ctx, hctx, &1))))

    {next_expr, ctxs} = compile_except_chain(ctx, rest, nc_v, np_v, c_v, st_v, r_v, merge, [hctx | acc])

    expr =
      case_(call(:slop_rt, :exc_matches, [nc_v, classes_expr]), [
        clause([lit(true)], tagged),
        clause([lit(false)], next_expr)
      ])

    {expr, ctxs}
  end

  defp compile_except_types(ctx, nil), do: {lit([:BaseException]), ctx}

  defp compile_except_types(ctx, {:tuple, _, elems}) do
    {exprs, ctx} = Enum.map_reduce(elems, ctx, fn e, c -> compile_expr(c, e) end)
    {list_lit(exprs), ctx}
  end

  defp compile_except_types(ctx, e) do
    {expr, ctx} = compile_expr(ctx, e)
    {list_lit([expr]), ctx}
  end

  # =====================================================================
  # with statement
  # =====================================================================

  defp compile_with(ctx, items, body) do
    {preps, ctx} =
      Enum.map_reduce(items, ctx, fn {ctx_expr, name}, c ->
        {ee, c} = compile_expr(c, ctx_expr)
        mgr = fresh()
        entered_v = fresh()
        entered = call(:slop_rt, :with_enter, [mgr])

        {bind_code, c} =
          case name do
            nil ->
              {let_([entered_v], entered, lit(nil)), c}

            _ ->
              {bc, c} = assign_name(c, name, entered_v)
              {let_([entered_v], entered, bc), c}
          end

        {{mgr, ee, bind_code}, c}
      end)

    wrap_with_items(ctx, preps, body)
  end

  defp wrap_with_items(ctx, [], body), do: compile_stmts(ctx, body)

  defp wrap_with_items(ctx, [{mgr, ee, bind_code} | rest], body) do
    c_v = fresh()
    r_v = fresh()
    st_v = fresh()
    res_v = fresh()
    norm_t = fresh()

    {inner_expr, inner_ctx} = wrap_with_items(ctx, rest, body)

    exit_ok = call(:slop_rt, :with_exit, [mgr, lit(nil)])

    inner =
      try_(
        inner_expr,
        [res_v],
        seq(exit_ok, res_v),
        [c_v, r_v, st_v],
        bind_lets(
          [{norm_t, call(:slop_rt, :normalize_exc, [c_v, r_v])}],
          if_truthy(
            call(:slop_rt, :with_exit, [mgr, call(:erlang, :element, [lit(2), norm_t])]),
            lit(nil),
            Slop.Cerl.reraise(c_v, r_v, st_v)
          )
        )
      )

    {let_([mgr], ee, seq(bind_code, inner)), inner_ctx}
  end

  # =====================================================================
  # match statement
  # =====================================================================

  defp compile_match(ctx, subj, cases) do
    {subj_e, ctx} = compile_expr(ctx, subj)
    sv = fresh()

    all_suites = Enum.map(cases, fn {_, _, b, _} -> b end)
    merge = merge_names(ctx, all_suites)

    {chain_expr, arm_ctxs} = compile_match_chain(ctx, cases, sv, merge, [])
    chain_expr = let_([sv], subj_e, chain_expr)

    case merge do
      [] ->
        {chain_expr, ctx}

      _ ->
        t = fresh()
        vars = for _ <- merge, do: fresh()

        env_after =
          Enum.zip(merge, vars)
          |> Enum.reduce(ctx.env, fn {name, v}, e ->
            unbound? =
              not match?({:local, _, _}, ctx.env[name]) or
                Enum.any?(arm_ctxs, fn ac -> not match?({:local, _, _}, ac.env[name]) end)

            Map.put(e, name, {:local, v, unbound?})
          end)

        bindings =
          Enum.zip(vars, 1..length(vars)//1)
          |> Enum.map(fn {v, i} -> {v, call(:erlang, :element, [lit(i), t])} end)

        cont = fn rest -> let_([t], chain_expr, bind_lets(bindings, rest)) end
        {{:wrap, cont}, %{ctx | env: env_after}}
    end
  end

  defp compile_match_chain(ctx, [], _s, merge, acc) do
    fallthrough =
      case merge do
        [] -> lit(nil)
        _ -> tuple(Enum.map(merge, fn n -> branch_value(ctx, ctx, n) end))
      end

    {fallthrough, Enum.reverse(acc)}
  end

  defp compile_match_chain(ctx, [{pat, guard, body, _line} | rest], s, merge, acc) do
    {spec_expr, leaf_count, ctx} = pattern_spec(ctx, pat)

    leaf_vars = for _ <- 1..max(leaf_count, 0), do: fresh()
    leaf_vars = if leaf_count == 0, do: [], else: leaf_vars

    ok_pattern = tuple([lit(:ok), list_pattern(leaf_vars)])

    arm_env = leaf_bindings_env(ctx, pat, leaf_vars)

    {guard_expr, _} =
      case guard do
        nil -> {lit(true), ctx}
        _ -> compile_expr(%{ctx | env: arm_env}, guard)
      end

    {body_expr, body_ctx} = compile_stmts(%{ctx | env: arm_env}, body)

    tagged =
      case merge do
        [] -> seq(body_expr, lit(nil))
        _ -> seq(body_expr, tuple(Enum.map(merge, &branch_value(ctx, body_ctx, &1))))
      end

    {next_expr, ctxs} = compile_match_chain(ctx, rest, s, merge, [body_ctx | acc])

    arm = if_truthy(guard_expr, tagged, next_expr)

    expr =
      case_(call(:slop_rt, :pattern_match, [spec_expr, s]), [
        clause([ok_pattern], arm),
        clause([fresh()], next_expr)
      ])

    {expr, ctxs}
  end

  defp leaf_bindings_env(ctx, pat, leaf_vars) do
    names = pattern_leaf_names(pat)

    Enum.zip(names, leaf_vars)
    |> Enum.reduce(ctx.env, fn {n, v}, e -> Map.put(e, n, {:local, v, false}) end)
  end

  defp pattern_leaf_names(pat) do
    ordered_leaf_names(pat, []) |> Enum.reverse()
  end

  defp ordered_leaf_names({:p_capture, _, n}, acc), do: [n | acc]
  defp ordered_leaf_names({:p_wild, _}, acc), do: acc
  defp ordered_leaf_names({:p_lit, _, _}, acc), do: acc
  defp ordered_leaf_names({:p_value, _, _}, acc), do: acc

  defp ordered_leaf_names({:p_seq, _, elems, _}, acc),
    do: Enum.reduce(elems, acc, &ordered_leaf_names/2)

  defp ordered_leaf_names({:p_tuple, _, elems, _}, acc),
    do: Enum.reduce(elems, acc, &ordered_leaf_names/2)

  defp ordered_leaf_names({:p_map, _, pairs, rest}, acc) do
    acc = Enum.reduce(pairs, acc, fn {_k, p}, a -> ordered_leaf_names(p, a) end)
    if rest, do: [rest | acc], else: acc
  end

  defp ordered_leaf_names({:p_class, _, _, kwps}, acc),
    do: Enum.reduce(kwps, acc, fn {_k, p}, a -> ordered_leaf_names(p, a) end)

  defp ordered_leaf_names({:p_or, _, [p | _]}, acc), do: ordered_leaf_names(p, acc)
  defp ordered_leaf_names({:p_as, _, p, n}, acc), do: [n | ordered_leaf_names(p, acc)]

  # build runtime spec expression; returns {expr, leaf_count, ctx}
  defp pattern_spec(ctx, {:p_lit, _, v}), do: {lit({:lit, v}), 0, ctx}
  defp pattern_spec(ctx, {:p_capture, _, _}), do: {lit({:capture}), 1, ctx}
  defp pattern_spec(ctx, {:p_wild, _}), do: {lit({:wild}), 0, ctx}

  defp pattern_spec(ctx, {:p_value, _, e}) do
    {ee, ctx} = compile_expr(ctx, e)
    {tuple([lit(:value), ee]), 0, ctx}
  end

  defp pattern_spec(ctx, {:p_seq, _, elems, star_idx}) do
    {specs, counts, ctx} = pattern_specs(ctx, elems)
    {tuple([lit(:seq), list_lit(specs), lit(star_idx), lit(:list)]), Enum.sum(counts), ctx}
  end

  defp pattern_spec(ctx, {:p_tuple, _, elems, star_idx}) do
    {specs, counts, ctx} = pattern_specs(ctx, elems)
    {tuple([lit(:seq), list_lit(specs), lit(star_idx), lit(:tuple)]), Enum.sum(counts), ctx}
  end

  defp pattern_spec(ctx, {:p_map, _, pairs, rest}) do
    {pair_exprs, total, ctx} =
      Enum.reduce(pairs, {[], 0, ctx}, fn {k, p}, {exprs, cnt, c} ->
        {ke, c} =
          case k do
            {:p_lit, _, v} ->
              {lit({:key, v}), c}

            {:p_value, _, e} ->
              {ee, c} = compile_expr(c, e)
              {tuple([lit(:value), ee]), c}
          end

        {se, scnt, c} = pattern_spec(c, p)
        {exprs ++ [tuple([ke, se])], cnt + scnt, c}
      end)

    has_rest = if rest, do: 1, else: 0
    {tuple([lit(:map), list_lit(pair_exprs), lit(rest != nil)]), total + has_rest, ctx}
  end

  defp pattern_spec(ctx, {:p_class, _, class_e, kwps}) do
    {ce, ctx} = compile_expr(ctx, class_e)

    {pair_exprs, total, ctx} =
      Enum.reduce(kwps, {[], 0, ctx}, fn {k, p}, {exprs, cnt, c} ->
        {se, scnt, c} = pattern_spec(c, p)
        {exprs ++ [tuple([lit(String.to_atom(k)), se])], cnt + scnt, c}
      end)

    {tuple([lit(:class), ce, list_lit(pair_exprs)]), total, ctx}
  end

  defp pattern_spec(ctx, {:p_or, _, ps}) do
    {specs, counts, ctx} = pattern_specs(ctx, ps)
    {tuple([lit(:or), list_lit(specs)]), Enum.at(counts, 0), ctx}
  end

  defp pattern_spec(ctx, {:p_as, _, p, _n}) do
    {se, cnt, ctx} = pattern_spec(ctx, p)
    {tuple([lit(:as), se]), cnt + 1, ctx}
  end

  defp pattern_specs(ctx, pats) do
    Enum.reduce(pats, {[], [], ctx}, fn p, {specs, counts, c} ->
      {se, cnt, c} = pattern_spec(c, p)
      {specs ++ [se], counts ++ [cnt], c}
    end)
  end

  # =====================================================================
  # class statement
  # =====================================================================

  defp compile_class_stmt(ctx, _line, name, bases, body, decos) do
    fq =
      case ctx.class do
        nil -> "#{ctx.modname}.#{name}"
        parent -> "#{parent}.#{name}"
      end

    fq_atom = String.to_atom(fq)

    {bases_list, ctx} =
      Enum.map_reduce(bases, ctx, fn
        {:kw, _, _}, c -> {nil, c}
        b, c ->
          {e, c2} = compile_expr(c, b)
          {e, c2}
      end)
      |> then(fn {exprs, c} -> {list_lit(Enum.reject(exprs, &is_nil/1)), c} end)

    {methods_map, attrs_map, body_expr, ctx} =
      compile_class_body(ctx, fq_atom, body)

    defclass =
      call(:slop_rt, :defclass, [lit(fq_atom), bases_list, methods_map, attrs_map])

    cv = fresh()
    {decorated, ctx} = apply_decorators(ctx, cv, decos)
    {bind_code, ctx} = assign_name(ctx, name, decorated)

    {let_([cv], seq(body_expr, defclass), bind_code), ctx}
  end

  defp compile_class_body(ctx, fq_atom, body) do
    locals = Scope.assigned(body)

    class_ctx = %{
      ctx
      | env: %{},
        locals: locals,
        globals_decl: MapSet.new(),
        class: fq_atom,
        loop: nil,
        exc_info: nil
    }

    # methods: compile defs, collect entries
    {class_ctx, method_entries} =
      Enum.reduce(body, {class_ctx, []}, fn
        {:def, _, mname, params, mbody, mdecos, _ann}, {c, acc} ->
          static? = Enum.any?(mdecos, &match?({:name, _, "staticmethod"}, &1))
          classmethod? = Enum.any?(mdecos, &match?({:name, _, "classmethod"}, &1))

          plain_decos =
            Enum.reject(mdecos, fn d ->
              match?({:name, _, "staticmethod"}, d) or match?({:name, _, "classmethod"}, d)
            end)

          {c2, defn} = compile_fundef(c, mname, params, mbody, {fq_atom, static?})
          c = %{c2 | defs: c2.defs ++ [defn]}

          beam_name = String.to_atom("#{fq_atom}.#{mname}")
          {wrapper, c} = emit_def_wrapper(c, fname(beam_name, 3), params)
          {decorated, c} = apply_decorators(c, wrapper, plain_decos)

          entry =
            cond do
              static? -> tuple([lit(:"$static"), decorated])
              classmethod? -> tuple([lit(:"$classmeth"), decorated])
              true -> decorated
            end

          {c, acc ++ [{String.to_atom(mname), entry}]}

        _, acc ->
          acc
      end)

    other_stmts = Enum.reject(body, &match?({:def, _, _, _, _, _, _}, &1))
    {body_expr, end_ctx} = compile_stmts(class_ctx, other_stmts)

    attr_pairs =
      end_ctx.env
      |> Enum.filter(fn {_n, b} -> match?({:local, _, _}, b) end)
      |> Enum.map(fn {n, {:local, v, _}} -> {String.to_atom(n), v} end)

    attrs_map =
      :cerl.ann_c_map(
        [],
        lit(%{}),
        Enum.map(attr_pairs, fn {k, v} -> :cerl.c_map_pair(lit(k), v) end)
      )

    methods_map =
      :cerl.ann_c_map(
        [],
        lit(%{}),
        Enum.map(method_entries, fn {k, v} -> :cerl.c_map_pair(lit(k), v) end)
      )

    ctx_out = %{
      end_ctx
      | env: ctx.env,
        class: ctx.class,
        locals: ctx.locals,
        globals_decl: ctx.globals_decl,
        is_method: ctx.is_method,
        self_name: ctx.self_name
    }
    {methods_map, attrs_map, body_expr, ctx_out}
  end

  defp apply_decorators(ctx, value_expr, []), do: {value_expr, ctx}

  defp apply_decorators(ctx, value_expr, decos) do
    Enum.reduce(Enum.reverse(decos), {value_expr, ctx}, fn deco, {ve, c} ->
      {de, c} = compile_expr(c, deco)
      {v, c} = ensure_var(c, ve)
      {call(:slop_rt, :invoke, [de, list_lit([v]), map_lit([])]), c}
    end)
  end

  # =====================================================================
  # expressions
  # =====================================================================

  defp compile_expr(ctx, {:lit, _, v}), do: {lit(v), ctx}
  defp compile_expr(ctx, {:name, _, n}), do: read_name(ctx, n)

  defp compile_expr(ctx, {:list, _, elems}), do: compile_list(ctx, elems)
  defp compile_expr(ctx, {:tuple, _, elems}), do: compile_tuple(ctx, elems)

  defp compile_expr(ctx, {:set, _, elems}) do
    {exprs, ctx} = compile_exprs(ctx, elems)

    m =
      :cerl.ann_c_map([], lit(%{}), Enum.map(exprs, fn e -> :cerl.c_map_pair(e, lit(true)) end))

    {tuple([lit(:"$set"), m]), ctx}
  end

  defp compile_expr(ctx, {:dict, _, pairs}) do
    Enum.reduce(pairs, {map_lit([]), ctx}, fn
      {:pair, k, v}, {me, c} ->
        {ke, c} = compile_expr(c, k)
        {ve, c} = compile_expr(c, v)
        {:cerl.ann_c_map([], me, [:cerl.c_map_pair(ke, ve)]), c}

      {:kwstar, _, e}, {me, c} ->
        {ee, c} = compile_expr(c, e)
        {call(:maps, :merge, [me, ee]), c}
    end)
  end

  defp compile_expr(ctx, {:binop, _, op, l, r}) do
    {le, ctx} = compile_expr(ctx, l)
    {re, ctx} = compile_expr(ctx, r)
    {call(:slop_rt, :binop, [lit(op), le, re]), ctx}
  end

  defp compile_expr(ctx, {:boolop, _, "and", l, r}) do
    {le, ctx} = compile_expr(ctx, l)
    {re, ctx} = compile_expr(ctx, r)
    lv = fresh()
    {let_([lv], le, if_truthy(lv, re, lv)), ctx}
  end

  defp compile_expr(ctx, {:boolop, _, "or", l, r}) do
    {le, ctx} = compile_expr(ctx, l)
    {re, ctx} = compile_expr(ctx, r)
    lv = fresh()
    {let_([lv], le, if_truthy(lv, lv, re)), ctx}
  end

  defp compile_expr(ctx, {:unary, _, "not", e}) do
    {ee, ctx} = compile_expr(ctx, e)
    {if_truthy(ee, lit(false), lit(true)), ctx}
  end

  defp compile_expr(ctx, {:unary, _, op, e}) do
    {ee, ctx} = compile_expr(ctx, e)
    {call(:slop_rt, :unary, [lit(op), ee]), ctx}
  end

  defp compile_expr(ctx, {:compare, _, ops}) do
    compile_comparisons(ctx, ops)
  end

  defp compile_expr(ctx, {:ifexp, _, c, t, e}) do
    {ce, ctx} = compile_expr(ctx, c)
    {te, ctx} = compile_expr(ctx, t)
    {ee, ctx} = compile_expr(ctx, e)
    {if_truthy(ce, te, ee), ctx}
  end

  defp compile_expr(ctx, {:call, line, {:name, _, "super"}, _args, _kwargs}) do
    case {ctx.class, ctx.self_name} do
      {nil, _} ->
        raise CompileError, message: "super() used outside a class", line: line

      {_, nil} ->
        raise CompileError, message: "super() used in a method without self", line: line

      {class, self_name} ->
        case ctx.env[self_name] do
          {:local, sv, _} ->
            {call(:slop_rt, :super_proxy, [lit(class), sv]), ctx}

          _ ->
            raise CompileError, message: "super(): self is not bound", line: line
        end
    end
  end

  defp compile_expr(ctx, {:call, _, f, args, kwargs}) do
    {pos_expr, ctx} = compile_pos_args(ctx, args)
    {kw_expr, ctx} = compile_kw_args(ctx, kwargs)

    case f do
      {:attr, _, obj, attr} ->
        {oe, ctx} = compile_expr(ctx, obj)
        {call(:slop_rt, :call_method, [oe, lit(String.to_atom(attr)), pos_expr, kw_expr]), ctx}

      {:name, _, n} ->
        case ctx.env[n] do
          nil ->
            case Slop.Builtins.lookup(n) do
              {:ok, m, fnm} ->
                {call(m, fnm, [pos_expr, kw_expr]), ctx}

              :error ->
                {fe, ctx} = read_name(ctx, n)
                {call(:slop_rt, :invoke, [fe, pos_expr, kw_expr]), ctx}
            end

          {:rec, lfname, d_var} ->
            {apply_(lfname, [pos_expr, kw_expr, d_var]), ctx}

          _ ->
            {fe, ctx} = read_name(ctx, n)
            {call(:slop_rt, :invoke, [fe, pos_expr, kw_expr]), ctx}
        end

      _ ->
        {fe, ctx} = compile_expr(ctx, f)
        {call(:slop_rt, :invoke, [fe, pos_expr, kw_expr]), ctx}
    end
  end

  defp compile_expr(ctx, {:attr, _, obj, attr}) do
    case module_of(ctx, obj) do
      {:ok, mod_atom} ->
        {call(mod_atom, :"$__attr__", [lit(String.to_atom(attr))]), ctx}

      :no ->
        {oe, ctx} = compile_expr(ctx, obj)
        {call(:slop_rt, :getattr, [oe, lit(String.to_atom(attr))]), ctx}
    end
  end

  defp compile_expr(ctx, {:subscript, _, obj, idx}) do
    {oe, ctx} = compile_expr(ctx, obj)
    {ie, ctx} = compile_subscript_index(ctx, idx)
    {call(:slop_rt, :getitem, [oe, ie]), ctx}
  end

  defp compile_expr(ctx, {:lambda, _, params, body}) do
    compile_lambda(ctx, params, body)
  end

  defp compile_expr(ctx, {tag, _, _, _} = e)
       when tag in [:listcomp, :setcomp, :genexp] do
    compile_comprehension(ctx, e)
  end

  defp compile_expr(ctx, {:dictcomp, _, _, _, _} = e) do
    compile_comprehension(ctx, e)
  end

  defp compile_expr(ctx, {:fstring, _, parts}) do
    compile_fstring(ctx, parts)
  end

  defp compile_expr(ctx, {:namedexpr, _, n, v}) do
    {ve, ctx} = compile_expr(ctx, v)
    {vv, ctx} = ensure_var(ctx, ve)
    {assign_code, ctx} = assign_name(ctx, n, vv)
    {seq(assign_code, vv), ctx}
  end

  defp compile_expr(_ctx, {tag, line, _}) do
    raise CompileError, message: "unsupported expression #{tag}", line: line
  end

  defp compile_exprs(ctx, exprs) do
    Enum.map_reduce(exprs, ctx, fn e, c -> compile_expr(c, e) end)
  end

  defp compile_list(ctx, elems) do
    if Enum.any?(elems, &match?({:starred, _, _}, &1)) do
      {seg_exprs, ctx} =
        Enum.map_reduce(elems, ctx, fn
          {:starred, _, e}, c ->
            {ee, c} = compile_expr(c, e)
            {call(:slop_rt, :iter, [ee]), c}

          e, c ->
            {ee, c} = compile_expr(c, e)
            {list_lit([ee]), c}
        end)

      {Enum.reduce(seg_exprs, fn s, acc -> call(:erlang, :++, [acc, s]) end), ctx}
    else
      {exprs, ctx} = compile_exprs(ctx, elems)
      {list_lit(exprs), ctx}
    end
  end

  defp compile_tuple(ctx, elems) do
    if Enum.any?(elems, &match?({:starred, _, _}, &1)) do
      {le, ctx} = compile_list(ctx, elems)
      {call(:erlang, :list_to_tuple, [le]), ctx}
    else
      {exprs, ctx} = compile_exprs(ctx, elems)
      {tuple(exprs), ctx}
    end
  end

  # chained comparisons with shared middle operands
  defp compile_comparisons(ctx, [{op, l, r}]) do
    compile_comparison(ctx, op, l, r)
  end

  defp compile_comparisons(ctx, [{op0, l0, r0} | rest]) do
    {l0e, ctx} = compile_expr(ctx, l0)
    {re_exprs, ctx} = Enum.map_reduce([r0 | Enum.map(rest, fn {_op, _l, r} -> r end)], ctx, fn r, c -> compile_expr(c, r) end)
    ops = [op0 | Enum.map(rest, fn {op, _l, _r} -> op end)]

    vrs = for _ <- re_exprs, do: fresh()

    # innermost: let v_{n-1} = re_{n-1} in cmp(op_last, v_{n-2}, v_{n-1})
    n = length(ops)
    last_v = Enum.at(vrs, n - 1)
    last_re = Enum.at(re_exprs, n - 1)
    last_cmp =
      let_([last_v], last_re, cmp_call(Enum.at(ops, n - 1), Enum.at(vrs, n - 2), last_v))

    # fold right-to-left from the last operand down to the first
    {expr, _} =
      Enum.reduce((n - 1)..1//-1, {last_cmp, n}, fn i, {inner, _} ->
        v = Enum.at(vrs, i - 1)
        re = Enum.at(re_exprs, i - 1)
        prev = if i == 1, do: l0e, else: Enum.at(vrs, i - 2)
        cmp = cmp_call(Enum.at(ops, i - 1), prev, v)
        {let_([v], re, if_truthy(cmp, inner, lit(false))), nil}
      end)

    {expr, ctx}
  end

  defp compile_comparison(ctx, op, l, r) do
    {le, ctx} = compile_expr(ctx, l)
    {re, ctx} = compile_expr(ctx, r)
    {cmp_call(op, le, re), ctx}
  end

  defp cmp_call("is", le, re), do: call(:erlang, :"=:=", [le, re])
  defp cmp_call("is not", le, re), do: call(:erlang, :"=/=", [le, re])
  defp cmp_call("in", le, re), do: call(:slop_rt, :contains, [re, le])

  defp cmp_call("not in", le, re),
    do: if_truthy(call(:slop_rt, :contains, [re, le]), lit(false), lit(true))

  defp cmp_call(op, le, re), do: call(:slop_rt, :cmp, [lit(op), le, re])

  defp module_of(ctx, {:name, _, n}) do
    case ctx.env[n] do
      {:module, a} ->
        {:ok, a}

      _ ->
        case ctx.mod_bindings[n] do
          {:module, a} -> {:ok, a}
          _ -> :no
        end
    end
  end

  defp module_of(_, _), do: :no

  defp compile_subscript_index(ctx, {:slice, _, lo, hi, step}) do
    {lo_e, ctx} = if lo, do: compile_expr(ctx, lo), else: {lit(nil), ctx}
    {hi_e, ctx} = if hi, do: compile_expr(ctx, hi), else: {lit(nil), ctx}
    {st_e, ctx} = if step, do: compile_expr(ctx, step), else: {lit(nil), ctx}
    {tuple([lit(:"$slice"), lo_e, hi_e, st_e]), ctx}
  end

  defp compile_subscript_index(ctx, idx), do: compile_expr(ctx, idx)

  defp compile_pos_args(ctx, args) do
    if Enum.any?(args, &match?({:star, _, _}, &1)) do
      {segs, ctx} =
        Enum.map_reduce(args, ctx, fn
          {:star, _, e}, c ->
            {ee, c} = compile_expr(c, e)
            {call(:slop_rt, :iter, [ee]), c}

          e, c ->
            {ee, c} = compile_expr(c, e)
            {list_lit([ee]), c}
        end)

      {Enum.reduce(segs, fn s, acc -> call(:erlang, :++, [acc, s]) end), ctx}
    else
      {exprs, ctx} = compile_exprs(ctx, args)
      {list_lit(exprs), ctx}
    end
  end

  defp compile_kw_args(ctx, kwargs) do
    Enum.reduce(kwargs, {map_lit([]), ctx}, fn
      {:kw, n, e}, {me, c} ->
        {ee, c} = compile_expr(c, e)
        {:cerl.ann_c_map([], me, [:cerl.c_map_pair(lit(String.to_atom(n)), ee)]), c}

      {:kwstar, _, e}, {me, c} ->
        {ee, c} = compile_expr(c, e)
        {call(:maps, :merge, [me, ee]), c}
    end)
  end

  # ---------- lambdas ----------

  defp compile_lambda(ctx, params, body) do
    ret_id = fresh_id()

    a_var = fresh()
    k_var = fresh()
    d_var = fresh()

    locals = MapSet.union(params_names(params), Scope.expr_names(body))

    inner_ctx = %{
      ctx
      | env: Map.drop(ctx.env, MapSet.to_list(locals)),
        locals: locals,
        globals_decl: MapSet.new(),
        loop: nil,
        class: nil,
        is_method: false,
        self_name: nil,
        ret_id: ret_id,
        exc_info: nil
    }

    spec = params_spec(params)

    all_named = params.pos ++ params.kwonly
    val_vars = for _ <- all_named, do: fresh()
    va_var = fresh()
    kr_var = fresh()

    bind_call = call(:slop_rt, :bind_params, [spec, d_var, a_var, k_var])

    env_ctx = bind_params_env(inner_ctx, params, val_vars, va_var, kr_var)
    {body_expr, _} = compile_expr(env_ctx, body)

    core =
      if length(all_named) == 0 and is_nil(params.vararg) and is_nil(params.kwarg) do
        seq(bind_call, body_expr)
      else
        case_(bind_call, [
          clause([tuple([list_pattern(val_vars), va_var, kr_var])], body_expr)
        ])
      end

    # lambdas capture their defining environment via v3_core closure conversion
    inner_fun = fun([a_var, k_var, d_var], core)

    defaults = Enum.filter(params.pos ++ params.kwonly, fn {_, d, _} -> d != nil end)

    if defaults == [] do
      lf = fresh()
      a2 = fresh()
      k2 = fresh()

      wrapper =
        let_([lf], inner_fun,
          fun([a2, k2], apply_(lf, [a2, k2, tuple([])]))
        )

      {wrapper, ctx}
    else
      {def_exprs, ctx} =
        Enum.map_reduce(defaults, ctx, fn {_, d, _}, c -> compile_expr(c, d) end)

      lf = fresh()
      a2 = fresh()
      k2 = fresh()

      wrapper =
        let_([lf], inner_fun,
          fun([a2, k2], apply_(lf, [a2, k2, tuple(def_exprs)]))
        )

      {wrapper, ctx}
    end
  end

  # ---------- comprehensions ----------

  defp compile_comprehension(ctx, {tag, _, elem_expr, clauses})
       when tag in [:listcomp, :setcomp, :genexp] do
    saved_env = ctx.env

    emit = fn c, acc ->
      {ee, c2} = compile_expr(c, elem_expr)

      case tag do
        :setcomp ->
          {:cerl.ann_c_map([], acc, [:cerl.c_map_pair(ee, lit(true))]), c2}

        _ ->
          {cons(ee, acc), c2}
      end
    end

    init_acc = if tag == :setcomp, do: map_lit([]), else: nil_()

    result_expr = comp_build(ctx, clauses, init_acc, emit)

    result =
      case tag do
        :setcomp -> tuple([lit(:"$set"), result_expr])
        _ -> call(:lists, :reverse, [result_expr])
      end

    {result, %{ctx | env: saved_env}}
  end

  defp compile_comprehension(ctx, {:dictcomp, _, k_expr, v_expr, clauses}) do
    saved_env = ctx.env

    emit = fn c, acc ->
      {ke, c} = compile_expr(c, k_expr)
      {ve, c} = compile_expr(c, v_expr)
      {:cerl.ann_c_map([], acc, [:cerl.c_map_pair(ke, ve)]), c}
    end

    result_expr = comp_build(ctx, clauses, map_lit([]), emit)

    {result_expr, %{ctx | env: saved_env}}
  end

  # builds the nested loop expression producing the final accumulator
  # acc_var is always a cerl variable holding the current accumulator
  defp comp_build(ctx, [], acc_var, emit) do
    {e, _} = emit.(ctx, acc_var)
    e
  end

  defp comp_build(ctx, [{:for, target, iter} | rest], acc_var, emit) do
    id = fresh_id()

    l_var = fresh()
    h_var = fresh()
    t_var = fresh()
    acc2 = fresh()

    {bind_expr, bind_ctx} = compile_assign(%{ctx | loop: nil}, target, h_var)

    inner = comp_build(bind_ctx, rest, acc2, emit)

    {iter_e, _} = compile_expr(ctx, iter)

    loop_fname = fname(:"comp$#{id}", 2)

    loop_fun =
      {loop_fname,
       fun([l_var, acc2],
         case_(l_var, [
           clause([nil_()], acc2),
           clause([cons(h_var, t_var)], seq(bind_expr, apply_(loop_fname, [t_var, inner])))
         ])
       )}

    letrec([loop_fun], apply_(loop_fname, [call(:slop_rt, :iter, [iter_e]), acc_var]))
  end

  defp comp_build(ctx, [{:if, cond_e} | rest], acc_var, emit) do
    {ce, _} = compile_expr(ctx, cond_e)
    inner = comp_build(ctx, rest, acc_var, emit)
    if_truthy(ce, inner, acc_var)
  end

  # ---------- f-strings ----------

  defp compile_fstring(ctx, parts) do
    {seg_exprs, ctx} =
      Enum.map_reduce(parts, ctx, fn
        {:str, s}, c ->
          {lit(s), c}

        {:expr, e, conv, spec}, c ->
          {ee, c} = compile_expr(c, e)
          {ev, c} = ensure_var(c, ee)

          se =
            case spec do
              nil ->
                case conv do
                  nil -> call(:slop_rt, :to_str, [ev])
                  "s" -> call(:slop_rt, :to_str, [ev])
                  "r" -> call(:slop_rt, :to_repr, [ev])
                  "a" -> call(:slop_rt, :to_repr, [ev])
                end

              spec_parts ->
                {spec_e, c} = compile_fstring_spec(c, spec_parts)
                {sv, c} = ensure_var(c, spec_e)

                _ = c
                call(:slop_rt, :format_spec, [ev, sv])
            end

          {se, c}
      end)

    combined =
      Enum.reduce(seg_exprs, lit(<<>>), fn s, acc ->
        call(:slop_rt, :binop, [lit("+"), acc, s])
      end)

    {combined, ctx}
  end

  defp compile_fstring_spec(ctx, parts) do
    {seg_exprs, ctx} =
      Enum.map_reduce(parts, ctx, fn
        {:str, s}, c ->
          {lit(s), c}

        {:expr, e, _, _}, c ->
          {ee, c} = compile_expr(c, e)
          {call(:slop_rt, :to_str, [ee]), c}
      end)

    combined =
      Enum.reduce(seg_exprs, lit(<<>>), fn s, acc ->
        call(:slop_rt, :binop, [lit("+"), acc, s])
      end)

    {combined, ctx}
  end

  # ---------- names ----------

  defp read_name(ctx, n) do
    case ctx.env[n] do
      {:local, v, unbound?} ->
        if unbound? do
          {emit_unbound_check(v, n), ctx}
        else
          {v, ctx}
        end

      {:module, a} ->
        {lit(a), ctx}

      {:rec, lfname, d_var} ->
        a = fresh()
        k = fresh()
        {fun([a, k], apply_(lfname, [a, k, d_var])), ctx}

      nil ->
        cond do
          ctx.locals != nil and MapSet.member?(ctx.locals, n) and
              not MapSet.member?(ctx.globals_decl, n) ->
            {call(:slop_rt, :raise_exc, [
               lit(:UnboundLocalError),
               lit(<<"local variable '#{n}' referenced before assignment">>)
             ]), ctx}

          MapSet.member?(ctx.globals_decl, n) or Map.has_key?(ctx.mod_bindings, n) ->
            {call(:slop_rt, :global_get, [lit(ctx.mod), lit(String.to_atom(n))]), ctx}

          n == "__name__" ->
            if ctx.main? do
              {lit(<<"__main__">>), ctx}
            else
              {lit(Atom.to_string(ctx.mod)), ctx}
            end

          true ->
            case Slop.Builtins.lookup(n) do
              {:ok, m, f} ->
                {make_fun(m, f, 2), ctx}

              :error ->
                if String.to_atom(n) in @builtin_classes do
                  {lit(String.to_atom(n)), ctx}
                else
                  {call(:slop_rt, :raise_exc, [
                     lit(:NameError),
                     lit(<<"name '#{n}' is not defined">>)
                   ]), ctx}
                end
            end
        end
    end
  end

  defp emit_unbound_check(v, n) do
    other = fresh()

    case_(v, [
      clause([lit(:"$unbound")],
        call(:slop_rt, :raise_exc, [
          lit(:UnboundLocalError),
          lit(<<"local variable '#{n}' referenced before assignment">>)
        ])),
      clause([other], other)
    ])
  end

  # ---------- helpers ----------

  defp fresh_id do
    :erlang.unique_integer([:positive])
  end

  defp ensure_var(ctx, e) do
    case e do
      {:c_var, _, _} ->
        {e, ctx}

      {:c_literal, _, _} ->
        {e, ctx}

      _ ->
        v = fresh()
        {let_([v], e, v), ctx}
    end
  end
end
