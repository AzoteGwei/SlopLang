for src <- ["result = [x * y for x in xs for y in ys if x > 0]", "z = a[1:3] + b[-1]", "call(f(1, *args, k=2, **kw))", "w = x if (y := 5) else 0", "sq = {x: x*x for x in xs}", "del a[0]", "g = (x for x in xs)"] do
  r = Slop.Parser.parse(src <> "\n")
  IO.puts("#{src} => #{if match?({:ok, _}, r), do: "OK", else: inspect(r)}")
end
