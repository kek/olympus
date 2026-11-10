defmodule Olympus.TestAdapter do
  @behaviour Olympus.Adapter
  def respond(req, opts) do
    if pid = opts[:observer], do: send(pid, {:request, req})
    if opts[:sleep], do: Process.sleep(opts[:sleep])
    if opts[:crash], do: raise("the god fell")

    case req.action do
      :propose ->
        valid = opts[:invalid] != true
        cost = if req.god == "ares", do: 1, else: 3
        {:ok, %{"artifact" => %{"ok" => valid, "cost" => cost}}}

      :review ->
        {:ok, %{"objections" => [0, -1, 999, "all", 0]}}
    end
  end
end

defmodule Olympus.FateTest do
  use ExUnit.Case
  alias Olympus.Fate

  defp path do
    Path.join(
      System.tmp_dir!(),
      "olympus-test-#{Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)}/events"
    )
  end

  defp start(opts \\ []) do
    journal = opts[:journal] || path()

    pid =
      start_supervised!(
        {Fate,
         [journal: journal, adapter: Olympus.TestAdapter, adapter_opts: opts[:adapter_opts] || []]}
      )

    {pid, journal}
  end

  defp prayer(id \\ "contest") do
    %{
      "id" => id,
      "request" => "Produce a low-cost valid plan",
      "checks" => [%{"path" => ["ok"], "op" => "eq", "value" => true}],
      "objective" => %{"path" => ["cost"], "direction" => "min"},
      "rounds" => 3,
      "timeout_ms" => 1_000,
      "tokens" => 1200
    }
  end

  test "rivalry settles autonomously, conserves favor and cannot be vetoed by fabricated objections" do
    {fate, _} = start(adapter_opts: [observer: self()])
    assert {:ok, result} = Fate.pray(fate, prayer())
    assert result.status == :harmonious
    assert result.winner == "ares"
    assert result.sponsor == "hephaestus"
    assert length(result.rounds) == 2
    assert Enum.sum(Map.values(result.spent)) <= 1200
    assert Enum.all?(result.spent, fn {_, n} -> n >= 0 end)

    assert Enum.all?(result.rounds, fn r ->
             Enum.all?(r.candidates, &(&1.review.verified == []))
           end)

    ledger = Fate.status(fate).ledger
    assert Enum.sum(Enum.map(ledger, fn {_, g} -> g.favor end)) == 1200
    assert ledger["ares"].favor > ledger["athena"].favor
    assert {:error, :episode_exists} = Fate.pray(fate, prayer())
    assert_receive {:request, %{budget: budget, contract: %{"digest" => digest}}}
    assert budget > 0
    assert byte_size(digest) == 64
    assert Fate.epic(fate) =~ "Lachesis declared harmony"
  end

  test "invalid candidates cannot ascend and verified enemy criticism changes relationships" do
    {fate, _} = start(adapter_opts: [invalid: true])
    assert {:ok, r} = Fate.pray(fate, prayer())
    assert r.status == :cut
    assert r.winner == nil
    assert Fate.status(fate).champion == nil
    assert map_size(Fate.status(fate).relationships) > 0
    assert Enum.all?(Fate.status(fate).ledger, fn {_, g} -> g.favor == 100 end)
  end

  test "Atropos kills hanging work without accepting a late result" do
    {fate, _} = start(adapter_opts: [sleep: 300])
    before = System.monotonic_time(:millisecond)
    assert {:ok, r} = Fate.pray(fate, Map.put(prayer(), "timeout_ms", 30))
    assert System.monotonic_time(:millisecond) - before < 250
    assert r.status == :cut
    assert Task.Supervisor.children(Olympus.Tasks) == []
  end

  @tag capture_log: true
  test "crashing adapters do not crash Fate or bypass measurement" do
    {fate, _} = start(adapter_opts: [crash: true])
    assert {:ok, %{status: :cut}} = Fate.pray(fate, prayer())
    assert Process.alive?(fate)
  end

  test "replay restores exact durable state and duplicate fencing" do
    {fate, journal} = start()
    {:ok, _} = Fate.pray(fate, prayer())
    original = Fate.status(fate)
    events = Fate.events(fate)
    stop_supervised!(Fate)
    {restarted, _} = start(journal: journal)
    assert Fate.status(restarted) == original
    assert Fate.events(restarted) == events
    assert {:error, :episode_exists} = Fate.pray(restarted, prayer())
  end

  test "interrupted sealed epoch is cut on recovery, never retried" do
    {fate, journal} = start()
    {:ok, _} = Fate.pray(fate, prayer())
    [seal, _] = Fate.events(fate)
    stop_supervised!(Fate)
    File.rm!(journal)
    {:ok, j, []} = Olympus.Journal.open(journal)
    {:ok, j, _} = Olympus.Journal.append(j, seal.type, seal.data)
    Olympus.Journal.close(j)
    {restarted, _} = start(journal: journal)
    assert Fate.status(restarted).pending == nil
    assert Fate.status(restarted).episodes["contest"].reason == :restart
    assert {:error, :episode_exists} = Fate.pray(restarted, prayer())
  end

  test "same journal cannot have two live Fate writers" do
    {_, journal} = start()

    assert {:error, {:already_started, _}} =
             Fate.start_link(journal: journal, adapter: Olympus.TestAdapter)
  end

  test "tiny token allocations never overspend" do
    {fate, _} = start()
    assert {:ok, r} = Fate.pray(fate, Map.put(prayer(), "tokens", 1))
    assert Enum.sum(Map.values(r.spent)) <= 1
    assert r.status == :cut
  end

  test "evidence budget is rejected before dispatch and journal snapshots do not duplicate history" do
    {fate, _} = start()
    assert {:error, :evidence_budget} = Fate.pray(fate, Map.put(prayer(), "max_bytes", 1_048_576))
    assert Fate.events(fate) == []

    for n <- 1..20 do
      assert {:ok, %{status: :harmonious}} = Fate.pray(fate, prayer("episode-#{n}"))
    end

    assert map_size(Fate.status(fate).episodes) == 20
    assert Enum.all?(Fate.events(fate), &(not Map.has_key?(&1.data.state, :episodes)))
  end

  test "invalid prayers create no journal events" do
    {fate, _} = start()

    assert {:error, :invalid_contract} =
             Fate.pray(fate, %{"request" => "invent your own success criteria"})

    assert Fate.events(fate) == []
  end
end
