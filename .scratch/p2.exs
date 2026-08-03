for src <- ["a[1:3]", "c[::2]", "d[1, 2]", "a[1:2:3]", "a[:]", "a[::-1]", "a[-1]"] do
  r = Slop.Parser.parse_expression(src)
  IO.puts("#{src} => #{inspect(r)}")
end
