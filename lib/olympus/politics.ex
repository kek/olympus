defmodule Olympus.Politics do
  @moduledoc """
  Mechanical Styx, ambrosia, Lethe and generation trials.
  After three cut epochs, proposals use fresh challenger context. A challenger
  inherits office only by winning the same sealed majority trial.
  """
  alias Olympus.Contract

  def identity(durable, god) do
    incumbent = durable.ledger[god]

    if durable.stagnation >= 3 do
      %{incumbent | memory: [], generation: incumbent.generation + 1}
    else
      incumbent
    end
  end

  def assess(contract, artifact, response, god) do
    declarations = Map.get(response, "oaths", [])

    valid =
      is_list(declarations) and length(declarations) <= 16 and
        Enum.all?(declarations, &Contract.valid_check?/1)

    oaths = if valid, do: Enum.uniq(god.oaths ++ declarations), else: god.oaths

    broken = Enum.filter(oaths, &(not Contract.holds?(&1, artifact)))

    measurement =
      cond do
        not valid or length(oaths) > 16 or :erlang.external_size(oaths) > 8192 ->
          {:error, :invalid_oath}

        broken != [] ->
          {:error, :oath_broken}

        true ->
          Contract.measure(contract, artifact)
      end

    %{
      measurement: measurement,
      oaths: if(measurement == {:error, :invalid_oath}, do: god.oaths, else: oaths),
      broken: broken
    }
  end

  def settle(ledger, result, epoch, stagnation) do
    candidates = Enum.flat_map(result.rounds, & &1.candidates)

    Map.new(ledger, fn {name, god} ->
      own = Enum.filter(candidates, &(&1.god == name))

      oaths =
        own |> Enum.flat_map(& &1.oaths) |> Kernel.++(god.oaths) |> Enum.uniq() |> Enum.take(16)

      broken = Enum.any?(own, &(&1.broken != []))
      ascended = result.winner == name and stagnation >= 3
      memory = if ascended, do: [], else: god.memory

      memory =
        (memory ++ [%{episode: result.id, status: result.status, won: result.winner == name}])
        |> Enum.take(-16)

      {name,
       %{
         god
         | memory: memory,
           oaths: oaths,
           coma_until: if(broken, do: epoch + 2, else: god.coma_until),
           generation: god.generation + if(ascended, do: 1, else: 0)
       }}
    end)
  end

  def lethe(weights) do
    Map.new(weights, fn {pair, weight} -> {pair, if(weight <= -20, do: -10, else: weight)} end)
  end
end
