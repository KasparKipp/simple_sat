# SPDX-FileCopyrightText: 2024 simple_sat contributors <https://github.com/ash-project/simple_sat/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule SimpleSat.CDCL do
  @moduledoc false

  # Conflict-driven clause learning, after MiniSat:
  #
  #   * two watched literals per clause, so propagating a literal only visits
  #     the clauses watching its negation;
  #   * on conflict, 1UIP analysis learns a clause and backjumps to the second
  #     highest decision level in it;
  #   * VSIDS branching (bump variables seen in conflicts, decay the rest) with
  #     phase saving, ties broken by the lowest variable;
  #   * Luby restarts, keeping learned clauses.
  #
  # Everything is persistent data: clauses are tuples in a map keyed by id, with
  # the two watched literals at positions 0 and 1, and the trail is a list with
  # the newest literal first.

  @restart_base 32
  @decay 0.95
  @rescale_limit 1.0e100
  @rescale_factor 1.0e-100

  defstruct clauses: %{},
            watches: %{},
            assigns: %{},
            trail: [],
            queue: [],
            level: 0,
            activity: %{},
            inc: 1.0,
            heap: nil,
            phase: %{},
            next_id: 0,
            restarts: 0,
            conflicts_left: @restart_base

  @spec solve([[integer]]) :: {:ok, [integer]} | {:error, :unsatisfiable}
  def solve(clauses) do
    # TODO: I don't think this is our use-case. Pretty sure it don't matter.
    # clauses = Enum.map(clauses, &Enum.uniq/1)

    if Enum.any?(clauses, &(&1 == [])) do
      {:error, :unsatisfiable}
    else
      vars = clauses |> List.flatten() |> Enum.map(&abs/1) |> Enum.uniq() |> Enum.sort()

      with %__MODULE__{} = state <- init(clauses, vars),
           {:sat, state} <- search(state) do
        {:ok, model(state.assigns, vars)}
      else
        _unsat -> {:error, :unsatisfiable}
      end
    end
  end

  # Every variable starts in the heap, so tautologies (dropped here) still get a
  # value. Unit clauses are assigned at level 0 rather than watched.
  defp init(clauses, vars) do
    state = %__MODULE__{heap: :gb_sets.from_list(for var <- vars, do: {0.0, -var})}

    clauses
    |> Enum.reject(&tautology?/1)
    |> Enum.reduce_while(state, fn
      [literal], state ->
        case value(state.assigns, literal) do
          nil -> {:cont, enqueue(state, literal, nil)}
          true -> {:cont, state}
          false -> {:halt, :conflict}
        end

      clause, state ->
        {:cont, add_clause(state, clause)}
    end)
  end

  defp tautology?(clause), do: Enum.any?(clause, &(-&1 in clause))

  defp search(state) do
    case propagate(state) do
      {:ok, state} ->
        case decide(state) do
          :sat -> {:sat, state}
          state -> search(state)
        end

      {:conflict, _id, %{level: 0}} ->
        :unsat

      {:conflict, id, state} ->
        state |> learn(id) |> maybe_restart() |> search()
    end
  end

  # ----------------------------------------------------------------------
  # Assignment
  # ----------------------------------------------------------------------

  defp value(assigns, literal) do
    case Map.fetch(assigns, abs(literal)) do
      {:ok, {value, _level, _reason}} -> value == literal > 0
      :error -> nil
    end
  end

  defp enqueue(state, literal, reason) do
    %{
      state
      | assigns: Map.put(state.assigns, abs(literal), {literal > 0, state.level, reason}),
        trail: [literal | state.trail],
        queue: [literal | state.queue]
    }
  end

  defp add_clause(state, [first, second | _] = literals) do
    id = state.next_id

    watches =
      state.watches
      |> add_watch(first, id)
      |> add_watch(second, id)

    %{
      state
      | clauses: Map.put(state.clauses, id, List.to_tuple(literals)),
        watches: watches,
        next_id: id + 1
    }
  end

  defp add_watch(watches, literal, id), do: Map.update(watches, literal, [id], &[id | &1])

  # ----------------------------------------------------------------------
  # Propagation (two watched literals)
  # ----------------------------------------------------------------------

  defp propagate(%{queue: []} = state), do: {:ok, state}

  defp propagate(%{queue: [literal | rest]} = state) do
    falsified = -literal
    {ids, watches} = Map.pop(state.watches, falsified, [])
    visit(ids, falsified, %{state | queue: rest, watches: watches}, [])
  end

  # Clauses that keep watching the falsified literal are collected in `kept`.
  # New watches only ever go to non-false literals, so nothing else is added
  # to the falsified literal's list while we walk it.
  defp visit([], falsified, state, kept) do
    propagate(%{state | watches: Map.put(state.watches, falsified, kept)})
  end

  defp visit([id | ids], falsified, state, kept) do
    case update_watch(state, id, falsified) do
      {:keep, state} ->
        visit(ids, falsified, state, [id | kept])

      {:moved, state} ->
        visit(ids, falsified, state, kept)

      :conflict ->
        watches = Map.put(state.watches, falsified, ids ++ [id | kept])
        {:conflict, id, %{state | watches: watches}}
    end
  end

  defp update_watch(state, id, falsified) do
    clause = Map.fetch!(state.clauses, id)
    other = if elem(clause, 0) == falsified, do: elem(clause, 1), else: elem(clause, 0)

    case value(state.assigns, other) do
      true ->
        {:keep, state}

      other_value ->
        case replacement(clause, state.assigns, 2) do
          nil when other_value == nil -> {:keep, enqueue(state, other, id)}
          nil -> :conflict
          index -> {:moved, move_watch(state, id, clause, other, index, falsified)}
        end
    end
  end

  # Index of the first literal past the watched pair that is not false.
  defp replacement(clause, _assigns, index) when index >= tuple_size(clause), do: nil

  defp replacement(clause, assigns, index) do
    case value(assigns, elem(clause, index)) do
      false -> replacement(clause, assigns, index + 1)
      _true_or_unassigned -> index
    end
  end

  # The replacement becomes the second watched literal and the falsified one
  # takes its old position.
  defp move_watch(state, id, clause, other, index, falsified) do
    literal = elem(clause, index)

    clause =
      clause
      |> put_elem(0, other)
      |> put_elem(1, literal)
      |> put_elem(index, falsified)

    %{
      state
      | clauses: Map.put(state.clauses, id, clause),
        watches: add_watch(state.watches, literal, id)
    }
  end

  # ----------------------------------------------------------------------
  # Conflict analysis (first UIP), learning and backjumping
  # ----------------------------------------------------------------------

  defp learn(state, conflict_id) do
    {[asserting | rest], state} = analyze(state, conflict_id)
    state = decay(state)

    case rest do
      [] ->
        state |> backjump(0) |> enqueue(asserting, nil)

      _ ->
        # Watch the literal from the highest remaining level: it is the last
        # one to become unassigned, so the watch stays valid after backjumping.
        second = Enum.max_by(rest, &level(state, &1))
        literals = [asserting, second | List.delete(rest, second)]
        state = backjump(state, level(state, second))
        id = state.next_id

        state
        |> add_clause(literals)
        |> enqueue(asserting, id)
    end
  end

  # Resolves the conflict clause with the reasons of current-level literals,
  # newest first, until one current-level literal (the first UIP) remains.
  # Returns the learned clause with the negated UIP first.
  defp analyze(state, conflict_id) do
    conflict = state.clauses |> Map.fetch!(conflict_id) |> Tuple.to_list()
    {seen, pending, learned, state} = absorb(conflict, state, MapSet.new(), 0, [])
    find_uip(state.trail, state, seen, pending, learned)
  end

  defp find_uip([literal | trail], state, seen, pending, learned) do
    var = abs(literal)

    cond do
      not MapSet.member?(seen, var) ->
        find_uip(trail, state, seen, pending, learned)

      pending == 1 ->
        {[-literal | learned], state}

      true ->
        {_value, _level, reason} = Map.fetch!(state.assigns, var)
        reason_literals = state.clauses |> Map.fetch!(reason) |> Tuple.to_list()

        {seen, pending, learned, state} =
          absorb(reason_literals, state, seen, pending - 1, learned)

        find_uip(trail, state, seen, pending, learned)
    end
  end

  # Level 0 literals are false for good and are dropped from learned clauses.
  # Current-level literals are counted for resolution; lower-level ones go
  # straight into the learned clause.
  defp absorb(literals, state, seen, pending, learned) do
    Enum.reduce(literals, {seen, pending, learned, state}, fn literal, acc ->
      {seen, pending, learned, state} = acc
      var = abs(literal)
      literal_level = level(state, literal)

      cond do
        literal_level == 0 or MapSet.member?(seen, var) ->
          acc

        literal_level == state.level ->
          {MapSet.put(seen, var), pending + 1, learned, bump(state, var)}

        true ->
          {MapSet.put(seen, var), pending, [literal | learned], bump(state, var)}
      end
    end)
  end

  defp level(state, literal) do
    {_value, level, _reason} = Map.fetch!(state.assigns, abs(literal))
    level
  end

  defp backjump(%{level: level} = state, target) when level <= target, do: state

  defp backjump(state, target) do
    %{undo(state, target) | queue: [], level: target}
  end

  defp undo(%{trail: [literal | trail]} = state, target) do
    var = abs(literal)
    {value, level, _reason} = Map.fetch!(state.assigns, var)

    if level > target do
      undo(
        %{
          state
          | trail: trail,
            assigns: Map.delete(state.assigns, var),
            phase: Map.put(state.phase, var, value),
            heap: :gb_sets.add({activity(state, var), -var}, state.heap)
        },
        target
      )
    else
      state
    end
  end

  defp undo(state, _target), do: state

  defp maybe_restart(%{conflicts_left: 1} = state) do
    restarts = state.restarts + 1

    %{
      backjump(state, 0)
      | restarts: restarts,
        conflicts_left: luby(restarts + 1) * @restart_base
    }
  end

  defp maybe_restart(state), do: %{state | conflicts_left: state.conflicts_left - 1}

  # 1, 1, 2, 1, 1, 2, 4, 1, 1, 2, 1, 1, 2, 4, 8, ...
  defp luby(i) do
    k = luby_block(i, 1)

    if Bitwise.bsl(1, k) - 1 == i do
      Bitwise.bsl(1, k - 1)
    else
      luby(i - Bitwise.bsl(1, k - 1) + 1)
    end
  end

  defp luby_block(i, k) do
    if Bitwise.bsl(1, k) - 1 >= i, do: k, else: luby_block(i, k + 1)
  end

  # ----------------------------------------------------------------------
  # Branching (VSIDS with phase saving)
  # ----------------------------------------------------------------------

  # The heap holds {activity, -var}, so the largest entry is the most active
  # variable, lowest variable first on ties. Assigned variables are skipped
  # lazily and put back when backjumping unassigns them.
  defp decide(state) do
    case pick(state.heap, state.assigns) do
      :none ->
        :sat

      {var, heap} ->
        literal = if Map.get(state.phase, var, true), do: var, else: -var
        enqueue(%{state | heap: heap, level: state.level + 1}, literal, nil)
    end
  end

  defp pick(heap, assigns) do
    if :gb_sets.is_empty(heap) do
      :none
    else
      {{_activity, negated}, heap} = :gb_sets.take_largest(heap)
      var = -negated
      if Map.has_key?(assigns, var), do: pick(heap, assigns), else: {var, heap}
    end
  end

  defp activity(state, var), do: Map.get(state.activity, var, 0.0)

  defp bump(state, var) do
    old = activity(state, var)
    new = old + state.inc
    heap = state.heap

    heap =
      if :gb_sets.is_member({old, -var}, heap) do
        :gb_sets.add({new, -var}, :gb_sets.delete({old, -var}, heap))
      else
        heap
      end

    %{state | activity: Map.put(state.activity, var, new), heap: heap}
  end

  # Growing the increment instead of shrinking every activity; rescale
  # everything once it gets too large to stay precise.
  defp decay(state) do
    inc = state.inc / @decay

    if inc > @rescale_limit do
      activity = Map.new(state.activity, fn {var, a} -> {var, a * @rescale_factor} end)

      heap =
        :gb_sets.from_list(
          for {a, n} <- :gb_sets.to_list(state.heap), do: {a * @rescale_factor, n}
        )

      %{state | activity: activity, heap: heap, inc: inc * @rescale_factor}
    else
      %{state | inc: inc}
    end
  end

  defp model(assigns, vars) do
    for var <- vars do
      case Map.fetch!(assigns, var) do
        {true, _level, _reason} -> var
        {false, _level, _reason} -> -var
      end
    end
  end
end
