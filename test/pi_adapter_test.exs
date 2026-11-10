defmodule Olympus.PiAdapterTest do
  use ExUnit.Case, async: true
  alias Olympus.Adapters.Pi

  defp request do
    %{
      action: :propose,
      god: "athena",
      identity: %{ambrosia: %{favor: 100}, context: []},
      contract: %{"id" => "city"},
      opponents: ["ares"],
      budget: 10,
      timeout_ms: 1000,
      max_bytes: 4096
    }
  end

  defp opts(provider) do
    executable =
      Path.join(System.tmp_dir!(), "pi-node-#{Base.encode16(:crypto.strong_rand_bytes(8))}")

    File.cp!(Path.expand("fixtures/pi_node.py", __DIR__), executable)
    File.chmod!(executable, 0o700)
    on_exit(fn -> File.rm(executable) end)
    [provider: provider, model: "test-model", node: executable]
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(20)
          eventually(fun, attempts - 1)
        )
  end

  test "wire protocol serializes action and nested identity without atom-keyed JSON" do
    assert {:ok, %{"artifact" => artifact}} = Pi.respond(request(), opts("echo"))
    assert artifact["action"] == "propose"
    assert artifact["identity"] == %{"ambrosia" => %{"favor" => 100}, "context" => []}
    assert artifact["model"] == "test-model"
  end

  test "configuration, provider failure and invalid responses fail closed" do
    assert {:error, :pi_configuration} = Pi.respond(request(), [])

    assert {:error, :pi_configuration} =
             Pi.respond(request(), provider: "x", model: "y", node: "/absent/node")

    assert {:error, :pi_failed} = Pi.respond(request(), opts("malformed"))
    assert {:error, :pi_failed} = Pi.respond(request(), opts("failure"))
    assert {:error, :pi_model_not_found} = Pi.respond(request(), opts("missing"))
    assert {:error, :response_budget} = Pi.respond(%{request() | max_bytes: 32}, opts("oversize"))
  end

  test "deadline closes child stdin rather than leaving a hanging process" do
    marker =
      Path.join(System.tmp_dir!(), "pi-timeout-#{Base.encode16(:crypto.strong_rand_bytes(8))}")

    on_exit(fn ->
      File.rm(marker)
      File.rm(marker <> ".closed")
    end)

    assert {:error, :pi_timeout} =
             Pi.respond(%{request() | timeout_ms: 200}, opts("hang") ++ [agent_dir: marker])

    eventually(fn -> File.exists?(marker <> ".closed") end)
  end

  test "Fate task death closes child input even when its after block cannot run" do
    marker =
      Path.join(System.tmp_dir!(), "pi-death-#{Base.encode16(:crypto.strong_rand_bytes(8))}")

    on_exit(fn ->
      File.rm(marker)
      File.rm(marker <> ".closed")
    end)

    options = opts("hang") ++ [agent_dir: marker]

    worker =
      spawn(fn ->
        Pi.respond(%{request() | timeout_ms: 10_000}, options)
      end)

    eventually(fn -> File.exists?(marker) end)
    Process.exit(worker, :kill)
    eventually(fn -> File.exists?(marker <> ".closed") end)
  end
end
