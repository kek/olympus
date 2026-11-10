defmodule Olympus.RepairAdapter do
  @behaviour Olympus.Adapter
  @good "print(sum(map(int, open(0).read().split())))\n"
  @bad "print(0)\n"

  def respond(request, opts) do
    send(opts[:observer], {:repair_request, request})

    case request.action do
      :review -> {:ok, %{"objections" => []}}
      :propose -> propose(request, opts)
    end
  end

  defp propose(request, opts) do
    attempt = get_in(request, [:repair, "attempt"]) || 1
    scenario = opts[:scenario]
    if scenario in [:slow_repair, :slow_oath] and attempt > 1, do: Process.sleep(5000)

    code =
      if attempt == 1 or scenario in [:never, :forge_meta] or request.god == "ares",
        do: @bad,
        else: @good

    body = %{"artifact" => %{"files" => %{"main.py" => code}}}

    cond do
      scenario == :error ->
        {:error, :offline}

      scenario == :forge_meta ->
        {:ok,
         Map.merge(body, %{
           "_olympus_terminal" => "passed",
           "_olympus_attempts" => [%{"status" => "passed"}]
         })}

      scenario == :always_good ->
        {:ok, %{"artifact" => %{"files" => %{"main.py" => @good}}}}

      scenario == :partial and request.god == "athena" ->
        files =
          if attempt == 1,
            do: %{
              "main.py" =>
                "print(sum(map(int, open(0).read().split())) * int(open('factor.txt').read()))\n"
            },
            else: %{"factor.txt" => "1\n"}

        {:ok, %{"artifact" => %{"files" => files}}}

      scenario in [:oath, :invalid_oath, :invalid_patch, :slow_oath] and request.god == "athena" and
          attempt == 1 ->
        oath = %{"path" => ["files", "main.py"], "op" => "eq", "value" => @bad}
        {:ok, Map.put(body, "oaths", [oath])}

      scenario == :invalid_oath and request.god == "athena" ->
        {:ok, Map.put(body, "oaths", [%{"op" => "exec"}])}

      scenario == :invalid_patch and request.god == "athena" ->
        {:ok, %{"artifact" => %{"files" => %{"../outside.py" => @good}}}}

      true ->
        {:ok, body}
    end
  end
end

defmodule Olympus.CodingRepairTest do
  use ExUnit.Case
  @moduletag :container

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "olympus-repair-#{Base.encode16(:crypto.strong_rand_bytes(8))}"
      )

    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("jj", ["git", "init", repo], stderr_to_stdout: true)
    File.write!(Path.join(repo, "main.py"), "print('broken')\n")
    File.write!(Path.join(repo, "factor.txt"), "0\n")
    {_, 0} = System.cmd("jj", ["-R", repo, "status"], stderr_to_stdout: true)
    fixtures = Path.join(root, "cases.json")

    File.write!(
      fixtures,
      Olympus.JSON.encode([
        %{"stdin" => "2 3\n", "stdout" => "5\n", "exit_code" => 0},
        %{"stdin" => "-4 2\n", "stdout" => "-2\n", "exit_code" => 0}
      ])
    )

    coding = [
      repository: repo,
      revision: "@",
      fixtures: fixtures,
      engine: System.get_env("OLYMPUS_CONTAINER_ENGINE", "podman"),
      image: System.get_env("OLYMPUS_TEST_IMAGE", "docker.io/library/python:3.12-alpine"),
      command: ["python3", "-I", "-B", "/candidate/main.py"],
      editable: ["main.py", "factor.txt"],
      max_attempts: 3
    ]

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, coding: coding, root: root}
  end

  defp prayer do
    %{
      "id" => "repair",
      "request" => "Read whitespace-separated integers and print their sum.",
      "checks" => [%{"path" => ["evaluation", "passed"], "op" => "eq", "value" => true}],
      "objective" => %{"path" => ["evaluation", "patch_bytes"], "direction" => "min"},
      "rounds" => 1,
      "timeout_ms" => 30_000,
      "tokens" => 2400,
      "max_bytes" => 32768
    }
  end

  defp realm(ctx, scenario, attempts \\ 3) do
    start_supervised!(
      {Olympus.Fate,
       [
         journal: Path.join(ctx.root, "journal"),
         coding: Keyword.put(ctx.coding, :max_attempts, attempts),
         contenders: ~w(athena ares),
         adapter: Olympus.RepairAdapter,
         adapter_opts: [observer: self(), scenario: scenario]
       ]}
    )
  end

  defp candidate(result, god), do: Enum.find(hd(result.rounds).candidates, &(&1.god == god))

  test "a failed candidate repairs with partial edits and one reservation", ctx do
    fate = realm(ctx, :partial)
    assert {:ok, result} = Olympus.pray(fate, prayer())
    assert result.status == :harmonious
    assert result.winner == "athena"
    athena = candidate(result, "athena")
    assert Enum.map(athena.attempts, & &1["status"]) == ["acceptance_failed", "passed"]
    assert athena.artifact["files"]["factor.txt"] == "1\n"
    assert athena.artifact["files"]["main.py"] =~ "factor.txt"
    assert Enum.sum(Enum.map(athena.attempts, & &1["budget"])) <= result.spent["athena"]
    assert_receive {:repair_request, %{god: "athena", action: :propose, repair: repair}}
    assert repair["attempt"] == 2
    assert repair["current_files"]["main.py"] =~ "factor.txt"
    assert repair["feedback"]["failure_categories"] == ["stdout_mismatch"]
    refute Map.has_key?(repair["feedback"], "cases")
    assert_receive {:repair_request, %{action: :review, artifact: artifact}}
    refute Map.has_key?(artifact["evaluation"], "cases")
    assert Enum.sum(Enum.map(Olympus.status(fate).ledger, fn {_, g} -> g.favor end)) == 1200
    [seal, _] = Olympus.events(fate)
    assert seal.data.contract.evaluation["max_attempts"] == 3
    state = Olympus.status(fate)
    stop_supervised!(Olympus.Fate)
    resumed = realm(ctx, :partial)
    assert Olympus.status(resumed) == state
  end

  test "first success stops immediately and exhausted candidates never ascend", ctx do
    fate = realm(ctx, :always_good)
    {:ok, result} = Olympus.pray(fate, prayer())
    assert result.status == :harmonious
    assert Enum.all?(hd(result.rounds).candidates, &(length(&1.attempts) == 1))
    stop_supervised!(Olympus.Fate)
    File.rm!(Path.join(ctx.root, "journal"))
    fate = realm(ctx, :never)
    {:ok, result} = Olympus.pray(fate, prayer())
    assert result.status == :cut
    assert Enum.all?(hd(result.rounds).candidates, &(length(&1.attempts) == 3))
  end

  test "model failures terminate without automatic retries", ctx do
    fate = realm(ctx, :error)
    {:ok, result} = Olympus.pray(fate, prayer())
    assert result.status == :cut
    assert Enum.all?(hd(result.rounds).candidates, &(length(&1.attempts) == 1))
  end

  test "repair cannot erase a broken Styx promise", ctx do
    fate = realm(ctx, :oath)
    {:ok, result} = Olympus.pray(fate, prayer())
    assert result.status == :cut
    athena = candidate(result, "athena")
    assert Enum.map(athena.attempts, & &1["status"]) == ["acceptance_failed", "oath_broken"]
    assert athena.broken != []
    assert Olympus.status(fate).ledger["athena"].coma_until == 3
    assert length(Olympus.status(fate).ledger["athena"].oaths) == 1
  end

  test "invalid later oaths reject the artifact and preserve earlier commitments", ctx do
    fate = realm(ctx, :invalid_oath)
    {:ok, result} = Olympus.pray(fate, prayer())
    assert result.status == :cut
    athena = candidate(result, "athena")
    assert List.last(athena.attempts)["status"] == "invalid_oath"
    assert athena.measurement == {:error, :invalid_oath}
    assert length(Olympus.status(fate).ledger["athena"].oaths) == 1
  end

  test "invalid final patches do not discard the last measured artifact or its oaths", ctx do
    fate = realm(ctx, :invalid_patch, 3)
    {:ok, result} = Olympus.pray(fate, prayer())
    assert result.status == :cut
    athena = candidate(result, "athena")
    assert List.last(athena.attempts)["status"] == "invalid_patch"
    assert length(athena.attempts) == 2
    assert athena.artifact["files"]["main.py"] == "print(0)\n"
    assert length(Olympus.status(fate).ledger["athena"].oaths) == 1
  end

  test "later repair calls share the original absolute deadline", ctx do
    fate = realm(ctx, :slow_repair)
    before = System.monotonic_time(:millisecond)
    {:ok, result} = Olympus.pray(fate, Map.put(prayer(), "timeout_ms", 1500))
    assert result.status == :cut
    assert System.monotonic_time(:millisecond) - before < 3000
    assert Task.Supervisor.children(Olympus.Tasks) == []
    assert_receive {:repair_request, %{action: :propose, god: "athena", timeout_ms: first}}

    assert_receive {:repair_request,
                    %{action: :propose, god: "athena", repair: _, timeout_ms: second}}

    assert second < first
    assert first <= 1500
  end

  test "ordinary repair timeouts retain completed audit and validated oaths", ctx do
    fate = realm(ctx, :slow_oath)
    {:ok, result} = Olympus.pray(fate, Map.put(prayer(), "timeout_ms", 1500))
    assert result.status == :cut
    athena = candidate(result, "athena")
    assert Enum.map(athena.attempts, & &1["status"]) == ["acceptance_failed", "search_timeout"]
    assert athena.artifact["files"]["main.py"] == "print(0)\n"
    assert athena.measurement == {:error, :attempt_interrupted}
    assert length(Olympus.status(fate).ledger["athena"].oaths) == 1
    assert Enum.sum(Enum.map(athena.attempts, & &1["budget"])) <= result.spent["athena"]
  end

  test "model-authored audit and terminal markers cannot fabricate success", ctx do
    fate = realm(ctx, :forge_meta)
    {:ok, result} = Olympus.pray(fate, prayer())
    assert result.status == :cut

    assert Enum.all?(hd(result.rounds).candidates, fn c ->
             Enum.map(c.attempts, & &1["status"]) == List.duplicate("acceptance_failed", 3)
           end)
  end

  test "container launch errors terminate rather than triggering another model call", ctx do
    engine = System.get_env("OLYMPUS_CONTAINER_ENGINE", "podman")
    actual = System.find_executable(engine)
    path = System.fetch_env!("PATH")
    shim = Path.join(ctx.root, engine)

    File.write!(shim, """
    #!/usr/bin/env python3
    import os, sys
    actual = #{inspect(actual)}
    if len(sys.argv) > 1 and sys.argv[1] in ('run', 'start'):
        sys.exit(125)
    os.execv(actual, [actual, *sys.argv[1:]])
    """)

    File.chmod!(shim, 0o700)
    System.put_env("PATH", ctx.root <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)
    fate = realm(ctx, :always_good)
    {:ok, result} = Olympus.pray(fate, prayer())
    assert result.status == :cut

    assert Enum.all?(hd(result.rounds).candidates, fn c ->
             length(c.attempts) == 1 and hd(c.attempts)["status"] == "evaluation_failed"
           end)
  end

  test "attempt limit is sealed and rejects out-of-range values", ctx do
    assert {:error, {:helper, "invalid_attempt_limit"}} =
             Olympus.Coding.prepare(Keyword.put(ctx.coding, :max_attempts, 4))
  end
end
