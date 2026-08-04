defmodule Slop.OutboundInteropTest do
  use ExUnit.Case, async: false

  @dir Path.expand(Path.join([__DIR__, "..", "..", "examples", "outbound"]))
  @rt Path.expand(Path.join([__DIR__, "..", "..", "_build", "dev", "lib", "slop", "ebin"]))

  defp slopc do
    Path.expand(Path.join([__DIR__, "..", "..", "slopc"]))
  end

  test "compiled module is callable from Erlang and Elixir" do
    tmp = Path.join(System.tmp_dir!(), "slop_outbound_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(tmp)

    {_, 0} =
      System.cmd(slopc(), ["build", Path.join(@dir, "out.slop"), "-o", tmp],
        stderr_to_stdout: true
      )

    erl_src = Path.join(@dir, "call_out.erl")
    {_, 0} = System.cmd("erlc", ["-o", tmp, erl_src], stderr_to_stdout: true)

    {erl_out, 0} =
      System.cmd("erl", ["-noshell", "-pa", tmp, "-pa", @rt, "-eval", "call_out:main()."],
        stderr_to_stdout: true
      )

    assert erl_out =~ "double: 42"
    assert erl_out =~ ~s(greet default: <<"hi beam!">>)
    assert erl_out =~ ~s(greet kw: <<"hi bob?">>)
    assert erl_out =~ "Point.sum: 7"

    {exs_out, 0} =
      System.cmd(
        "elixir",
        ["-pa", tmp, "-pa", @rt, Path.join(@dir, "call_out.exs")],
        stderr_to_stdout: true
      )

    assert exs_out =~ "double: 42"
    assert exs_out =~ ~s(greet: "hi elixir!")
    assert exs_out =~ "Point.sum: 30"
  end
end
