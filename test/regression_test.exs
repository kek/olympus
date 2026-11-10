defmodule Olympus.ContradictoryAdapter do
  @behaviour Olympus.Adapter

  def respond(%{action: :propose, god: "ares"}, opts) do
    round = Agent.get_and_update(opts[:counter], fn n -> {n + 1, n + 1} end)
    promise = round == 1

    {:ok,
     %{
       "artifact" => %{"ok" => true, "cost" => 1, "promise" => promise},
       "oaths" => [%{"path" => ["promise"], "op" => "eq", "value" => promise}]
     }}
  end

  def respond(req, opts), do: Olympus.TestAdapter.respond(req, opts)
end

defmodule Olympus.RegressionTest do
  use ExUnit.Case

  test "contradictory cross-round promises cannot produce harmony or erase earlier oaths" do
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    path =
      Path.join(System.tmp_dir!(), "olympus-oath-#{Base.encode16(:crypto.strong_rand_bytes(12))}")

    fate =
      start_supervised!(
        {Olympus.Fate,
         [journal: path, adapter: Olympus.ContradictoryAdapter, adapter_opts: [counter: counter]]}
      )

    on_exit(fn -> File.rm(path) end)

    prayer = %{
      "id" => "contradiction",
      "request" => "Produce a valid plan and keep your word",
      "checks" => [%{"path" => ["ok"], "op" => "eq", "value" => true}],
      "objective" => %{"path" => ["cost"], "direction" => "min"},
      "rounds" => 3,
      "timeout_ms" => 1000
    }

    assert {:ok, result} = Olympus.pray(fate, prayer)
    refute result.winner == "ares"
    ledger = Olympus.status(fate).ledger
    assert ledger["ares"].coma_until == 3

    for epoch <- 2..3 do
      assert {:ok, later} = Olympus.pray(fate, Map.put(prayer, "id", "coma-#{epoch}"))
      assert later.spent["ares"] == 0
    end

    assert Enum.any?(ledger["ares"].oaths, &(&1["value"] == true))

    assert Enum.any?(result.rounds, fn r ->
             Enum.any?(
               r.candidates,
               &(&1.god == "ares" and &1.measurement == {:error, :oath_broken})
             )
           end)
  end
end
