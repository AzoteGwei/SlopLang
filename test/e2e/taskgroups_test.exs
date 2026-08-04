defmodule Slop.TaskgroupsTest do
  use ExUnit.Case, async: false

  @ex Path.expand(Path.join([__DIR__, "..", "..", "examples", "13_taskgroups.slop"]))

  defp slopc do
    Path.expand(Path.join([__DIR__, "..", "..", "slopc"]))
  end

  test "join timeout, cancel tree-kill, task groups, 10k scale" do
    {out, code} = System.cmd(slopc(), ["run", @ex], stderr_to_stdout: true)
    assert code == 0, out

    assert out =~ "join 100ms: None"
    assert out =~ "join rest: done"
    assert out =~ "parent alive, child spawned: True"
    assert out =~ "parent alive after cancel: False"
    assert out =~ "join after cancel: task was cancelled"
    assert out =~ "tree cancelled ok"
    refute out =~ "child finished (should not see)"
    refute out =~ "grandchild finished (should not see)"

    assert out =~ "fail_fast all ok: [0, 2, 4, 6, 8]"

    assert out =~
             "collect: [(ok, 0), (ok, 1), (error, 'SlopError: ValueError: child 2 blew up'), (ok, 3)]"

    assert out =~ "fail_fast propagated: child 2 blew up"
    assert out =~ "group 10k sum: 50005000"
    assert out =~ "direct 10k sum: 50005000"
  end
end
