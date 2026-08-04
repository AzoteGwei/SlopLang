defmodule Slop.StreamsTest do
  use ExUnit.Case, async: false

  @ex Path.expand(Path.join([__DIR__, "..", "..", "examples", "14_streams.slop"]))

  defp slopc do
    Path.expand(Path.join([__DIR__, "..", "..", "slopc"]))
  end

  test "lazy streams: infinite sources, for/comp interop" do
    {out, code} = System.cmd(slopc(), ["run", @ex], stderr_to_stdout: true)
    assert code == 0, out

    assert out =~ "fib take 10: [0, 1, 1, 2, 3, 5, 8, 13, 21, 34]"
    assert out =~ "even squares: [0, 4, 16, 36, 64, 100]"
    assert out =~ "for over stream: 10"
    assert out =~ "comp over stream: [0, 2, 2, 4]"
    assert out =~ "stream from list: [11, 21, 31]"
    assert out =~ "iterate: [1, 10, 100]"
  end

  test "1M-element stream pipeline stays memory-flat" do
    probe = """
    import stream
    import erlang.erlang

    def mem():
        (tag, n) = erlang.process_info(self_pid(), atom("memory"))
        return n

    m0 = mem()
    pipeline = stream.smap(lambda x: x + 1, stream.smap(lambda x: x * 2, stream.sfilter(lambda x: x % 3 != 0, stream.naturals())))
    total = 0
    for x in stream.take(1000000, pipeline):
        total += x
    print("sum:", total)
    print("mem growth:", mem() - m0)
    """

    path = Path.join(System.tmp_dir!(), "slop_stream_mem_probe.slop")
    File.write!(path, probe)

    {out, code} = System.cmd(slopc(), ["run", path], stderr_to_stdout: true)
    assert code == 0, out

    # sum over n in 1..1499999 with n % 3 != 0 of (2n + 1):
    #   2 * 750000000000 + 1000000
    assert out =~ "sum: 1500001000000"

    [_, growth] = Regex.run(~r/mem growth: (-?\d+)/, out)
    growth = String.to_integer(growth)
    assert growth < 20_000_000, "stream pipeline leaked memory: #{growth} bytes"
  end
end
