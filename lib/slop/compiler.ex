defmodule Slop.Compiler do
  @moduledoc """
  Drives compilation of SlopLang source files to BEAM binaries.
  Handles import resolution across a search path.
  """

  defmodule Error do
    defexception [:message, :file]
  end

  defstruct search_path: [], modules: %{}

  @doc """
  Compile the given entry .slop file (and transitively imported modules).
  Returns {:ok, [{module_atom, beam_binary}], main_module_atom} or {:error, msg}.
  """
  def compile_file(path, opts \\ []) do
    search_path = Keyword.get(opts, :search_path, [Path.dirname(path)])
    entry = Path.expand(path)

    case compile_tree(entry, search_path, entry, %{}) do
      {:ok, mods, main} -> {:ok, mods, main}
      {:error, _} = e -> e
    end
  end

  @doc "Compile a source string as a standalone module."
  def compile_source(source, modname, opts \\ []) do
    with {:ok, ast} <- parse(source),
         {:ok, forms, _exports} <- codegen(ast, modname, opts) do
      compile_forms(forms)
    end
  end

  defp compile_tree(path, search_path, entry, seen) do
    abs = Path.expand(path)

    if Map.has_key?(seen, abs) do
      {:ok, seen, nil}
    else
      with {:ok, source} <- read_file(abs),
           {:ok, ast} <- parse(source) do
        modname = modname_for(abs)
        imports = collect_imports(ast)

        case compile_imports(imports, abs, search_path, entry, Map.put(seen, abs, :pending)) do
          {:error, _} = e ->
            e

          {:ok, seen} ->
            with {:ok, forms, _} <- codegen(ast, modname, main?: abs == entry),
                 {:ok, mod_atom, bin} <- compile_forms(forms) do
              {:ok, Map.put(seen, abs, {mod_atom, bin}), mod_atom}
            end
        end
      end
    end
  end

  defp compile_imports(imports, from_file, search_path, entry, seen) do
    Enum.reduce_while(imports, {:ok, seen}, fn name, {:ok, acc} ->
      case find_module_file(name, Path.dirname(from_file), search_path) do
        {:ok, file} ->
          case compile_tree(file, search_path, entry, acc) do
            {:ok, acc2, _} -> {:cont, {:ok, acc2}}
            {:error, _} = e -> {:halt, e}
          end

        :error ->
          {:halt, {:error, "cannot find module #{name} (imported from #{from_file})"}}
      end
    end)
  end

  defp collect_imports({:module, _, stmts}) do
    stmts
    |> Enum.flat_map(fn
      {:import, _, mods} ->
        Enum.map(mods, fn {dotted, _as} -> dotted |> String.split(".") |> hd() end)

      {:from, _, mod, _names} ->
        mod = String.trim_leading(mod, ".")

        if mod == "" do
          []
        else
          [mod |> String.split(".") |> hd()]
        end

      _ ->
        []
    end)
    |> Enum.uniq()
  end

  defp find_module_file(name, dir, search_path) do
    candidates = [dir | search_path] |> Enum.uniq() |> Enum.map(&Path.join(&1, name <> ".slop"))

    case Enum.find(candidates, &File.exists?/1) do
      nil -> :error
      f -> {:ok, f}
    end
  end

  defp modname_for(abs) do
    abs |> Path.basename(".slop") |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, s} -> {:ok, s}
      {:error, reason} -> {:error, "cannot read #{path}: #{inspect(reason)}"}
    end
  end

  defp parse(source) do
    case Slop.Parser.parse(source) do
      {:ok, ast} -> {:ok, ast}
      {:error, msg, _} -> {:error, "parse error: #{msg}"}
      {:error, msg} -> {:error, "parse error: #{msg}"}
    end
  end

  defp codegen(ast, modname, opts) do
    try do
      {:ok, forms, exports} = Slop.Codegen.compile_module(ast, modname, opts)
      {:ok, forms, exports}
    rescue
      e in Slop.Codegen.CompileError -> {:error, "codegen error: #{Exception.message(e)}"}
      e -> {:error, "codegen error: #{Exception.format(:error, e, __STACKTRACE__)}"}
    end
  end

  defp compile_forms(forms) do
    case :compile.forms(forms, [:from_core, :binary, :return_errors, :return_warnings]) do
      {:ok, mod, bin} -> {:ok, mod, bin}
      {:ok, mod, bin, _warnings} -> {:ok, mod, bin}
      {:error, errors, _warnings} -> {:error, "beam compile error: #{format_errors(errors)}"}
      other -> {:error, "beam compile error: #{inspect(other)}"}
    end
  end

  defp format_errors(errors) do
    for {file, errs} <- errors do
      for {line, mod, desc} <- errs do
        "#{file}:#{line}: #{mod.format_error(desc)}"
      end
    end
    |> List.flatten()
    |> Enum.join("\n")
  end

  @doc """
  Write compiled modules as .beam files into out_dir.
  mods is the map from compile_file (path => {mod, bin}); keeps only compiled tuples.
  """
  def write_beams(mods, out_dir) do
    File.mkdir_p!(out_dir)

    for {_path, {mod, bin}} <- mods do
      File.write!(Path.join(out_dir, "#{mod}.beam"), bin)
    end

    :ok
  end
end
