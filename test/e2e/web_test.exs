defmodule Slop.WebFrameworkTest do
  use ExUnit.Case, async: false

  @app Path.expand(Path.join([__DIR__, "..", "..", "examples", "webapp.slop"]))

  defp slopc do
    Path.expand(Path.join([__DIR__, "..", "..", "slopc"]))
  end

  defp curl(args) do
    {out, _} = System.cmd("curl", ["-s", "-m", "15" | args])
    out
  end

  test "dev server: routes, params, query, POST, 404, concurrency" do
    port = 18200 + :rand.uniform(1000)

    server =
      Task.start(fn ->
        System.cmd(slopc(), ["run", @app, to_string(port)], stderr_to_stdout: true)
      end)

    base = "http://127.0.0.1:#{port}"

    # wait for the server to accept connections
    wait_up(base, 50)

    assert curl([base <> "/"]) =~ "Hello from SlopLang web!"
    assert curl([base <> "/hello/slop"]) == ~s({"hello": "slop"})
    assert curl([base <> "/search?q=beam"]) =~ ~s("q": "beam")
    assert curl([base <> "/add?a=4&b=5"]) == ~s({"sum": 9})
    assert curl(["-X", "POST", "-d", "hello slop", base <> "/echo"]) == ~s({"you_said": "hello slop"})
    assert curl(["-X", "POST", "-d", "10,20,30", base <> "/sum"]) == ~s({"sum": 60})

    not_found = curl(["-i", base <> "/nope"])
    assert not_found =~ "404 Not Found"
    assert not_found =~ "not found: GET /nope"

    teapot = curl(["-i", base <> "/missing"])
    assert teapot =~ "418"
    assert teapot =~ "teapot says no"

    created = curl(["-i", base <> "/tuple"])
    assert created =~ "201 Created"
    assert created =~ "X-Custom: slop"

    # concurrency: 5 x 1000ms slow requests must finish well under the
    # ~5s a serial server would need
    {us, _} =
      :timer.tc(fn ->
        1..5
        |> Enum.map(fn _ ->
          Task.async(fn -> curl([base <> "/slow/1000"]) end)
        end)
        |> Enum.each(fn t ->
          assert Task.await(t, 20_000) =~ "slow done after 1000ms"
        end)
      end)

    assert us < 4_000_000, "parallel slow requests took #{us}us, expected concurrency"
  after
    :ok
  end

  defp wait_up(_base, 0), do: raise("server did not start")

  defp wait_up(base, n) do
    case curl(["-m", "1", base <> "/"]) do
      "" ->
        Process.sleep(200)
        wait_up(base, n - 1)

      _ ->
        :ok
    end
  end
end
