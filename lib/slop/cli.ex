defmodule Slop.CLI do
  @moduledoc """
  slopc — the SlopLang compiler/driver.

  Commands:
    run FILE.slop [ARGS...]   compile & execute
    build FILE.slop -o DIR    compile to .beam files
    tokens FILE.slop          dump lexer tokens
    parse FILE.slop           dump AST
    dump FILE.slop            dump Core Erlang
  """

  def main(argv) do
    case argv do
      ["run", file | rest] -> run(file, rest)
      ["build", file | rest] -> build(file, rest)
      ["tokens", file] -> tokens(file)
      ["parse", file] -> parse(file)
      ["dump", file] -> dump(file)
      _ -> usage()
    end
  end

  defp usage do
    IO.puts("slopc run FILE.slop [ARGS...] | build FILE.slop -o DIR | tokens FILE | parse FILE | dump FILE")
    System.halt(2)
  end

  defp run(file, args) do
    :application.set_env(:slop, :argv, args)

    case Slop.Compiler.compile_file(file) do
      {:ok, mods, main} ->
        load_all(mods)
        mod_atom = main
        :slop_rt.set_argv(Enum.map(args, &to_string/1))

        try do
          apply(mod_atom, :"$__init__", [])
          :ok
        rescue
          e -> reraise(e, __STACKTRACE__)
        catch
          {:'$slop_exc', class, inst} ->
            IO.puts(:stderr, "uncaught exception: #{class}")
            IO.puts(:stderr, format_instance(inst))
            System.halt(1)

          :exit, reason ->
            if reason != :normal do
              IO.puts(:stderr, "exit: #{inspect(reason)}")
              System.halt(1)
            end
        end

      {:error, msg} ->
        IO.puts(:stderr, msg)
        System.halt(1)
    end
  end

  defp format_instance(inst) when is_map(inst) do
    case Map.get(inst, :"$__str__") do
      nil -> inspect(inst)
      _ -> inspect(inst)
    end
  end

  defp format_instance(inst), do: inspect(inst)

  defp load_all(mods) do
    for {_path, {mod, bin}} <- mods do
      {:module, ^mod} = :code.load_binary(mod, ~c"slopc", bin)
    end

    :ok
  end

  defp build(file, rest) do
    out =
      case rest do
        ["-o", dir | _] -> dir
        _ -> "."
      end

    case Slop.Compiler.compile_file(file) do
      {:ok, mods, _main} ->
        Slop.Compiler.write_beams(mods, out)
        IO.puts("wrote #{map_size(mods)} beam file(s) to #{out}")

      {:error, msg} ->
        IO.puts(:stderr, msg)
        System.halt(1)
    end
  end

  defp tokens(file) do
    source = File.read!(file)

    case Slop.Lexer.tokenize(source) do
      {:ok, toks} -> Enum.each(toks, &IO.inspect/1)
      {:error, msg} -> IO.puts(:stderr, msg)
    end
  end

  defp parse(file) do
    source = File.read!(file)

    case Slop.Parser.parse(source) do
      {:ok, ast} -> IO.inspect(ast, limit: :infinity, printable_limit: :infinity)
      {:error, msg} -> IO.puts(:stderr, inspect(msg))
    end
  end

  defp dump(file) do
    source = File.read!(file)
    {:ok, ast} = Slop.Parser.parse(source)
    modname = file |> Path.basename(".slop")
    {:ok, forms, _} = Slop.Codegen.compile_module(ast, modname, main?: true)
    IO.puts(:cerl_prettypr.format(forms))
  end
end
