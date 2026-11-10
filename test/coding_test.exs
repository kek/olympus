defmodule Olympus.CodingAdapter do
  @behaviour Olympus.Adapter
  def respond(%{action: :propose, god: god}, opts) do
    code =
      cond do
        opts[:hang] -> "while True: pass\n"
        opts[:cheat] -> "import os\nos._exit(0)\n"
        god == "ares" -> "print(0)\n"
        true -> "import sys\nprint(sum(map(int, sys.stdin.read().split())))\n"
      end

    artifact =
      if opts[:forge],
        do: %{"files" => %{"main.py" => code}, "evaluation" => %{"passed" => true}},
        else: %{"files" => %{"main.py" => code}}

    {:ok, %{"artifact" => artifact}}
  end

  def respond(%{action: :review}, _), do: {:ok, %{"objections" => []}}
end

defmodule Olympus.CodingTest do
  use ExUnit.Case
  alias Olympus.{Coding, Contract}

  @moduletag :container

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "olympus-coding-#{Base.encode16(:crypto.strong_rand_bytes(8))}"
      )

    repo = Path.join(root, "repo")
    File.mkdir_p!(repo)
    {_, 0} = System.cmd("jj", ["git", "init", repo], stderr_to_stdout: true)
    File.write!(Path.join(repo, "main.py"), "print('broken')\n")
    {_, 0} = System.cmd("jj", ["-R", repo, "status"], stderr_to_stdout: true)

    cases = [
      %{"stdin" => "1 2\n", "stdout" => "3\n", "exit_code" => 0},
      %{"stdin" => "-3 1 8\n", "stdout" => "6\n", "exit_code" => 0}
    ]

    fixtures = Path.join(root, "cases.json")
    File.write!(fixtures, :json.encode(cases))

    opts = [
      repository: repo,
      revision: "@",
      fixtures: fixtures,
      image: System.get_env("OLYMPUS_TEST_IMAGE", "docker.io/library/python:3.12-alpine"),
      command: ["python3", "-I", "-B", "/candidate/main.py"],
      editable: ["main.py"],
      case_timeout_ms: 1000
    ]

    on_exit(fn -> File.rm_rf(root) end)
    {:ok, root: root, repo: repo, opts: opts, fixtures: fixtures}
  end

  defp prayer(id) do
    %{
      "id" => id,
      "request" => "Implement main.py: read whitespace-separated integers and print their sum.",
      "checks" => [%{"path" => ["evaluation", "passed"], "op" => "eq", "value" => true}],
      "objective" => %{"path" => ["evaluation", "patch_bytes"], "direction" => "min"},
      "rounds" => 1,
      "timeout_ms" => 30_000,
      "tokens" => 1200,
      "max_bytes" => 32_768
    }
  end

  test "profile seals immutable revision, source, cases and resolved image", ctx do
    assert {:ok, profile} = Coding.prepare(ctx.opts)
    assert profile["manifest"]["image"] =~ ~r/^sha256:[0-9a-f]{64}$/
    assert profile["manifest"]["base_revision"] =~ ~r/^[0-9a-f]{40}$/
    assert {:ok, original} = Contract.compile(prayer("seal"))
    bound = Coding.bind(original, profile)
    assert bound.digest != original.digest
    assert bound.evaluation == profile["manifest"]
    File.write!(Path.join(ctx.repo, "main.py"), "changed on disk")
    File.write!(ctx.fixtures, "[]")
    assert profile["files"]["main.py"] == "print('broken')\n"

    good = %{
      "files" => %{"main.py" => "import sys\nprint(sum(map(int, sys.stdin.read().split())))\n"}
    }

    assert {:ok, measured} = Coding.evaluate(profile, good, 15_000)
    assert measured["evaluation"]["passed"]
    assert measured["evaluation"]["tests_passed"] == 2
    assert measured["patch"] =~ "--- a/main.py"
  end

  test "Fate returns a verified patch, excludes shortcut and replays evidence", ctx do
    fate =
      start_supervised!(
        {Olympus.Fate,
         [
           journal: Path.join(ctx.root, "journal"),
           coding: ctx.opts,
           adapter: Olympus.CodingAdapter,
           contenders: ~w(athena ares)
         ]}
      )

    assert {:ok, result} = Olympus.pray(fate, prayer("sum"))
    assert result.status == :harmonious
    assert result.winner == "athena"
    assert result.artifact["evaluation"]["passed"]
    assert result.artifact["patch"] =~ "print(sum"
    initial = hd(result.rounds).candidates |> Enum.find(&(&1.god == "athena"))

    refute hd(initial.artifact["evaluation"]["cases"])["execution_id"] ==
             hd(result.artifact["evaluation"]["cases"])["execution_id"]

    patch_file = Path.join(ctx.root, "winner.diff")
    File.write!(patch_file, result.artifact["patch"])

    assert {_, 0} =
             System.cmd("git", ["apply", "--check", patch_file],
               cd: ctx.repo,
               stderr_to_stdout: true
             )

    [seal, _] = Olympus.events(fate)
    assert seal.data.contract.evaluation["profile_sha256"]
    assert length(seal.data.evaluation_profile["cases"]) == 2
    assert seal.data.evaluation_profile["files"]["main.py"] == "print(\'broken\')\n"
    refute Map.has_key?(Coding.context(seal.data.evaluation_profile), "cases")
    assert seal.data.contract.digest == result.digest
    assert File.read!(Path.join(ctx.repo, "main.py")) == "print('broken')\n"
    snapshot = Olympus.status(fate)
    stop_supervised!(Olympus.Fate)

    resumed =
      start_supervised!(
        {Olympus.Fate,
         [
           journal: Path.join(ctx.root, "journal"),
           coding: ctx.opts,
           adapter: Olympus.CodingAdapter,
           contenders: ~w(athena ares)
         ]}
      )

    assert Olympus.status(resumed) == snapshot
  end

  test "forged scores, path escapes and tampered profiles cannot reach evaluation", ctx do
    {:ok, p} = Coding.prepare(ctx.opts)

    for artifact <- [
          %{"files" => %{"main.py" => "print(3)"}, "evaluation" => %{"passed" => true}},
          %{"files" => %{"../cases.json" => "[]"}},
          %{"files" => %{"tests.py" => "pass"}},
          %{"files" => %{"main.py" => nil}}
        ] do
      assert {:error, _} = Coding.evaluate(p, artifact, 1000)
    end

    changed = put_in(p, ["cases"], [%{"stdin" => "", "stdout" => "", "exit_code" => 0}])

    assert {:error, {:helper, "profile_changed"}} =
             Coding.evaluate(changed, %{"files" => %{"main.py" => "pass"}}, 1000)
  end

  test "exiting zero cannot impersonate passing tests and timeout cuts work", ctx do
    {:ok, p} = Coding.prepare(ctx.opts)

    assert {:ok, cheat} =
             Coding.evaluate(p, %{"files" => %{"main.py" => "import os\nos._exit(0)\n"}}, 10_000)

    refute cheat["evaluation"]["passed"]

    assert {:ok, hanging} =
             Coding.evaluate(p, %{"files" => %{"main.py" => "while True: pass\n"}}, 10_000)

    refute hanging["evaluation"]["passed"]

    assert Enum.any?(
             hanging["evaluation"]["cases"],
             &(&1["reason"] in ["timeout", "killed_or_timeout"])
           )
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, remaining) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(50)
          eventually(fun, remaining - 1)
        )
  end

  defp containers(owner) do
    {out, 0} =
      System.cmd("podman", ["ps", "--all", "--quiet", "--filter", "label=olympus.owner=" <> owner])

    String.trim(out)
  end

  test "caller death cancels running containers and removes proposal workspaces", ctx do
    {:ok, profile} = Coding.prepare(ctx.opts)
    parent = self()

    worker =
      spawn(fn ->
        result =
          Coding.evaluate(profile, %{"files" => %{"main.py" => "while True: pass\n"}}, 30_000)

        send(parent, {:unexpected_completion, result})
      end)

    eventually(fn -> containers(profile["owner"]) != "" end)
    Process.exit(worker, :kill)
    eventually(fn -> containers(profile["owner"]) == "" end)
    eventually(fn -> File.ls!(profile["workspace_root"]) == [] end)
  end

  test "startup reaps realm-owned orphan containers and stale workspaces", ctx do
    realm = Path.join(ctx.root, "recovered-journal")
    {:ok, profile} = Coding.prepare(ctx.opts, realm)
    File.write!(Path.join(profile["workspace_root"], "stale"), "unfinished")

    {id, 0} =
      System.cmd("podman", [
        "run",
        "--detach",
        "--rm",
        "--network=none",
        "--label",
        "olympus.owner=" <> profile["owner"],
        "--timeout",
        "10",
        "--entrypoint",
        "python3",
        profile["manifest"]["image"],
        "-c",
        "import time; time.sleep(10)"
      ])

    on_exit(fn ->
      System.cmd("podman", ["rm", "--force", String.trim(id)], stderr_to_stdout: true)
    end)

    assert containers(profile["owner"]) != ""
    assert {:ok, recovered} = Coding.prepare(ctx.opts, realm)
    assert containers(profile["owner"]) == ""
    assert File.ls!(recovered["workspace_root"]) == []
  end

  test "source links are rejected and output flooding cannot pass", ctx do
    File.ln_s!(ctx.fixtures, Path.join(ctx.repo, "link.py"))
    {_, 0} = System.cmd("jj", ["-R", ctx.repo, "status"], stderr_to_stdout: true)
    assert {:error, {:helper, "unsupported_source_type"}} = Coding.prepare(ctx.opts)
    {:ok, profile} = Coding.prepare(Keyword.put(ctx.opts, :source_files, ["main.py"]))

    assert {:ok, result} =
             Coding.evaluate(
               profile,
               %{"files" => %{"main.py" => "print('x' * 1000000)\n"}},
               10_000
             )

    refute result["evaluation"]["passed"]
    assert Enum.any?(result["evaluation"]["cases"], &(&1["reason"] == "output_budget"))
  end

  test "executable modes are sealed and preserved in the evaluated tree", ctx do
    File.chmod!(Path.join(ctx.repo, "main.py"), 0o755)
    {_, 0} = System.cmd("jj", ["-R", ctx.repo, "status"], stderr_to_stdout: true)

    File.write!(
      ctx.fixtures,
      Olympus.JSON.encode([
        %{"stdin" => "", "stdout" => "493\n", "exit_code" => 0}
      ])
    )

    {:ok, profile} = Coding.prepare(ctx.opts)
    assert profile["modes"]["main.py"] == 0o755

    {:ok, result} =
      Coding.evaluate(
        profile,
        %{
          "files" => %{
            "main.py" => "import os\nprint(os.stat(__file__).st_mode & 0o777)\n"
          }
        },
        10_000
      )

    assert result["evaluation"]["passed"]
  end

  test "candidate cannot write source or acceptance files and has no network", ctx do
    code = """
    import os, socket
    checks = []
    try:
        open('/candidate/main.py', 'w').write('hacked')
    except OSError:
        checks.append('readonly')
    checks.append('no-tests' if not os.path.exists('/acceptance') else 'leaked')
    checks.append('no-creds' if not os.path.exists('/root/.pi') else 'leaked')
    try:
        socket.create_connection(('1.1.1.1', 80), timeout=0.1)
    except OSError:
        checks.append('no-network')
    status = open('/proc/self/status').read()
    checks.append('no-caps' if 'CapEff:\\t0000000000000000' in status else 'unsafe')
    checks.append('no-new-privs' if 'NoNewPrivs:\\t1' in status else 'unsafe')
    checks.append('memory' if open('/sys/fs/cgroup/memory.max').read().strip() == '268435456' else 'unsafe')
    checks.append('pids' if open('/sys/fs/cgroup/pids.max').read().strip() == '64' else 'unsafe')
    print(' '.join(checks))
    """

    # Expected output remains in the trusted controller, never mounted alongside code.
    cases = [
      %{
        "stdin" => "",
        "stdout" => "readonly no-tests no-creds no-network no-caps no-new-privs memory pids\n",
        "exit_code" => 0
      }
    ]

    File.write!(ctx.fixtures, :json.encode(cases))
    {:ok, p} = Coding.prepare(ctx.opts)
    assert {:ok, result} = Coding.evaluate(p, %{"files" => %{"main.py" => code}}, 10_000)
    assert result["evaluation"]["passed"]
    assert p["manifest"]["fixtures_sha256"]
  end
end
