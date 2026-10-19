# SPDX-FileCopyrightText: 2024 simple_sat contributors <https://github.com/ash-project/simple_sat/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule SimpleSat.Bench.Error do
  @moduledoc false
  # Raised by the bench modules for anything the user has to fix (nothing
  # recorded, corrupt recording, solvers disagreeing). `mix sat.bench` turns it
  # into a Mix.raise so the message is shown without a stacktrace.
  defexception [:message]
end
