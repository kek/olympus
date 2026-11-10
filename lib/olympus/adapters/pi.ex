defmodule Olympus.Adapters.Pi do
  @moduledoc """
  Pi SDK 1.5.1 subprocess adapter. Requires Node >=22.19 and npm ci in priv/pi.
  Options: :provider, :model, optional :agent_dir and :node (executable path).
  Each call uses a new, tool-free in-memory session. Fate remains authoritative.
  """
  @behaviour Olympus.Adapter

  def respond(request, opts) do
    with provider when is_binary(provider) and provider != "" <- opts[:provider],
         model when is_binary(model) and model != "" <- opts[:model],
         node when is_binary(node) <- System.find_executable(Keyword.get(opts, :node, "node")) do
      envelope = %{
        "config" => %{"provider" => provider, "model" => model, "agent_dir" => opts[:agent_dir]},
        "request" => wire(request)
      }

      owner = self()
      tag = make_ref()
      deadline = System.monotonic_time(:millisecond) + request.timeout_ms

      {guardian, monitor} =
        spawn_monitor(fn ->
          Process.flag(:trap_exit, true)
          owner_ref = Process.monitor(owner)
          result = invoke(node, envelope, request.max_bytes, deadline, owner_ref)
          send(owner, {tag, result})
        end)

      receive do
        {^tag, result} ->
          Process.demonitor(monitor, [:flush])
          result

        {:DOWN, ^monitor, :process, ^guardian, _} ->
          {:error, :pi_failed}
      end
    else
      nil -> {:error, :pi_configuration}
      _ -> {:error, :pi_configuration}
    end
  rescue
    _ -> {:error, :pi_failed}
  end

  defp invoke(node, envelope, limit, deadline, owner_ref) do
    script = Application.app_dir(:olympus, "priv/pi/bridge.mjs")

    port =
      Port.open({:spawn_executable, node}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        args: [script],
        env: [{~c"PI_OFFLINE", ~c"1"}, {~c"PI_TELEMETRY", ~c"0"}]
      ])

    try do
      Port.command(port, [Olympus.JSON.encode(envelope), "\n"])
      collect(port, <<>>, limit + 128, deadline, owner_ref)
    after
      if Port.info(port), do: Port.close(port)
    end
  rescue
    _ -> {:error, :pi_failed}
  end

  defp collect(port, bytes, limit, deadline, owner_ref) do
    receive do
      {^port, {:data, chunk}} ->
        if byte_size(bytes) + byte_size(chunk) <= limit,
          do: collect(port, bytes <> chunk, limit, deadline, owner_ref),
          else: {:error, :response_budget}

      {^port, {:exit_status, 0}} ->
        decode(bytes)

      {^port, {:exit_status, _}} ->
        {:error, :pi_failed}

      {:EXIT, ^port, _} ->
        {:error, :pi_failed}

      {:DOWN, ^owner_ref, :process, _, _} ->
        {:error, :pi_cancelled}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :pi_timeout}
    end
  end

  defp decode(bytes) do
    case Olympus.JSON.decode(bytes) do
      %{"ok" => true, "value" => value} when is_map(value) -> {:ok, value}
      %{"ok" => false, "error" => "model_not_found"} -> {:error, :pi_model_not_found}
      %{"ok" => false, "error" => "response_budget"} -> {:error, :response_budget}
      %{"ok" => false, "error" => "token_budget"} -> {:error, :token_budget}
      _ -> {:error, :pi_failed}
    end
  rescue
    _ -> {:error, :pi_failed}
  end

  defp wire(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), wire(v)} end)

  defp wire(value) when is_list(value), do: Enum.map(value, &wire/1)
  defp wire(value) when value in [true, false, nil], do: value
  defp wire(value) when is_atom(value), do: Atom.to_string(value)
  defp wire(value), do: value
end
