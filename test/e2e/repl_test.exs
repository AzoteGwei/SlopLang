defmodule Slop.ReplTest do
  use ExUnit.Case, async: false

  defp slopc do
    Path.expand(Path.join([__DIR__, "..", "..", "slopc"]))
  end

  defp run_piped(input) do
    file = Path.join(System.tmp_dir!(), "slop_repl_in.txt")
    File.write!(file, input)

    System.cmd("sh", ["-c", "#{inspect(slopc())} repl < #{inspect(file)}"],
      stderr_to_stdout: true
    )
  end

  test "piped stdin: expressions, statements, shared context, blocks" do
    input = """
    1 + 2
    x = 5
    x * 2
    def f(n):
        return n + 1

    f(41)
    print("hello")
    if x > 3:
        print("big")

    y = (1 +
    2)
    y
    """

    {out, code} = run_piped(input)
    assert code == 0, out

    assert out == """
           3
           10
           42
           hello
           big
           3
           """
  end

  test "piped stdin: errors are reported and the session continues" do
    input = """
    1 / 0
    undefined_name
    1 +* 2
    raise ValueError("boom")
    2 + 2
    """

    {out, code} = run_piped(input)
    assert code == 0, out
    assert out =~ "ZeroDivisionError: division by zero"
    assert out =~ "NameError: name 'undefined_name' is not defined"
    assert out =~ "SyntaxError: line 1:"
    assert out =~ "ValueError: boom"
    assert String.trim_trailing(out) |> String.ends_with?("4")
  end

  test "piped stdin: names persist across many lines (shared context)" do
    lines = for i <- 1..30, do: "acc_#{i} = #{i}\nacc_#{i} + 1"
    input = Enum.join(lines, "\n") <> "\n"

    {out, code} = run_piped(input)
    assert code == 0, out

    got = String.split(out, "\n", trim: true) |> Enum.map(&String.to_integer/1)
    assert got == Enum.map(1..30, &(&1 + 1))
  end

  test "TTY: banner, prompts, blocks, Ctrl-C interrupt, history, Ctrl-D" do
    # octal escapes: dash printf does not support \xHH
    driver = """
    printf 'if True:\\r'; sleep 0.4
    printf '    print("in block")\\r'; sleep 0.4
    printf '\\r'; sleep 0.6
    printf 'while True:\\r'; sleep 0.4
    printf '    pass\\r'; sleep 0.4
    printf '\\r'; sleep 1.5
    printf '\\003'; sleep 0.6
    printf '1 + 12\\177\\1773\\r'; sleep 0.6
    printf '\\033[A'; sleep 0.4
    printf '\\r'; sleep 0.6
    printf '\\004'; sleep 0.4
    """

    log = Path.join(System.tmp_dir!(), "slop_repl_tty.log")

    {_, code} =
      System.cmd(
        "sh",
        ["-c", "{ #{String.trim_trailing(driver)}\n} | timeout 60 script -qec \"#{slopc()} repl\" #{inspect(log)} >/dev/null 2>&1", "--"],
        stderr_to_stdout: true
      )

    out = File.read!(log)
    assert code == 0, out
    assert out =~ "SlopLang 0.1.0 (BEAM/OTP"
    assert out =~ ">>> if True:"
    assert out =~ "..."
    assert out =~ "in block"
    assert out =~ "KeyboardInterrupt"
    # backspace turned `1 + 12` into `1 + 3`; up-arrow recalled it
    assert out =~ ">>> 1 + 3"
    assert out =~ "4"
  end
end
