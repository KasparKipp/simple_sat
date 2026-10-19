# SPDX-FileCopyrightText: 2024 simple_sat contributors <https://github.com/ash-project/simple_sat/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule SimpleSat.Bench.Recording do
  @moduledoc false
  # The on-disk recording, in `sat_bench/` under the current directory:
  #
  #   calls.txt     one formula hash per solver call, in call order
  #   formulas.etf  every distinct formula once, as <<size::32, term_to_binary(cnf)>>
  #   report.txt    the last report
  #
  # Each distinct formula is stored once and every call is one line, so the
  # replayed workload keeps its real mix and order without storing duplicates.

  alias SimpleSat.Bench.Error

  @dir "sat_bench"

  @type hash :: String.t()
  @type cnf :: [[integer()]]

  @spec dir() :: Path.t()
  def dir, do: @dir

  @spec calls_path() :: Path.t()
  def calls_path, do: Path.join(@dir, "calls.txt")

  @spec formulas_path() :: Path.t()
  def formulas_path, do: Path.join(@dir, "formulas.etf")

  @spec report_path() :: Path.t()
  def report_path, do: Path.join(@dir, "report.txt")

  # The hash of a formula is taken over its ETF encoding, which is also what
  # gets stored, so recording and loading agree by construction.
  @spec hash(binary()) :: hash()
  def hash(binary),
    do: :sha256 |> :crypto.hash(binary) |> Base.encode16(case: :lower) |> binary_part(0, 16)

  @spec encode(cnf()) :: {hash(), iodata()}
  def encode(cnf) do
    binary = :erlang.term_to_binary(cnf)
    {hash(binary), [<<byte_size(binary)::32>>, binary]}
  end

  @doc "Loads the recording: the calls in order, and the distinct formulas by hash."
  @spec load() :: {[hash()], %{hash() => cnf()}}
  def load do
    calls = read_calls()

    if calls == [] do
      raise Error,
        message: """
        sat_bench: nothing recorded in #{@dir}/. Either the tests never reached code
        that needed the SAT solver, or `mix sat.bench` hasn't run yet.
        """
    end

    formulas = decode(File.read!(formulas_path()), %{})

    case Enum.reject(Enum.uniq(calls), &Map.has_key?(formulas, &1)) do
      [] ->
        {calls, formulas}

      missing ->
        raise Error,
          message: """
          sat_bench: #{length(missing)} formulas listed in #{calls_path()} are missing
          from #{formulas_path()} (first: #{hd(missing)}). Record again with `mix sat.bench`.
          """
    end
  end

  defp read_calls do
    if File.exists?(calls_path()) and File.exists?(formulas_path()),
      do: calls_path() |> File.read!() |> String.split("\n", trim: true),
      else: []
  end

  defp decode(<<size::32, binary::binary-size(size), rest::binary>>, acc),
    do: decode(rest, Map.put(acc, hash(binary), :erlang.binary_to_term(binary)))

  defp decode(<<>>, acc), do: acc

  defp decode(_trailing, _acc) do
    raise Error,
      message: "sat_bench: #{formulas_path()} is truncated or corrupt; record again"
  end
end
