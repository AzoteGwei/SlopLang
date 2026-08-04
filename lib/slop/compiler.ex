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
    search_path = Keyword.get(opts, :search_path, default_search_path(path))
    entry = Path.expand(path)
    entry_opts = Keyword.take(opts, [:dynamic, :globals_mod])

    case compile_tree(entry, search_path, entry, %{}, entry_opts) do
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

  # the toolchain's bundled sloplib/ (stdlib modules get namespaced atoms
  # so they can never shadow OTP modules like :math or :os in the code
  # server)
  def toolchain_lib do
    try do
      Path.join(Path.dirname(to_string(:escript.script_name())), "sloplib")
      |> Path.expand()
    rescue
      _ -> nil
    catch
      _, _ -> nil
    end
  end

  # import resolution: the importing file's directory, then SLOP_PATH
  # (colon-separated), then the toolchain's bundled sloplib/
  defp default_search_path(path) do
    env =
      case System.get_env("SLOP_PATH") do
        nil -> []
        s -> String.split(s, ":", trim: true)
      end

    toolchain_lib =
      case toolchain_lib() do
        nil -> []
        lib -> [lib]
      end

    ([Path.dirname(path)] ++ env ++ toolchain_lib)
    |> Enum.uniq()
  end

  defp compile_tree(path, search_path, entry, seen, entry_opts \\ []) do
    abs = Path.expand(path)

    if Map.has_key?(seen, abs) do
      {:ok, seen, nil}
    else
      with {:ok, source} <- read_file(abs),
           {:ok, ast} <- parse(source) do
        modname = modname_for(abs)
        imports = collect_imports(ast)

        case compile_imports(imports, abs, search_path, entry, Map.put(seen, abs, :pending), entry_opts) do
          {:error, _} = e ->
            e

          {:ok, seen, mod_map} ->
            extra = if abs == entry, do: entry_opts, else: []

            with {:ok, forms, _} <- codegen(ast, modname, [main?: abs == entry, mod_map: mod_map] ++ extra),
                 {:ok, mod_atom, bin} <- compile_forms(forms) do
              {:ok, Map.put(seen, abs, {mod_atom, bin}), mod_atom}
            end
        end
      end
    end
  end

  defp foreign?(path),
    do: String.starts_with?(path, "erlang.") or String.starts_with?(path, "elixir.")

  defp compile_imports(imports, from_file, search_path, entry, seen, entry_opts \\ []) do
    Enum.reduce_while(imports, {:ok, seen, %{}}, fn name, {:ok, acc, mod_map} ->
      case find_module_file(name, Path.dirname(from_file), search_path) do
        {:ok, file} ->
          case compile_tree(file, search_path, entry, acc, entry_opts) do
            {:ok, acc2, _} ->
              {:cont, {:ok, acc2, Map.put(mod_map, name, modname_for(Path.expand(file)))}}

            {:error, _} = e ->
              {:halt, e}
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
        mods
        |> Enum.reject(fn {dotted, _as} -> foreign?(dotted) end)
        |> Enum.map(fn {dotted, _as} -> dotted |> String.split(".") |> hd() end)

      {:from, _, mod, _names} ->
        mod = String.trim_leading(mod, ".")

        if mod == "" or foreign?(mod) do
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
    base = abs |> Path.basename(".slop") |> String.replace(~r/[^a-zA-Z0-9_]/, "_")

    case toolchain_lib() do
      nil ->
        base

      lib ->
        if Path.dirname(abs) == lib do
          "slop$" <> base
        else
          base
        end
    end
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
      {:error, line, msg} when is_integer(line) -> {:error, "parse error: line #{line}: #{msg}"}
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
