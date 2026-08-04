IO.puts("double: #{inspect(:out.double([21], %{}))}")
IO.puts("greet: #{inspect(:out.greet(["elixir"], %{}))}")
p = :slop_rt.instantiate(:"out.Point", [10, 20], %{})
IO.puts("Point.sum: #{inspect(apply(:out, :"out.Point.sum", [[p], %{}, {}]))}")
