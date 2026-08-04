defmodule Slop.Builtins do
  @moduledoc """
  Registry of compile-time-known builtin functions (protocol fun(Pos, Kw)).
  Builtin *type* names (int, str, ...) are NOT here: they resolve to class
  atoms handled by the runtime instantiate path.
  """

  @table %{
    "atom" => {:slop_rt, :atom},
    "spawn" => {:slop_rt, :spawn_task},
    "join" => {:slop_rt, :join},
    "sleep" => {:slop_rt, :sleep},
    "send" => {:slop_rt, :send_msg},
    "recv" => {:slop_rt, :recv_msg},
    "self_pid" => {:slop_rt, :self_pid},
    "monotonic" => {:slop_rt, :monotonic},
    "cancel" => {:slop_rt, :cancel},
    "is_alive" => {:slop_rt, :is_alive},
    "task_group" => {:slop_rt, :task_group},
    "group_spawn" => {:slop_rt, :group_spawn},
    "group_join" => {:slop_rt, :group_join},
    "eval" => {:slop_rt, :eval_wrap},
    "exec" => {:slop_rt, :exec_wrap},
    "seq_init" => {:slop_rt, :seq_init_wrap},
    "seq_next" => {:slop_rt, :seq_next_wrap},
    "print" => {:slop_rt, :print},
    "len" => {:slop_rt, :len},
    "repr" => {:slop_rt, :repr},
    "range" => {:slop_rt, :range},
    "enumerate" => {:slop_rt, :enumerate},
    "zip" => {:slop_rt, :zip},
    "map" => {:slop_rt, :map},
    "filter" => {:slop_rt, :filter},
    "sorted" => {:slop_rt, :sorted},
    "reversed" => {:slop_rt, :reversed},
    "sum" => {:slop_rt, :sum},
    "min" => {:slop_rt, :min},
    "max" => {:slop_rt, :max},
    "abs" => {:slop_rt, :abs},
    "all" => {:slop_rt, :all},
    "any" => {:slop_rt, :any},
    "chr" => {:slop_rt, :chr},
    "ord" => {:slop_rt, :ord},
    "hex" => {:slop_rt, :hex},
    "oct" => {:slop_rt, :oct},
    "bin" => {:slop_rt, :bin},
    "round" => {:slop_rt, :round},
    "divmod" => {:slop_rt, :divmod},
    "pow" => {:slop_rt, :pow},
    "hash" => {:slop_rt, :hash},
    "id" => {:slop_rt, :id},
    "callable" => {:slop_rt, :callable},
    "hasattr" => {:slop_rt, :hasattr},
    "getattr" => {:slop_rt, :getattr_wrap},
    "setattr" => {:slop_rt, :setattr_wrap},
    "isinstance" => {:slop_rt, :isinstance},
    "issubclass" => {:slop_rt, :issubclass},
    "type" => {:slop_rt, :type},
    "input" => {:slop_rt, :input},
    "open" => {:slop_rt, :open},
    "argv" => {:slop_rt, :argv},
    "exit" => {:slop_rt, :exit}
  }

  def lookup(name) do
    case Map.fetch(@table, name) do
      {:ok, {m, f}} -> {:ok, m, f}
      :error -> :error
    end
  end
end
