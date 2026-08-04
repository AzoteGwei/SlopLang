defmodule Slop.StdlibTest do
  use ExUnit.Case, async: false

  @ex Path.expand(Path.join([__DIR__, "..", "..", "examples", "15_stdlib.slop"]))

  defp slopc do
    Path.expand(Path.join([__DIR__, "..", "..", "slopc"]))
  end

  test "stdlib modules: golden output" do
    {out, code} = System.cmd(slopc(), ["run", @ex], stderr_to_stdout: true)
    assert code == 0, out

    expected = File.read!(@ex <> ".expected")
    assert out == expected

    # spot-check the load-bearing lines per module
    assert out =~ "math: 3 4 6 720 4"
    assert out =~ "random: 61 a [2, 4, 3, 1]"
    assert out =~ "hashlib: 8a7148dfee42902f881086ce7249dd2b"
    assert out =~ "statistics: 2.5 3 2"
    assert out =~ "functools: 6 110"
    assert out =~ "functools cache fib(35): 9227465"
    assert out =~ "itertools: [('a', 'b'), ('b', 'c')]"
    assert out =~ "collections: 4 0 [('s', 4), ('i', 4)] 11"
    assert out =~ "re: 66-42 66 42 (6, 8)"
    assert out =~ ~s(json: {"lang": "slop", "nested": {"ok": "yes"}, "nums": [1, 2.5, true, null]})
    assert out =~ "datetime: 2024-03-01T15:30:45 4 2024-03-01"
    assert out =~ "os: /tmp/x ('a.tar', '.gz') b.txt"
    assert out =~ "sys: sloplang 0.1.0 (BEAM/OTP"
  end

  test "stdlib error behavior" do
    probe = """
    import json
    import math
    import statistics

    try:
        json.loads("{bad json")
    except ValueError as e:
        print("json error:", type(e).__name__)

    try:
        math.factorial(-1)
    except ValueError:
        print("factorial error ok")

    try:
        statistics.mean([])
    except ValueError:
        print("mean error ok")
    """

    path = Path.join(System.tmp_dir!(), "slop_stdlib_err.slop")
    File.write!(path, probe)
    {out, code} = System.cmd(slopc(), ["run", path], stderr_to_stdout: true)
    assert code == 0, out
    assert out =~ "json error: ValueError"
    assert out =~ "factorial error ok"
    assert out =~ "mean error ok"
  end
end
