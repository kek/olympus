defmodule Olympus.Fate do
  @moduledoc """
  The non-LLM authority. One serialized writer per realm; there is no override,
  force-merge, test-edit, favor-edit, or human approval operation.
  """
  use GenServer
  alias Olympus.{Contract, God, Journal}

  def start_link(opts) do
    path = opts |> Keyword.fetch!(:journal) |> Path.expand()

    GenServer.start_link(__MODULE__, Keyword.put(opts, :journal, path),
      name: {:global, {__MODULE__, path}}
    )
  end

  def pray(fate, prayer), do: GenServer.call(fate, {:pray, prayer}, :infinity)
  def status(fate), do: GenServer.call(fate, :status)
  def events(fate), do: GenServer.call(fate, :events)
  def epic(fate), do: events(fate) |> Olympus.Homer.render()

  @impl true
  def init(opts) do
    path = Keyword.fetch!(opts, :journal)

    with {:ok, journal, events} <- Journal.open(path) do
      ledger =
        Map.new(
          God.names(),
          &{&1, %{favor: 100, coma_until: 0, memory: [], generation: 0, oaths: []}}
        )

      initial = %{
        epoch: 0,
        stagnation: 0,
        ledger: ledger,
        relationships: %{},
        episodes: %{},
        pending: nil,
        champion: nil
      }

      durable =
        Enum.reduce(events, initial, fn event, prior ->
          snapshot = event.data.state

          episodes =
            case Map.get(event.data, :result) do
              nil -> prior.episodes
              result -> Map.put(prior.episodes, result.id, result)
            end

          Map.put(snapshot, :episodes, episodes)
        end)

      state = %{
        journal: journal,
        events: events,
        durable: durable,
        realm: path,
        adapter: Keyword.fetch!(opts, :adapter),
        adapter_opts: Keyword.get(opts, :adapter_opts, []),
        contenders: Keyword.get(opts, :contenders, ~w(athena ares hephaestus))
      }

      if valid_contenders?(state.contenders) do
        Enum.each(God.names(), fn name ->
          case DynamicSupervisor.start_child(Olympus.Pantheon, {God, {path, name}}) do
            {:ok, _} -> :ok
            {:error, {:already_started, _}} -> :ok
          end
        end)

        # A sealed but unfinished epoch never silently reruns on restart.
        state =
          if durable.pending do
            pending = durable.pending

            terminal = %{
              id: pending.id,
              digest: pending.digest,
              status: :cut,
              reason: :restart,
              winner: nil,
              rounds: [],
              spent: pending.reserved
            }

            finish(state, terminal)
          else
            state
          end

        {:ok, state}
      else
        Journal.close(journal)
        {:stop, :invalid_contenders}
      end
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  defp valid_contenders?(names),
    do:
      is_list(names) and length(names) >= 2 and
        length(Enum.uniq(names)) == length(names) and Enum.all?(names, &(&1 in God.names()))

  @impl true
  def handle_call(:status, _, state), do: {:reply, state.durable, state}
  def handle_call(:events, _, state), do: {:reply, state.events, state}

  def handle_call({:pray, prayer}, _, state) do
    with {:ok, contract} <- Contract.compile(prayer),
         false <- Map.has_key?(state.durable.episodes, contract.id),
         :ok <- evidence_budget(contract, state.contenders) do
      epoch = state.durable.epoch + 1
      reserved = allocate(state.durable.ledger, contract.tokens, epoch)

      pending = %{
        id: contract.id,
        digest: contract.digest,
        contract: contract,
        reserved: reserved
      }

      durable = %{state.durable | epoch: epoch, pending: pending}
      state = persist(state, :thread_spun, %{state: durable, contract: contract})

      result = contest(state, contract, reserved)
      state = finish(state, result)
      {:reply, {:ok, result}, state}
    else
      true -> {:reply, {:error, :episode_exists}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp evidence_budget(contract, contenders) do
    if contract.rounds * length(contenders) * contract.max_bytes <= 1_048_576,
      do: :ok,
      else: {:error, :evidence_budget}
  end

  defp allocate(ledger, tokens, epoch) do
    eligible =
      Enum.filter(ledger, fn {_, g} -> g.coma_until < epoch and g.favor > 0 end) |> Enum.sort()

    total = Enum.reduce(eligible, 0, fn {_, g}, n -> n + g.favor end)

    if total == 0 do
      Map.new(God.names(), &{&1, 0})
    else
      base = Map.new(eligible, fn {name, g} -> {name, div(tokens * g.favor, total)} end)
      remainder = tokens - Enum.sum(Map.values(base))
      bonuses = eligible |> Enum.take(remainder) |> Enum.map(&elem(&1, 0))

      Map.new(God.names(), fn name ->
        {name, Map.get(base, name, 0) + if(name in bonuses, do: 1, else: 0)}
      end)
    end
  end

  defp contest(state, contract, reserved) do
    deadline = now() + contract.timeout_ms

    initial = %{
      rounds: [],
      wins: %{},
      best: %{},
      remaining: reserved,
      oaths: Map.new(state.durable.ledger, fn {name, g} -> {name, g.oaths} end),
      disqualified: MapSet.new(),
      relationships: state.durable.relationships
    }

    result =
      Enum.reduce_while(1..contract.rounds, initial, fn round, acc ->
        if now() >= deadline do
          {:halt, acc}
        else
          {outcomes, acc} = proposals(state, contract, reserved, acc, deadline)
          {outcomes, acc} = reviews(state, contract, reserved, outcomes, acc, deadline)

          candidates =
            Enum.filter(
              outcomes,
              &(match?({:ok, _}, &1.measurement) and not MapSet.member?(acc.disqualified, &1.god))
            )

          ranked = Enum.sort_by(candidates, fn c -> {-elem(c.measurement, 1), c.god} end)
          winner = List.first(ranked)
          wins = if winner, do: Map.update(acc.wins, winner.god, 1, &(&1 + 1)), else: acc.wins

          best =
            if winner,
              do:
                Map.update(acc.best, winner.god, winner, fn old ->
                  if elem(winner.measurement, 1) > elem(old.measurement, 1), do: winner, else: old
                end),
              else: acc.best

          record = %{round: round, winner: winner && winner.god, candidates: outcomes}
          acc = %{acc | rounds: acc.rounds ++ [record], wins: wins, best: best}

          if winner && wins[winner.god] > div(contract.rounds, 2),
            do: {:halt, acc},
            else: {:cont, acc}
        end
      end)

    winner =
      result.wins
      |> Enum.filter(fn {_, n} -> n > div(contract.rounds, 2) end)
      |> Enum.sort()
      |> List.first()

    name = if winner, do: elem(winner, 0)
    artifact = if name, do: result.best[name].artifact
    sponsor = if name, do: sponsor(state, name, reviewer(state, name, result.relationships))

    # The final gate is evaluated again, never inferred from a vote or summary.
    harmonious =
      name != nil and sponsor != nil and now() < deadline and
        match?({:ok, _}, Contract.measure(contract, artifact)) and
        Enum.all?(result.oaths[name], &Contract.holds?(&1, artifact)) and now() < deadline

    %{
      id: contract.id,
      digest: contract.digest,
      status: if(harmonious, do: :harmonious, else: :cut),
      reason: if(harmonious, do: :fate_satisfied, else: :no_majority_or_deadline),
      winner: if(harmonious, do: name),
      artifact: if(harmonious, do: artifact),
      sponsor: if(harmonious, do: sponsor),
      rounds: result.rounds,
      relationships: result.relationships,
      spent: Map.new(reserved, fn {god, budget} -> {god, budget - result.remaining[god]} end)
    }
  end

  defp proposals(state, contract, reserved, acc, deadline) do
    {jobs, acc} =
      Enum.map_reduce(state.contenders, acc, fn god, acc ->
        {budget, acc} = reserve(acc, reserved, god, contract.rounds)
        request = request(state, contract, god, budget, deadline, :propose)
        {{god, launch(state, request, budget)}, acc}
      end)

    {outcomes, acc} =
      Enum.map_reduce(jobs, acc, fn {god, job}, acc ->
        response = await(job, deadline, contract.max_bytes)

        artifact =
          case response do
            {:ok, %{"artifact" => a}} -> a
            _ -> nil
          end

        assessment =
          case response do
            {:ok, %{"artifact" => _} = body} ->
              Olympus.Politics.assess(contract, artifact, body, %{
                state.durable.ledger[god]
                | oaths: acc.oaths[god]
              })

            _ ->
              %{measurement: {:error, :invalid_proposal}, oaths: [], broken: []}
          end

        disqualified =
          if assessment.broken != [],
            do: MapSet.put(acc.disqualified, god),
            else: acc.disqualified

        acc = %{
          acc
          | oaths: Map.put(acc.oaths, god, Enum.uniq(acc.oaths[god] ++ assessment.oaths)),
            disqualified: disqualified
        }

        {Map.merge(assessment, %{god: god, artifact: artifact, review: nil}), acc}
      end)

    {outcomes, acc}
  end

  defp reviews(state, contract, reserved, outcomes, acc, deadline) do
    Enum.map_reduce(outcomes, acc, fn candidate, acc ->
      enemy = reviewer(state, candidate.god, acc.relationships)
      {budget, acc} = reserve(acc, reserved, enemy, contract.rounds)

      req =
        request(state, contract, enemy, budget, deadline, :review)
        |> Map.put(:artifact, candidate.artifact)

      response = launch(state, req, budget) |> await(deadline, contract.max_bytes)

      objections =
        case response do
          {:ok, %{"objections" => indexes}} when is_list(indexes) ->
            indexes
            |> Enum.filter(&(is_integer(&1) and &1 >= 0 and &1 < length(contract.checks)))
            |> Enum.uniq()

          _ ->
            []
        end

      verified =
        Enum.filter(objections, fn index ->
          not Contract.holds?(Enum.at(contract.checks, index), candidate.artifact)
        end)

      key = {enemy, candidate.god}

      weights =
        if verified == [],
          do: acc.relationships,
          else: Map.update(acc.relationships, key, -1, &max(&1 - 1, -100))

      review = %{reviewer: enemy, alleged: objections, verified: verified}
      {%{candidate | review: review}, %{acc | relationships: weights}}
    end)
  end

  defp reviewer(state, author, weights) do
    God.names()
    |> Enum.reject(&(&1 == author))
    |> Enum.filter(&(state.durable.ledger[&1].coma_until < state.durable.epoch))
    |> Enum.min_by(
      fn name -> {Map.get(weights, {name, author}, base_weight(name, author)), name} end,
      fn -> nil end
    )
  end

  defp base_weight(a, b) do
    if {a, b} in [
         {"athena", "ares"},
         {"ares", "athena"},
         {"hephaestus", "ares"},
         {"hera", "zeus"}
       ],
       do: -10,
       else: 0
  end

  defp sponsor(state, author, reviewer) do
    God.allies(reviewer)
    |> Enum.reject(&(&1 == author or &1 == reviewer))
    |> Enum.find(
      &(state.durable.ledger[&1].coma_until < state.durable.epoch and
          state.durable.ledger[&1].favor > 0)
    )
  end

  defp reserve(acc, reserved, god, rounds) do
    allowance = max(div(Map.get(reserved, god, 0), rounds * 2), 1)
    amount = min(allowance, Map.get(acc.remaining, god, 0))
    {amount, %{acc | remaining: Map.update(acc.remaining, god, 0, &(&1 - amount))}}
  end

  defp request(state, contract, god, budget, deadline, action) do
    identity =
      if god,
        do: God.context(state.realm, god, Olympus.Politics.identity(state.durable, god)),
        else: %{}

    %{
      action: action,
      god: god,
      identity: identity,
      contract: contract |> Map.from_struct() |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end),
      budget: budget,
      timeout_ms: max(deadline - now(), 1),
      max_bytes: contract.max_bytes,
      opponents: state.contenders -- [god]
    }
  end

  defp launch(_, _, 0), do: nil

  defp launch(state, request, _) do
    if request.timeout_ms <= 1 do
      nil
    else
      adapter = state.adapter
      opts = state.adapter_opts
      owner = self()

      Task.Supervisor.async_nolink(Olympus.Tasks, fn ->
        worker = self()

        watcher =
          spawn(fn ->
            owner_ref = Process.monitor(owner)
            worker_ref = Process.monitor(worker)

            receive do
              {:DOWN, ^owner_ref, :process, ^owner, _} -> Process.exit(worker, :kill)
              {:DOWN, ^worker_ref, :process, ^worker, _} -> :ok
            end
          end)

        try do
          adapter.respond(request, opts) |> validate_response(request.max_bytes)
        after
          Process.exit(watcher, :kill)
        end
      end)
    end
  end

  defp await(nil, _, _), do: {:error, :budget}

  defp await(task, deadline, _limit) do
    result = Task.yield(task, max(deadline - now(), 0)) || Task.shutdown(task, :brutal_kill)

    case result do
      {:ok, {:ok, value}} ->
        {:ok, value}

      _ ->
        {:error, :adapter_failed}
    end
  rescue
    _ -> {:error, :adapter_failed}
  end

  defp validate_response({:ok, value}, limit) do
    if :erlang.external_size(value) <= limit * 8 + 4096 and Contract.json?(value) and
         byte_size(:json.encode(value) |> IO.iodata_to_binary()) <= limit,
       do: {:ok, value},
       else: {:error, :response_budget}
  end

  defp validate_response(_, _), do: {:error, :adapter_failed}

  defp finish(state, result) do
    durable = state.durable
    ledger = reward(durable.ledger, result.winner)

    ledger = Olympus.Politics.settle(ledger, result, durable.epoch, durable.stagnation)

    durable = %{
      durable
      | pending: nil,
        ledger: ledger,
        relationships:
          Olympus.Politics.lethe(Map.get(result, :relationships, durable.relationships)),
        stagnation: if(result.status == :cut, do: durable.stagnation + 1, else: 0),
        episodes: Map.put(durable.episodes, result.id, result),
        champion:
          if(result.status == :harmonious,
            do: %{id: result.id, god: result.winner, artifact: result.artifact},
            else: durable.champion
          )
    }

    persist(state, if(result.status == :harmonious, do: :harmony, else: :thread_cut), %{
      state: durable,
      result: result
    })
  end

  defp reward(ledger, nil), do: ledger

  defp reward(ledger, winner) do
    donors = Enum.count(ledger, fn {name, g} -> name != winner and g.favor > 1 end)

    Map.new(ledger, fn {name, g} ->
      favor =
        cond do
          name == winner -> g.favor + donors
          g.favor > 1 -> g.favor - 1
          true -> g.favor
        end

      {name, %{g | favor: favor}}
    end)
  end

  defp persist(state, type, data) do
    # Episode evidence is stored once, never copied into every subsequent snapshot.
    durable = data.state
    data = Map.update!(data, :state, &Map.delete(&1, :episodes))

    case Journal.append(state.journal, type, data) do
      {:ok, journal, event} ->
        %{
          state
          | journal: journal,
            events: state.events ++ [event],
            durable: durable
        }

      {:error, reason} ->
        exit({:fate_persistence_failed, reason})
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
  @impl true
  def terminate(_, state), do: Journal.close(state.journal)
end
