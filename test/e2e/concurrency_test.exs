defmodule Slop.ConcurrencyTest do
  use ExUnit.Case, async: false

  @ex Path.expand(Path.join([__DIR__, "..", "..", "examples", "11_concurrency.slop"]))

  defp slopc do
    Path.expand(Path.join([__DIR__, "..", "..", "slopc"]))
  end

  test "spawn/join concurrency with timing evidence" do
    {out, code} = System.cmd(slopc(), ["run", @ex], stderr_to_stdout: true)
    assert code == 0, out

    assert out =~ "sequential: 10 20 30"
    assert out =~ "concurrent: [10, 20, 30]"
    assert out =~ "join re-raised: task failed"
    assert out =~ ~r/main got: \('reply', 42\)/
    assert out =~ "8 cpu tasks sum: 4999950000"

    [_, seq_ms] = Regex.run(~r/sequential: .* in (\d+) ms/, out)
    [_, con_ms] = Regex.run(~r/concurrent: .* in (\d+) ms/, out)

    seq = String.to_integer(seq_ms)
    con = String.to_integer(con_ms)

    # 3 x 300ms sleeps: sequential ~900ms, concurrent ~300ms
    assert seq >= 850, "sequential should take ~900ms, got #{seq}"
    assert con < 700, "concurrent should take ~300ms, got #{con}"
  end
end
