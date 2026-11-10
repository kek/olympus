defmodule Olympus.Adapter do
  @moduledoc """
  Untrusted proposal source. A request has action, god, contract, budget,
  opponents, and optionally artifact. Return {:ok, JSON value} or {:error, reason}.
  Fate may invoke coding proposals repeatedly with disjoint attempt allowances.
  Provider-supported output caps, elapsed time and output bytes bound each call;
  native Codex completion usage is checked after generation.
  Implementations run as disposable tasks, never as Fate callbacks.
  """
  @callback respond(map(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback respond_with_usage(map(), keyword()) ::
              {:ok, term(), map() | nil} | {:error, term(), map() | nil} | {:error, term()}
  @optional_callbacks respond_with_usage: 2

  @usage_keys ~w(input output cacheRead cacheWrite totalTokens)

  @doc "Invoke trusted adapter code and keep timing/usage outside the model-authored value."
  def invoke(adapter, request, opts) do
    started = System.monotonic_time(:millisecond)

    raw =
      try do
        Code.ensure_loaded!(adapter)

        if function_exported?(adapter, :respond_with_usage, 2),
          do: adapter.respond_with_usage(request, opts),
          else: adapter.respond(request, opts)
      rescue
        _ -> {:error, :adapter_failed}
      catch
        _, _ -> {:error, :adapter_failed}
      end

    {result, meta} =
      case raw do
        {:ok, body, meta} -> {{:ok, body}, meta}
        {:error, reason, meta} -> {{:error, reason}, meta}
        {:ok, body} -> {{:ok, body}, nil}
        {:error, reason} -> {{:error, reason}, nil}
        _ -> {{:error, :invalid_adapter_result}, nil}
      end

    usage = usage(meta)

    call = %{
      "adapter" => Atom.to_string(adapter),
      "action" => Atom.to_string(request.action),
      "completion_allowance" => request.budget,
      "elapsed_ms" => max(System.monotonic_time(:millisecond) - started, 0),
      "status" => if(match?({:ok, _}, result), do: "ok", else: "error"),
      "provider" => label(meta, "provider"),
      "model" => label(meta, "model"),
      "usage_format" => if(usage, do: "pi-sdk", else: nil),
      "usage" => usage
    }

    {result, call}
  end

  defp label(meta, key) when is_map(meta) do
    case meta[key] do
      value when is_binary(value) and byte_size(value) <= 256 ->
        if String.valid?(value), do: value, else: nil

      _ ->
        nil
    end
  end

  defp label(_, _), do: nil

  defp usage(%{"usage_format" => "pi-sdk", "usage" => usage}) when is_map(usage) do
    if Enum.all?(@usage_keys, fn key ->
         is_integer(usage[key]) and usage[key] >= 0 and usage[key] <= 9_007_199_254_740_991
       end) and Enum.any?(@usage_keys, &(usage[&1] > 0)),
       do: Map.take(usage, @usage_keys),
       else: nil
  end

  defp usage(_), do: nil
end
