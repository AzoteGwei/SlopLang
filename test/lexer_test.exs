defmodule Slop.LexerTest do
  use ExUnit.Case, async: true

  defp toks(src) do
    {:ok, ts} = Slop.Lexer.tokenize(src)
    Enum.map(ts, fn {k, _l, v} -> {k, v} end)
  end

  test "integers with bases and underscores" do
    assert toks("0x1F 0o17 0b101 1_000 42") == [
             {:int, 31},
             {:int, 15},
             {:int, 5},
             {:int, 1000},
             {:int, 42},
             {:newline, nil},
             {:eof, nil}
           ]
  end

  test "floats" do
    assert toks("1.5 .5 2. 1e3 2.5e-2") == [
             {:float, 1.5},
             {:float, 0.5},
             {:float, 2.0},
             {:float, 1000.0},
             {:float, 0.025},
             {:newline, nil},
             {:eof, nil}
           ]
  end

  test "strings with escapes" do
    assert toks(~s("a\\nb")) == [{:str, {"a\nb", []}}, {:newline, nil}, {:eof, nil}]
  end

  test "raw strings" do
    assert toks(~S(r"a\nb")) == [{:str, {"a\\nb", ["r"]}}, {:newline, nil}, {:eof, nil}]
  end

  test "triple-quoted strings span lines" do
    {:ok, ts} = Slop.Lexer.tokenize("\"\"\"x\ny\"\"\"")
    assert [{:str, _, {"x\ny", _}} | _] = ts
  end

  test "indentation produces INDENT/DEDENT" do
    kinds =
      Slop.Lexer.tokenize("if x:\n    y\nz\n")
      |> elem(1)
      |> Enum.map(&elem(&1, 0))

    assert kinds == [:kw, :name, :op, :newline, :indent, :name, :newline, :dedent, :name, :newline, :eof]
  end

  test "comments are skipped" do
    kinds =
      Slop.Lexer.tokenize("x # comment\ny\n")
      |> elem(1)
      |> Enum.map(&elem(&1, 0))

    assert kinds == [:name, :newline, :name, :newline, :eof]
  end

  test "line continuation in brackets" do
    kinds =
      Slop.Lexer.tokenize("x = [1,\n     2]\n")
      |> elem(1)
      |> Enum.map(&elem(&1, 0))

    assert kinds == [:name, :op, :op, :int, :op, :int, :op, :newline, :eof]
  end

  test "f-string token keeps raw content for parser" do
    {:ok, ts} = Slop.Lexer.tokenize(~S(f"a{1 + 2}b"))
    assert [{:fstring, 1, {"a{1 + 2}b", ["f"]}} | _] = ts
  end
end
