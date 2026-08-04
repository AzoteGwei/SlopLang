defmodule Slop.HotReloadTest do
  use ExUnit.Case, async: false

  defp slopc do
    Path.expand(Path.join([__DIR__, "..", "..", "slopc"]))
  end

  defp curl(args) do
    {out, _} = System.cmd("curl", ["-s", "-m", "15" | args])
    out
  end

  test "recompile/1 swaps code in the same VM, repeatedly" do
    dir = Path.join(System.tmp_dir!(), "slop_reload_#{:rand.uniform(100_000)}")
    File.mkdir_p!(dir)
    a = Path.join(dir, "a.slop")
    main = Path.join(dir, "main.slop")

    File.write!(a, "def f():\n    return \"v1\"\n")

    File.write!(main, """
    import a
    import sloplang
    import erlang.file as file

    print("round 1:", a.f())
    for v in ["v2", "v3", "v4"]:
        file.write_file("#{a}", "def f():\\n    return \\"" + v + "\\"\\n")
        r = sloplang.recompile("#{a}")
        print("recompile:", r[0])
        print("now:", a.f())
    """)

    {out, code} = System.cmd(slopc(), ["run", main], stderr_to_stdout: true)
    assert code == 0, out
    assert out =~ "round 1: v1"
    assert out =~ "recompile: ok\nnow: v2"
    assert out =~ "recompile: ok\nnow: v3"
    assert out =~ "recompile: ok\nnow: v4"
  end

  test "debug server reloads on edit, survives broken edits" do
    dir = Path.join(System.tmp_dir!(), "slop_webreload_#{:rand.uniform(100_000)}")
    File.mkdir_p!(dir)
    app = Path.join(dir, "app.slop")
    port = 19200 + :rand.uniform(700)

    write_app = fn body ->
      File.write!(app, """
      from web import App

      app = App()

      @app.get("/hello")
      def hello():
          return "#{body}"

      app.run(port=#{port}, debug=True)
      """)
    end

    write_app.("hello v1\\n")

    Task.start(fn -> System.cmd(slopc(), ["run", app], stderr_to_stdout: true) end)

    base = "http://127.0.0.1:#{port}"

    try do
      wait_up(base, 60)
      assert curl([base <> "/hello"]) == "hello v1\n"

      # edit → new body without a restart
      write_app.("hello v2\\n")
      wait_body(base, "hello v2\n", 60)

      # break the source → server keeps serving the previous version
      File.write!(app, "from web import App\napp = App()\n@app.get(\"/hello\")\ndef hello(:\n")
      Process.sleep(2500)
      assert curl([base <> "/hello"]) == "hello v2\n"

      # fix it → reload resumes
      write_app.("hello v3: fixed\\n")
      wait_body(base, "hello v3: fixed\n", 60)
    after
      System.cmd("pkill", ["-f", "slopc run #{app}"])
    end
  end

  defp wait_up(_base, 0), do: raise("server did not start")

  defp wait_up(base, n) do
    case curl(["-m", "1", base <> "/hello"]) do
      "" ->
        Process.sleep(200)
        wait_up(base, n - 1)

      _ ->
        :ok
    end
  end

  defp wait_body(_base, _want, 0), do: raise("server never served the new body")

  defp wait_body(base, want, n) do
    if curl(["-m", "2", base <> "/hello"]) == want do
      :ok
    else
      Process.sleep(300)
      wait_body(base, want, n - 1)
    end
  end
end
