defmodule Olympus.Contract do
  @moduledoc """
  Clotho compiles a bounded declarative prayer. Lachesis evaluates it.
  Only string-keyed JSON data and a closed predicate vocabulary are accepted.
  No callbacks, shell commands, executable fixtures, or mutable test paths.
  """
  @enforce_keys [
    :id,
    :request,
    :checks,
    :objective,
    :rounds,
    :timeout_ms,
    :tokens,
    :max_bytes,
    :digest,
    :law_version
  ]
  defstruct @enforce_keys ++ [evaluation: nil]

  def compile(prayer) when is_map(prayer) do
    with true <- :erlang.external_size(prayer) <= 131_072,
         true <-
           Map.keys(prayer) -- ~w(id request checks objective rounds timeout_ms tokens max_bytes) ==
             [],
         id when is_binary(id) and byte_size(id) in 1..128 <- prayer["id"],
         request when is_binary(request) and byte_size(request) in 1..16_384 <- prayer["request"],
         checks when is_list(checks) and length(checks) in 1..128 <- prayer["checks"],
         true <- Enum.all?(checks, &valid_check?/1),
         objective <- prayer["objective"],
         true <- valid_objective?(objective),
         rounds <- Map.get(prayer, "rounds", 3),
         true <- rounds in [1, 3, 5, 7, 9],
         timeout <- Map.get(prayer, "timeout_ms", 5_000),
         true <- is_integer(timeout) and timeout in 1..120_000,
         tokens <- Map.get(prayer, "tokens", 2_000),
         true <- is_integer(tokens) and tokens in 1..100_000,
         bytes <- Map.get(prayer, "max_bytes", 65_536),
         true <- is_integer(bytes) and bytes in 1..1_048_576,
         true <- json?(prayer) do
      fields = %{
        law_version: 1,
        id: id,
        request: request,
        checks: checks,
        objective: objective,
        rounds: rounds,
        timeout_ms: timeout,
        tokens: tokens,
        max_bytes: bytes
      }

      digest =
        :crypto.hash(:sha256, :erlang.term_to_binary(fields, [:deterministic]))
        |> Base.encode16(case: :lower)

      {:ok, struct!(__MODULE__, Map.put(fields, :digest, digest))}
    else
      _ -> {:error, :invalid_contract}
    end
  end

  def compile(_), do: {:error, :invalid_contract}

  def valid_check?(%{"path" => path, "op" => op} = check) do
    allowed = if op in ["exists", "unique"], do: ~w(path op), else: ~w(path op value)

    Map.keys(check) |> Enum.sort() == Enum.sort(allowed) and
      path?(path) and op in ~w(exists eq neq lte gte length_lte length_gte contains unique) and
      (op in ["exists", "unique"] or json?(check["value"])) and
      (op not in ~w(lte gte) or is_number(check["value"])) and
      (op not in ~w(length_lte length_gte) or
         (is_integer(check["value"]) and check["value"] >= 0))
  end

  def valid_check?(_), do: false

  defp valid_objective?(nil), do: true

  defp valid_objective?(%{"path" => path, "direction" => direction} = obj),
    do: map_size(obj) == 2 and path?(path) and direction in ["min", "max"]

  defp valid_objective?(_), do: false

  defp path?(path),
    do:
      is_list(path) and length(path) <= 32 and
        Enum.all?(path, &(is_binary(&1) or (is_integer(&1) and &1 >= 0)))

  def json?(value), do: json?(value, 0)
  defp json?(_, depth) when depth > 64, do: false
  defp json?(value, _) when is_binary(value), do: String.valid?(value)
  defp json?(value, _) when is_number(value) or is_boolean(value) or is_nil(value), do: true
  defp json?(value, depth) when is_list(value), do: Enum.all?(value, &json?(&1, depth + 1))

  defp json?(value, depth) when is_map(value),
    do:
      Enum.all?(value, fn {k, v} -> is_binary(k) and String.valid?(k) and json?(v, depth + 1) end)

  defp json?(_, _), do: false

  def measure(contract, artifact) do
    cond do
      :erlang.external_size(artifact) > contract.max_bytes * 8 + 4096 ->
        {:error, :artifact_budget}

      not json?(artifact) ->
        {:error, :not_json}

      byte_size(Olympus.JSON.encode(artifact) |> IO.iodata_to_binary()) > contract.max_bytes ->
        {:error, :artifact_budget}

      true ->
        failed =
          contract.checks
          |> Enum.with_index()
          |> Enum.reject(fn {c, _} -> holds?(c, artifact) end)
          |> Enum.map(&elem(&1, 1))

        if failed == [],
          do: score(contract.objective, artifact),
          else: {:error, {:invariants, failed}}
    end
  end

  defp score(nil, _), do: {:ok, 0}

  defp score(%{"path" => path, "direction" => direction}, artifact) do
    case fetch(artifact, path) do
      {:ok, value} when is_number(value) -> {:ok, if(direction == "min", do: -value, else: value)}
      _ -> {:error, :missing_numeric_objective}
    end
  end

  def holds?(check, artifact) do
    case fetch(artifact, check["path"]) do
      {:ok, value} -> compare(check["op"], value, check["value"])
      :error -> false
    end
  end

  defp compare("exists", _, _), do: true
  defp compare("eq", a, b), do: a === b
  defp compare("neq", a, b), do: a !== b
  defp compare("lte", a, b), do: is_number(a) and a <= b
  defp compare("gte", a, b), do: is_number(a) and a >= b
  defp compare("length_lte", a, b), do: length_of(a) >= 0 and length_of(a) <= b
  defp compare("length_gte", a, b), do: length_of(a) >= b and length_of(a) >= 0
  defp compare("contains", a, b), do: is_list(a) and b in a
  defp compare("unique", a, _), do: is_list(a) and length(Enum.uniq(a)) == length(a)
  defp length_of(a) when is_list(a), do: length(a)
  defp length_of(a) when is_binary(a), do: String.length(a)
  defp length_of(_), do: -1

  def fetch(value, []), do: {:ok, value}

  def fetch(value, [key | rest]) when is_map(value) do
    case Map.fetch(value, key) do
      {:ok, next} -> fetch(next, rest)
      :error -> :error
    end
  end

  def fetch(value, [index | rest]) when is_list(value) and is_integer(index) do
    case Enum.fetch(value, index) do
      {:ok, next} -> fetch(next, rest)
      :error -> :error
    end
  end

  def fetch(_, _), do: :error
end
