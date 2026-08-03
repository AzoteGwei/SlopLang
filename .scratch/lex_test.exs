src = """
# comment
x = 5
name = "hi\\nthere"
def f(a, b=1):
    if a > 0:
        return a + b  # inline
    elif a == 0:
        return 0
    else:
        s = f"val={a} and {b + 1} end"
        return s

for i in range(10):
    print(i)
y = 0x1F + 1_000 + .5 + 1e3 + 2.
z = [1, 2,
     3]
w = {'a': 1}
t = (1, 2)
multiline = \'\'\'triple
line2\'\'\'
raw = r"\\n"
assert x is not None
"""
case Slop.Lexer.tokenize(src) do
  {:ok, toks} -> Enum.each(toks, &IO.inspect/1)
  err -> IO.inspect(err)
end
