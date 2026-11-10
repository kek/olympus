# Offline by default. Set OLYMPUS_PI_PROVIDER and OLYMPUS_PI_MODEL to use Pi.
defmodule CodingContenders do
  @behaviour Olympus.Adapter
  def respond(%{action: :propose, god: "ares"}, _) do
    {:ok, %{"artifact" => %{"files" => %{"main.py" => "print(0)\n"}}}}
  end

  def respond(%{action: :propose} = request, _) do
    # Deliberate first-attempt failure makes the offline repair demo deterministic.
    repair_demo =
      request.coding["manifest"]["max_attempts"] > 1 and not Map.has_key?(request, :repair)

    code =
      if repair_demo,
        do: "print(0)\n",
        else: "import sys\nprint(sum(map(int, sys.stdin.read().split())))\n"

    {:ok, %{"artifact" => %{"files" => %{"main.py" => code}}}}
  end

  def respond(%{action: :review}, _), do: {:ok, %{"objections" => []}}
end

repository = Path.expand("var/coding-source")

unless File.dir?(Path.join(repository, ".jj")) do
  File.mkdir_p!(repository)
  {_, 0} = System.cmd("jj", ["git", "init", repository], stderr_to_stdout: true)
  File.write!(Path.join(repository, "main.py"), "print('not implemented')\n")
  {_, 0} = System.cmd("jj", ["-R", repository, "status"], stderr_to_stdout: true)
end

fixtures = Path.expand("var/sum-cases.json")

File.write!(
  fixtures,
  Olympus.JSON.encode([
    %{"stdin" => "1 2\n", "stdout" => "3\n", "exit_code" => 0},
    %{"stdin" => "-3 1 8\n", "stdout" => "6\n", "exit_code" => 0},
    %{"stdin" => "", "stdout" => "0\n", "exit_code" => 0}
  ])
)

{adapter, adapter_opts} =
  if provider = System.get_env("OLYMPUS_PI_PROVIDER") do
    {Olympus.Adapters.Pi, [provider: provider, model: System.fetch_env!("OLYMPUS_PI_MODEL")]}
  else
    {CodingContenders, []}
  end

{:ok, realm} =
  Olympus.start_realm(
    journal: System.get_env("OLYMPUS_JOURNAL", "var/coding.journal"),
    contenders: ~w(athena ares),
    adapter: adapter,
    adapter_opts: adapter_opts,
    coding: [
      repository: repository,
      revision: "@",
      fixtures: fixtures,
      image: System.get_env("OLYMPUS_EVALUATOR_IMAGE", "docker.io/library/python:3.12-alpine"),
      engine: System.get_env("OLYMPUS_CONTAINER_ENGINE", "podman"),
      command: ["python3", "-I", "-B", "/candidate/main.py"],
      editable: ["main.py"],
      case_timeout_ms: 3000,
      max_attempts: String.to_integer(System.get_env("OLYMPUS_MAX_ATTEMPTS", "1"))
    ]
  )

prayer = %{
  "id" => "sum-integers-v1",
  "request" =>
    "Implement main.py: read whitespace-separated integers from stdin and print their sum followed by a newline. Empty input sums to zero.",
  "checks" => [%{"path" => ["evaluation", "passed"], "op" => "eq", "value" => true}],
  "objective" => %{"path" => ["evaluation", "patch_bytes"], "direction" => "min"},
  "rounds" => 1,
  "timeout_ms" => 120_000,
  "tokens" => 24_000,
  "max_bytes" => 32_768
}

result =
  case Olympus.pray(realm, prayer) do
    {:ok, result} -> result
    {:error, :episode_exists} -> Olympus.status(realm).episodes[prayer["id"]]
  end

if result.status == :harmonious do
  output = System.get_env("OLYMPUS_OUTPUT_DIR", "var/winner")
  File.mkdir_p!(output)
  File.write!(Path.join(output, "patch.diff"), result.artifact["patch"])

  File.write!(
    Path.join(output, "evidence.json"),
    Olympus.JSON.encode(result.artifact["evaluation"])
  )

  IO.puts("#{result.winner} won. Patch: #{output}/patch.diff; evidence: #{output}/evidence.json")
else
  IO.puts("Fate cut the contest; no patch was promoted.")
end

Enum.each(result.rounds, fn round ->
  Enum.each(round.candidates, fn candidate ->
    attempts = Map.get(candidate, :attempts, [])

    if attempts != [] do
      IO.puts("#{candidate.god}: " <> Enum.map_join(attempts, " → ", & &1["status"]))
    end
  end)
end)

IO.puts(Olympus.epic(realm))
