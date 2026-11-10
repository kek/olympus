# Offline by default. Set OLYMPUS_PI_PROVIDER and OLYMPUS_PI_MODEL to use Pi.
defmodule CodingContenders do
  @behaviour Olympus.Adapter
  def respond(%{action: :propose, god: "ares"}, _) do
    {:ok, %{"artifact" => %{"files" => %{"main.py" => "print(0)\n"}}}}
  end

  def respond(%{action: :propose}, _) do
    {:ok,
     %{
       "artifact" => %{
         "files" => %{"main.py" => "import sys\nprint(sum(map(int, sys.stdin.read().split())))\n"}
       }
     }}
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
      command: ["python3", "-I", "-B", "/candidate/main.py"],
      editable: ["main.py"],
      case_timeout_ms: 3000
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
  File.mkdir_p!("var/winner")
  File.write!("var/winner/patch.diff", result.artifact["patch"])
  File.write!("var/winner/evidence.json", Olympus.JSON.encode(result.artifact["evaluation"]))

  IO.puts(
    "#{result.winner} won. Patch: var/winner/patch.diff; evidence: var/winner/evidence.json"
  )
else
  IO.puts("Fate cut the contest; no patch was promoted.")
end

IO.puts(Olympus.epic(realm))
