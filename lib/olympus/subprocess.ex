defmodule Olympus.Subprocess do
  @moduledoc false

  # A separate port owner survives an untrappable death of the requesting task.
  # Helpers must exit/cancel work when their input closes.
  def json(executable, args, input, timeout_ms, max_bytes) do
    owner = self()
    tag = make_ref()
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    {guardian, monitor} =
      spawn_monitor(fn ->
        Process.flag(:trap_exit, true)
        ref = Process.monitor(owner)
        result = invoke(executable, args, input, deadline, max_bytes, ref)
        send(owner, {tag, result})
      end)

    receive do
      {^tag, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^guardian, _} ->
        {:error, :subprocess_failed}
    end
  end

  defp invoke(executable, args, input, deadline, limit, owner_ref) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :use_stdio,
        :hide,
        args: args
      ])

    try do
      Port.command(port, [Olympus.JSON.encode(input), "\n"])
      collect(port, <<>>, deadline, limit, owner_ref)
    after
      if Port.info(port), do: Port.close(port)
    end
  rescue
    _ -> {:error, :subprocess_failed}
  end

  defp collect(port, bytes, deadline, limit, owner_ref) do
    receive do
      {^port, {:data, chunk}} ->
        if byte_size(bytes) + byte_size(chunk) <= limit,
          do: collect(port, bytes <> chunk, deadline, limit, owner_ref),
          else: {:error, :subprocess_output_budget}

      {^port, {:exit_status, 0}} ->
        decode(bytes)

      {^port, {:exit_status, _}} ->
        {:error, :subprocess_failed}

      {:EXIT, ^port, _} ->
        {:error, :subprocess_failed}

      {:DOWN, ^owner_ref, :process, _, _} ->
        {:error, :subprocess_cancelled}
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :subprocess_timeout}
    end
  end

  defp decode(bytes) do
    case Olympus.JSON.decode(bytes) do
      %{"ok" => true, "value" => value} -> {:ok, value}
      %{"ok" => false, "error" => error} when is_binary(error) -> {:error, {:helper, error}}
      _ -> {:error, :subprocess_protocol}
    end
  rescue
    _ -> {:error, :subprocess_protocol}
  end
end
