src = """
import os, sys as system
from pkg.mod import a, b as bee
from . import local

x = 5
y: int = 10
a, b = 1, 2
*a, b = [1, 2, 3]

def greet(name: str, punct="!", *args, **kwargs) -> str:
    return f"hi {name}{punct}"

@deco
@deco2(1, 2)
def f():
    pass

class Point(Base, metaclass=Meta):
    def __init__(self, x, y):
        self.x = x
        self.y = y

while x > 0:
    x -= 1
    if x == 3:
        continue
    else:
        print(x)
else:
    print("done")

for i, v in enumerate(xs):
    print(i, v)

try:
    risky()
except ValueError as e:
    print(e)
except (TypeError, KeyError):
    pass
except:
    raise
else:
    print("ok")
finally:
    cleanup()

match command:
    case 0 | 1:
        pass
    case [first, *rest] if first > 0:
        print(rest)
    case {"name": n, **others}:
        pass
    case Point(x=0, y=y) as p:
        pass
    case Color.RED:
        pass
    case _:
        pass

result = [x * y for x in xs for y in ys if x > 0]
sq = {x: x*x for x in xs}
s = {1, 2, 3}
g = (x for x in xs)
l = lambda a, b=1: a + b
t = 1 if x > 0 else -1
w = x if (y := 5) else 0
z = a[1:3] + b[-1] + c[::2] + d[1, 2]
call(f(1, *args, k=2, **kw))
assert x is not None, "nope"
del a[0]
with open("f") as fh:
    print(fh)
global_var = g(1)(2)(3)
"""
case Slop.Parser.parse(src) do
  {:ok, ast} -> IO.puts("PARSE OK"); IO.inspect(ast, limit: :infinity, printable_limit: :infinity)
  {:error, line, msg} -> IO.puts("PARSE ERROR line #{line}: #{msg}")
end
