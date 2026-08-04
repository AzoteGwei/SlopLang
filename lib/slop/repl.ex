defmodule Slop.Repl do
  @moduledoc """
  Interactive REPL (`slopc repl`).

  Reads logical lines (multi-line blocks get `...` continuation prompts
  until a blank line), evaluates expressions and prints their repr,
  executes statements, all against a shared dynamic context ("repl")
  whose names persist across lines. Piped stdin runs without prompts.
  On a TTY the terminal is put in raw mode so Ctrl-C interrupts the
  current line (KeyboardInterrupt) instead of killing the VM, Ctrl-D at
  an empty prompt exits, and up/down arrows walk the history.
  """

  @prompt ">>> "
  @cont "... "
  @ctx "repl"

  def run do
    if tty?() do
      run_tty()
    else
      run_pipe()
    end
  end

  # a spawned `test -t 0` would check the child's stdin, not ours — look
  # at what the VM's own fd 0 points at instead
  defp tty? do
    case tty_dev() do
      nil -> false
      _ -> true
    end
  end

  defp tty_dev do
    case File.read_link("/proc/self/fd/0") do
      {:ok, "/dev/pts/" <> _ = path} -> path
      {:ok, "/dev/tty" <> _ = path} -> path
      _ -> nil
    end
  end

  defp banner do
    otp = :erlang.system_info(:otp_release) |> to_string()
    "SlopLang 0.1.0 (BEAM/OTP #{otp})"
  end

  # ------------------------------------------------------------------
  # shared: assemble logical lines and evaluate them
  # ------------------------------------------------------------------

  # read is a fun(prompt :: String.t) -> String.t | :eof
  defp loop(read) do
    case collect(read) do
      :eof ->
        :ok

      {:input, buf} ->
        execute(buf)
        loop(read)

      {:error, line, msg} ->
        IO.puts(:stderr, "SyntaxError: line #{line}: #{msg}")
        loop(read)
    end
  end

  defp collect(read) do
    case read.(@prompt) do
      :eof ->
        :eof

      line ->
        case Slop.Parser.parse(line) do
          {:ok, _} ->
            {:input, line}

          {:error, _, msg} ->
            if incomplete?(msg) do
              cont_loop(read, line, compound?(line))
            else
              {:error, 1, msg}
            end
        end
    end
  end

  defp cont_loop(read, buf, compound) do
    case read.(@cont) do
      :eof ->
        finish_block(buf)

      line ->
        if String.trim(line) == "" do
          finish_block(buf)
        else
          buf = buf <> line

          if compound do
            cont_loop(read, buf, true)
          else
            case Slop.Parser.parse(buf) do
              {:ok, _} -> {:input, buf}
              {:error, _, _} -> cont_loop(read, buf, false)
            end
          end
        end
    end
  end

  defp finish_block(buf) do
    case Slop.Parser.parse(buf) do
      {:ok, _} -> {:input, buf}
      {:error, line, msg} -> {:error, line, msg}
    end
  end

  defp incomplete?(msg), do: msg =~ "eof" or msg =~ "unexpected newline"

  # compound statements (first line ends with ':') keep collecting until
  # a blank line; bracket continuations run as soon as they parse
  defp compound?(line), do: line |> String.trim_trailing() |> String.ends_with?(":")

  defp execute(buf) do
    case Slop.Parser.parse_expression(buf) do
      {:ok, _} ->
        case guarded(fn -> :slop_rt.dyn_eval(buf, @ctx) end) do
          {:ok, nil} -> :ok
          {:ok, v} -> IO.puts(:slop_rt.to_repr(v))
          :interrupted -> :ok
          {:error, _, _} = e -> report(e)
        end

      {:error, _, _} ->
        case guarded(fn -> :slop_rt.dyn_exec(buf, @ctx) end) do
          {:ok, _} -> :ok
          :interrupted -> :ok
          {:error, _, _} = e -> report(e)
        end
    end
  end

  defp report({:error, class, msg}) do
    IO.puts(:stderr, "#{class}: #{msg}")
  end

  # run f, catching SlopLang exceptions; in TTY mode a Ctrl-C byte from
  # the reader process kills the task and reports KeyboardInterrupt
  defp guarded(f) do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {self(), safe(f)}) end)
    await(pid, ref)
  end

  defp safe(f) do
    {:ok, f.()}
  catch
    {:"$slop_exc", class, inst} -> {:error, class, exc_msg(inst)}
    :exit, reason -> {:error, "Exit", inspect(reason)}
  rescue
    e -> {:error, "Error", Exception.message(e)}
  end

  defp exc_msg(inst) when is_map(inst) do
    case Map.get(inst, :args) do
      [m | _] -> to_string(m)
      _ -> ""
    end
  end

  defp exc_msg(other), do: inspect(other)

  # default (piped) mode: wait for the executor message only
  defp await(pid, ref) do
    receive do
      {^pid, res} ->
        Process.demonitor(ref, [:flush])
        res

      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, "Error", "executor died: #{inspect(reason)}"}
    end
  end

  # ------------------------------------------------------------------
  # piped stdin: no prompts, line-based reads
  # ------------------------------------------------------------------

  defp run_pipe do
    stream = IO.stream(:stdio, :line)

    read = fn _prompt ->
      case Enum.take(stream, 1) do
        [line] -> line
        [] -> :eof
      end
    end

    loop(read)
  end

  # ------------------------------------------------------------------
  # TTY mode: raw-mode char reader, prompts, history, Ctrl-C handling
  # ------------------------------------------------------------------

  defp run_tty do
    dev = tty_dev()
    {saved, 0} = System.cmd("stty", ["-F", dev, "-g"])
    saved = String.trim(saved)
    restore = fn -> System.cmd("stty", ["-F", dev, saved]) end
    System.at_exit(fn _ -> restore.() end)
    System.cmd("stty", ["-F", dev, "-icanon", "-echo", "-isig"])

    IO.puts(banner())
    IO.puts("Type Ctrl-D (EOF) to exit, Ctrl-C to interrupt the current line.")

    repl = self()
    reader = spawn_link(fn -> reader_loop(repl) end)

    try do
      tty_loop(reader, [])
    after
      restore.()
    end
  end

  defp reader_loop(repl) do
    case IO.getn(:stdio, "", 1) do
      :eof ->
        send(repl, {:char, <<4>>})

      c when is_binary(c) ->
        send(repl, {:char, c})
        reader_loop(repl)
    end
  end

  # char-driven line collection; returns {:line, s} | :eof
  defp tty_loop(reader, history) do
    case tty_assemble(reader, history) do
      :eof ->
        IO.write("\n")

      {:error, l, m} ->
        IO.puts(:stderr, "SyntaxError: line #{l}: #{m}")
        tty_loop(reader, history)

      {:input, buf} ->
        run_tty_input(reader, buf)
        tty_loop(reader, [buf | history])
    end
  end

  defp tty_assemble(reader, history) do
    case tty_line(reader, @prompt, "", history, nil) do
      :eof ->
        :eof

      {:line, line} ->
        buf = line <> "\n"

        case Slop.Parser.parse(buf) do
          {:ok, _} ->
            {:input, buf}

          {:error, _, msg} ->
            if incomplete?(msg) do
              tty_cont(reader, buf, compound?(buf), history)
            else
              {:error, 1, msg}
            end
        end
    end
  end

  defp run_tty_input(reader, buf) do
    case Slop.Parser.parse_expression(buf) do
      {:ok, _} -> tty_exec(fn -> print_value(:slop_rt.dyn_eval(buf, @ctx)) end)
      {:error, _, _} -> tty_exec(fn -> :slop_rt.dyn_exec(buf, @ctx) end)
    end
  end

  defp print_value(nil), do: :ok
  defp print_value(v), do: IO.puts(:slop_rt.to_repr(v))

  defp tty_exec(f) do
    parent = self()
    {pid, ref} = spawn_monitor(fn -> send(parent, {self(), safe(f)}) end)

    # selective receive: chars typed during execution (except Ctrl-C,
    # byte 3) stay queued in the mailbox for the next line read
    receive do
      {^pid, res} ->
        Process.demonitor(ref, [:flush])

        case res do
          {:ok, _} -> :ok
          {:error, class, msg} -> IO.puts(:stderr, "#{class}: #{msg}")
        end

      {:DOWN, ^ref, :process, ^pid, reason} ->
        IO.puts(:stderr, "Error: executor died: #{inspect(reason)}")

      {:char, <<3>>} ->
        Process.exit(pid, :kill)
        Process.demonitor(ref, [:flush])
        IO.puts("^C\nKeyboardInterrupt")
    end
  end

  defp tty_cont(reader, buf, compound, history) do
    case tty_line(reader, @cont, "", history, nil) do
      :eof ->
        finish_block(buf)

      {:line, line} ->
        if String.trim(line) == "" do
          finish_block(buf)
        else
          buf = buf <> line <> "\n"

          if compound do
            tty_cont(reader, buf, true, history)
          else
            case Slop.Parser.parse(buf) do
              {:ok, _} -> {:input, buf}
              {:error, _, _} -> tty_cont(reader, buf, false, history)
            end
          end
        end
    end
  end

  # read one raw-mode line: handles backspace, Ctrl-C (abort line),
  # Ctrl-D (EOF on empty buffer), up/down history, escape swallowing
  defp tty_line(reader, prompt, buf, history, hidx) do
    IO.write(prompt)

    case next_char(reader) do
      :eof ->
        :eof

      {:char, <<4>>} ->
        if buf == "", do: :eof, else: tty_line(reader, "", buf, history, hidx)

      {:char, <<3>>} ->
        IO.write("^C\n")
        tty_line(reader, prompt, "", history, nil)

      {:char, c} when c in ["\r", "\n"] ->
        IO.write("\n")
        {:line, buf}

      {:char, c} when c in ["\d", "\b"] ->
        if buf == "" do
          tty_line(reader, "", buf, history, hidx)
        else
          IO.write("\b \b")
          tty_line(reader, "", String.slice(buf, 0..-2//1), history, hidx)
        end

      {:char, <<27>>} ->
        case read_escape(reader) do
          :up -> hist_move(reader, prompt, buf, history, hidx, -1)
          :down -> hist_move(reader, prompt, buf, history, hidx, 1)
          :other -> tty_line(reader, "", buf, history, hidx)
        end

      {:char, c} ->
        IO.write(c)
        tty_line(reader, "", buf <> c, history, hidx)
    end
  end

  defp next_char(_reader) do
    receive do
      {:char, c} -> {:char, c}
    end
  end

  defp read_escape(_reader) do
    receive do
      {:char, "["} ->
        receive do
          {:char, "A"} -> :up
          {:char, "B"} -> :down
          {:char, _} -> :other
        end

      {:char, _} ->
        :other
    after
      50 -> :other
    end
  end

  defp hist_move(reader, prompt, buf, history, hidx, delta) do
    len = length(history)

    new_idx =
      case {hidx, delta} do
        {nil, -1} -> if len > 0, do: 0, else: nil
        {nil, 1} -> nil
        {i, -1} -> if i + 1 < len, do: i + 1, else: i
        {i, 1} -> if i > 0, do: i - 1, else: nil
      end

    new_buf =
      case new_idx do
        nil -> ""
        i -> history |> Enum.at(i) |> String.trim_trailing("\n")
      end

    IO.write("\r" <> String.duplicate(" ", String.length(prompt) + String.length(buf)) <> "\r")
    IO.write(prompt <> new_buf)
    tty_line(reader, "", new_buf, history, new_idx)
  end
end
