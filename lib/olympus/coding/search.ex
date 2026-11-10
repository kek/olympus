defmodule Olympus.Coding.Search do
  @moduledoc """
  Bounded propose/evaluate/repair search inside one Fate reservation.
  Feedback is an intentionally limited acceptance oracle: no case contents,
  program output, exit-code values, output hashes, or candidate diagnostics.
  """
  alias Olympus.{Coding, Contract, JSON, Politics}

  def allowances(budget, attempts) when budget > 0 and attempts in 1..3 do
    count = min(budget, attempts)

    for index <- 1..count,
        do: div(budget, count) + if(index <= rem(budget, count), do: 1, else: 0)
  end

  def run(adapter, opts, request, profile, deadline, progress \\ fn _ -> :ok end) do
    contract =
      struct!(
        Contract,
        Map.new(Map.from_struct(Contract.__struct__()), fn {key, _} ->
          {key, Map.fetch!(request.contract, Atom.to_string(key))}
        end)
      )

    initial_oaths = get_in(request.identity, [:ambrosia, :oaths]) || []
    initial = %{last: nil, changes: %{}, oaths: initial_oaths, trace: [], feedback: nil}

    state =
      allowances(request.budget, profile["manifest"]["max_attempts"])
      |> Enum.with_index(1)
      |> Enum.reduce_while(initial, fn {budget, index}, state ->
        if now() >= deadline do
          {:halt, state}
        else
          req = %{request | budget: budget, timeout_ms: max(deadline - now(), 1)}

          req =
            if index == 1,
              do: req,
              else:
                Map.put(req, :repair, %{
                  "attempt" => index,
                  "current_files" => Map.merge(profile["files"], state.changes),
                  "feedback" => state.feedback,
                  "oaths" => state.oaths
                })

          progress.(
            snapshot(state)
            |> Map.put("_olympus_inflight", %{"attempt" => index, "budget" => budget})
          )

          {decision, next} =
            step(adapter, opts, req, profile, contract, deadline, state, index, progress)

          progress.(snapshot(next))
          {decision, next}
        end
      end)

    {:ok, snapshot(state)}
  end

  defp snapshot(state) do
    terminal =
      case List.last(state.trace) do
        nil -> "not_started"
        record -> record["status"]
      end

    (state.last || %{})
    |> Map.put("_olympus_attempts", state.trace)
    |> Map.put("_olympus_terminal", terminal)
  end

  def interrupted(snapshot, status) do
    inflight = snapshot["_olympus_inflight"]
    trace = snapshot["_olympus_attempts"]
    trace = if inflight, do: trace ++ [Map.put(inflight, "status", status)], else: trace

    terminal =
      if snapshot["_olympus_terminal"] == "invalid_oath", do: "invalid_oath", else: status

    snapshot
    |> Map.delete("_olympus_inflight")
    |> Map.put("_olympus_attempts", trace)
    |> Map.put("_olympus_terminal", terminal)
  end

  defp step(adapter, opts, request, profile, contract, deadline, state, index, progress) do
    {proposal, call} = propose(adapter, opts, request)

    progress.(
      snapshot(state)
      |> Map.put("_olympus_inflight", %{
        "attempt" => index,
        "budget" => request.budget,
        "call" => call
      })
    )

    with {:ok, body} <- proposal,
         %{"artifact" => artifact} <- body,
         artifact <- accumulate(artifact, state.changes),
         {:ok, measured} <- Coding.evaluate(profile, artifact, deadline - now()),
         true <- bounded?(measured, request.max_bytes) do
      assessment = Politics.assess(contract, measured, body, %{oaths: state.oaths})
      passed = Coding.passed?(profile, measured) and match?({:ok, _}, assessment.measurement)

      status =
        cond do
          assessment.measurement == {:error, :invalid_oath} ->
            "invalid_oath"

          assessment.broken != [] ->
            "oath_broken"

          Enum.any?(measured["evaluation"]["cases"], &(&1["reason"] == "engine_error")) ->
            "evaluation_failed"

          passed ->
            "passed"

          not Coding.passed?(profile, measured) ->
            "acceptance_failed"

          true ->
            "contract_failed"
        end

      # Commit only validated oaths. A later invalid declaration must not erase earlier ones.
      oaths = assessment.oaths

      last = %{"artifact" => measured, "oaths" => oaths}

      record = %{
        "attempt" => index,
        "budget" => request.budget,
        "call" => call,
        "status" => status,
        "artifact" => measured,
        "oaths" => oaths
      }

      state = %{
        state
        | last: last,
          changes: measured["files"],
          oaths: assessment.oaths,
          trace: state.trace ++ [record],
          feedback: feedback(measured, status)
      }

      if passed or status in ["invalid_oath", "oath_broken", "evaluation_failed"],
        do: {:halt, state},
        else: {:cont, state}
    else
      {:error, {:helper, reason}} ->
        invalid_patch =
          reason in ["invalid_patch", "forbidden_path", "patch_budget", "empty_or_large_patch"]

        failed(
          state,
          index,
          request.budget,
          if(invalid_patch, do: "invalid_patch", else: "evaluation_failed"),
          call
        )

      {:error, :response_budget} ->
        failed(state, index, request.budget, "response_budget", call)

      {:error, :invalid_response} ->
        failed(state, index, request.budget, "invalid_response", call)

      {:error, _} ->
        failed(state, index, request.budget, "adapter_or_evaluation_failed", call)

      false ->
        failed(state, index, request.budget, "response_budget", call)

      _ ->
        failed(state, index, request.budget, "invalid_patch", call)
    end
  end

  defp propose(adapter, opts, request) do
    {response, call} = Olympus.Adapter.invoke(adapter, request, opts)

    proposal =
      case response do
        {:ok, body} when is_map(body) ->
          if bounded?(body, request.max_bytes), do: {:ok, body}, else: {:error, :response_budget}

        _ ->
          {:error, :invalid_response}
      end

    {proposal, call}
  end

  defp accumulate(%{"files" => edits} = artifact, previous)
       when map_size(artifact) == 1 and is_map(edits),
       do: %{"files" => Map.merge(previous, edits)}

  defp accumulate(artifact, _), do: artifact

  defp failed(state, index, budget, status, call) do
    record = %{"attempt" => index, "budget" => budget, "status" => status, "call" => call}
    {:halt, %{state | trace: state.trace ++ [record], feedback: %{"status" => status}}}
  end

  def feedback(%{"evaluation" => evidence}, status) do
    failures =
      evidence["cases"]
      |> Enum.reject(& &1["passed"])
      |> Enum.map(fn c ->
        cond do
          c["reason"] == "output_budget" -> "output_budget"
          c["reason"] in ["timeout", "killed_or_timeout", "cancelled"] -> "time_or_process_limit"
          c["exit_code"] != 0 -> "nonzero_exit"
          true -> "stdout_mismatch"
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    %{
      "status" => status,
      "tests_passed" => evidence["tests_passed"],
      "tests_total" => evidence["tests_total"],
      "failure_categories" => failures
    }
  end

  defp bounded?(value, limit) do
    :erlang.external_size(value) <= limit * 8 + 4096 and Contract.json?(value) and
      byte_size(JSON.encode(value) |> IO.iodata_to_binary()) <= limit
  rescue
    _ -> false
  end

  defp now, do: System.monotonic_time(:millisecond)
end
