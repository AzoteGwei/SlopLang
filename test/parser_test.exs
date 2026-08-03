defmodule Slop.ParserTest do
  use ExUnit.Case, async: true

  defp parse!(src) do
    {:ok, ast} = Slop.Parser.parse(src)
    ast
  end

  test "simple assignment" do
    assert {:module, _, [{:assign, _, [{:name, _, "x"}], {:lit, _, 1}}]} = parse!("x = 1\n")
  end

  test "binary operator precedence" do
    {:module, _, [{:exprstmt, _, e}]} = parse!("1 + 2 * 3\n")
    assert {:binop, _, "+", {:lit, _, 1}, {:binop, _, "*", {:lit, _, 2}, {:lit, _, 3}}} = e
  end

  test "comparison chaining" do
    {:module, _, [{:exprstmt, _, {:compare, _, ops}}]} = parse!("a < b <= c\n")
    assert length(ops) == 2
  end

  test "if statement with else" do
    {:module, _, [{:if, _, _c, _b, o}]} = parse!("if x:\n    y\nelse:\n    z\n")
    assert [{:exprstmt, _, {:name, _, "z"}}] = o
  end

  test "def with defaults and star args" do
    {:module, _, [{:def, _, "f", params, _, _, _}]} =
      parse!("def f(a, b=1, *args, c, **kw):\n    pass\n")

    assert [{"a", nil, nil}, {"b", {:lit, _, 1}, nil}] = params.pos
    assert {"args", _} = params.vararg
    assert [{"c", nil, nil}] = params.kwonly
    assert {"kw", _} = params.kwarg
  end

  test "class with methods" do
    {:module, _, [{:class, _, "C", [], body, []}]} =
      parse!("class C:\n    def m(self):\n        return 1\n")

    assert [{:def, _, "m", _, _, _, _}] = body
  end

  test "list comprehension" do
    {:module, _, [{:exprstmt, _, {:listcomp, _, elem, clauses}}]} =
      parse!("[x * 2 for x in xs if x > 0]\n")

    assert {:binop, _, "*", _, _} = elem
    assert [{:for, {:name, _, "x"}, {:name, _, "xs"}}, {:if, _}] = clauses
  end

  test "dict comprehension" do
    {:module, _, [{:exprstmt, _, {:dictcomp, _, _k, _v, _clauses}}]} =
      parse!("{k: v for k, v in pairs}\n")
  end

  test "match statement with patterns" do
    {:module, _, [{:match, _, _subj, cases}]} =
      parse!("match p:\n    case (0, y):\n        a\n    case {\"k\": v}:\n        b\n    case _:\n        c\n")

    assert length(cases) == 3
  end

  test "try/except/finally" do
    {:module, _, [{:try, _, _b, handlers, _orelse, fin}]} =
      parse!("try:\n    a\nexcept ValueError as e:\n    b\nfinally:\n    c\n")

    assert [{_, "e", _}] = handlers
    assert fin != []
  end

  test "slices" do
    {:module, _, [{:exprstmt, _, {:subscript, _, _, {:slice, _, _, _, _}}}]} =
      parse!("x[1:10:2]\n")
  end

  test "walrus operator" do
    {:module, _, [{:exprstmt, _, {:namedexpr, _, "n", _}}]} = parse!("(n := 5)\n")
  end

  test "starred unpacking in assignment" do
    {:module, _, [{:assign, _, [{:tuple, _, ts}], _}]} = parse!("a, *rest = xs\n")
    assert [_, {:starred, _, _}] = ts
  end

  test "f-string parses to parts" do
    {:module, _, [{:exprstmt, _, {:fstring, _, parts}}]} = parse!(~S(f"a{x}b") <> "\n")
    assert length(parts) == 3
  end

  test "lambda" do
    {:module, _, [{:exprstmt, _, {:lambda, _, _, _}}]} = parse!("lambda x: x + 1\n")
  end

  test "conditional expression" do
    {:module, _, [{:exprstmt, _, {:ifexp, _, _, _, _}}]} = parse!("a if c else b\n")
  end

  test "global statement" do
    {:module, _, [{:def, _, _, _, body, _, _}]} = parse!("def f():\n    global x\n")
    assert [{:global, _, ["x"]}] = body
  end

  test "raise from" do
    {:module, _, [{:raise, _, _, from}]} = parse!("raise ValueError() from e\n")
    assert from != nil
  end

  test "assert with message" do
    {:module, _, [{:assert, _, _, msg}]} = parse!("assert x, 'bad'\n")
    assert msg != nil
  end

  test "with multiple items" do
    {:module, _, [{:with, _, items, _}]} = parse!("with a as x, b as y:\n    pass\n")
    assert length(items) == 2
  end

  test "decorators" do
    {:module, _, [{:def, _, _, _, _, decos, _}]} = parse!("@deco\ndef f():\n    pass\n")
    assert [{:name, _, "deco"}] = decos
  end

  test "import forms" do
    {:module, _, [{:import, _, _}, {:from, _, "mod", names}]} =
      parse!("import a.b\nfrom mod import x, y as z\n")

    assert length(names) == 2
  end
end
