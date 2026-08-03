defmodule Slop.E2ETest do
  use ExUnit.Case, async: false

  @examples_dir Path.expand(Path.join([__DIR__, "..", "..", "examples"]))

  defp slopc do
    Path.expand(Path.join([__DIR__, "..", "..", "slopc"]))
  end

  defp expected_for(ex) do
    File.read!(ex <> ".expected")
  end

  for slop <- Path.wildcard(Path.join(@examples_dir, "*.slop")) do
    name = Path.basename(slop, ".slop")

    if File.exists?(slop <> ".expected") do
      test "example #{name}" do
        ex = Path.join(@examples_dir, unquote(name) <> ".slop")

        {out, code} =
          System.cmd(slopc(), ["run", ex], stderr_to_stdout: true)

        expected = expected_for(ex)
        assert code == 0, "exit #{code}: #{out}"
        assert String.trim_trailing(out) == String.trim_trailing(expected)
      end
    end
  end
end
