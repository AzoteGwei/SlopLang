defmodule Slop.EvalTest do
  use ExUnit.Case, async: false

  defp slopc do
    Path.expand(Path.join([__DIR__, "..", "..", "slopc"]))
  end

  defp run_probe(name, source) do
    path = Path.join(System.tmp_dir!(), name)
    File.write!(path, source)
    {out, code} = System.cmd(slopc(), ["run", path], stderr_to_stdout: true)
    {out, code}
  end

  test "eval expressions and caller module globals" do
    {out, code} =
      run_probe("slop_eval_basic.slop", """
      g = 10
      print("eval:", eval("1 + 2 * 3"))
      print("eval global:", eval("g * 2"))
      """)

    assert code == 0, out
    assert out =~ "eval: 7"
    assert out =~ "eval global: 20"
  end

  test "eval does not see caller locals" do
    {out, code} =
      run_probe("slop_eval_locals.slop", """
      def f():
          local = 99
          return eval("local")

      try:
          f()
      except NameError as e:
          print("local not visible:", e)
      """)

    assert code == 0, out
    assert out =~ "local not visible: name 'local' is not defined"
  end

  test "exec defines persist in shared module context" do
    {out, code} =
      run_probe("slop_eval_exec.slop", """
      exec("def h(x): return x * 2")
      print("exec def:", eval("h(21)"))
      print("shared ctx eval:", eval("h(21)"))
      exec("counter = 5")
      print("exec global persisted:", eval("counter + 1"))
      """)

    assert code == 0, out
    assert out =~ "exec def: 42"
    assert out =~ "shared ctx eval: 42"
    assert out =~ "exec global persisted: 6"
  end

  test "named contexts are isolated from each other" do
    {out, code} =
      run_probe("slop_eval_named.slop", """
      exec("x = 1", "a")
      exec("x = 2", "b")
      print("a:", eval("x", "a"))
      print("b:", eval("x", "b"))
      try:
          print(eval("x", "c"))
      except NameError:
          print("c empty")
      """)

    assert code == 0, out
    assert out =~ "a: 1"
    assert out =~ "b: 2"
    assert out =~ "c empty"
  end

  test "syntax vs runtime error distinction and session survival" do
    {out, code} =
      run_probe("slop_eval_errors.slop", """
      try:
          eval("1 +* 2")
      except SyntaxError as e:
          print("syntax error:", type(e).__name__)

      try:
          eval("1 / 0")
      except ZeroDivisionError:
          print("runtime error: ZeroDivisionError")

      print("session still works:", eval("2 + 2"))
      print("exec returns:", exec("pass"))
      """)

    assert code == 0, out
    assert out =~ "syntax error: SyntaxError"
    assert out =~ "runtime error: ZeroDivisionError"
    assert out =~ "session still works: 4"
    assert out =~ "exec returns: None"
  end

  test "exec'd funs stay callable across many dynamic calls" do
    {out, code} =
      run_probe("slop_eval_retain.slop", """
      exec("def h(x): return x * 2")
      total = 0
      for i in range(5):
          total += eval("h(i)")
      print("retained fun loop:", total)
      f = eval("lambda x: x + 100")
      print("eval closure:", f(1))
      print("still callable after more evals:", eval("1"), eval("h(3)"))
      """)

    assert code == 0, out
    assert out =~ "retained fun loop: 20"
    assert out =~ "eval closure: 101"
    assert out =~ "still callable after more evals: 1 6"
  end
end
