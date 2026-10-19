# SPDX-FileCopyrightText: 2024 simple_sat contributors <https://github.com/ash-project/simple_sat/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule SimpleSat.Bench.Recorder do
  @moduledoc false
  # Records every formula handed to the SAT solver while the test suite runs.
  #
  # Recording uses the BEAM call tracer on the solver entry point, so the host
  # app needs no configuration change and nothing is recompiled. A registered
  # recorder process receives the trace messages and appends to the files
  # described in `SimpleSat.Bench.Recording`.

  alias SimpleSat.Bench.Recording

  @name __MODULE__

  @doc "Starts recording until `stop/0`. Returns the traced entry points."
  @spec start() :: {:ok, [mfa()]} | {:error, String.t()}
  def start do
    case trace_targets() do
      [] ->
        {:error, "sat_bench: no SAT solver entry point is loaded, so there is nothing to record"}

      targets ->
        File.rm_rf!(Recording.dir())
        File.mkdir_p!(Recording.dir())
        calls = File.open!(Recording.calls_path(), [:write])
        formulas = File.open!(Recording.formulas_path(), [:write])

        recorder = spawn(fn -> record(calls, formulas, MapSet.new()) end)
        Process.register(recorder, @name)

        :erlang.trace(:all, true, [:call, {:tracer, recorder}])
        Enum.each(targets, &:erlang.trace_pattern(&1, true, [:global]))
        {:ok, targets}
    end
  end

  @doc "Stops recording and waits until every trace message has been written."
  @spec stop() :: :ok
  def stop do
    case Process.whereis(@name) do
      nil ->
        :ok

      recorder ->
        :erlang.trace(:all, false, [:call])
        ref = :erlang.trace_delivered(:all)

        receive do
          {:trace_delivered, :all, ^ref} -> :ok
        end

        send(recorder, {:stop, self()})

        receive do
          {@name, :stopped} -> :ok
        end
    end
  end

  @spec format_mfa(mfa()) :: String.t()
  def format_mfa({module, function, arity}), do: "#{inspect(module)}.#{function}/#{arity}"

  # Current Ash solves through Crux, whose implementation module wraps whichever
  # solver the app has; tracing it captures every solve regardless of solver.
  # Before Crux, Ash called the solver modules directly.
  @spec trace_targets() :: [mfa()]
  defp trace_targets do
    if Code.ensure_loaded?(Crux.Implementation) do
      [{Crux.Implementation, :solve_expression, 1}]
    else
      for module <- [Picosat, SimpleSat], Code.ensure_loaded?(module), do: {module, :solve, 1}
    end
  end

  @spec record(File.io_device(), File.io_device(), MapSet.t()) :: :ok
  defp record(calls, formulas, seen) do
    receive do
      {:trace, _pid, :call, {_module, _function, [cnf]}} ->
        {hash, encoded} = Recording.encode(cnf)

        if not MapSet.member?(seen, hash), do: IO.binwrite(formulas, encoded)
        IO.binwrite(calls, [hash, ?\n])

        record(calls, formulas, MapSet.put(seen, hash))

      {:stop, from} ->
        File.close(calls)
        File.close(formulas)
        send(from, {@name, :stopped})
        :ok
    end
  end
end
