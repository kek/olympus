defmodule Olympus.Usage do
  @moduledoc """
  Non-authoritative adapter-call accounting. Missing usage is unknown, not zero.
  Token fields retain Pi SDK semantics. This is not a billing ledger.
  """
  @keys ~w(input output cacheRead cacheWrite totalTokens)

  def summarize(%{rounds: rounds}) do
    slots =
      Enum.flat_map(rounds, fn round ->
        Enum.flat_map(round.candidates, fn candidate ->
          proposal =
            case Map.get(candidate, :attempts, []) do
              [] -> [Map.get(candidate, :call)]
              attempts -> Enum.map(attempts, &Map.get(&1, "call"))
            end

          review =
            case candidate.review do
              nil -> []
              review -> [Map.get(review, :call)]
            end

          proposal ++ review
        end)
      end)

    calls = Enum.filter(slots, &is_map/1)
    reported = Enum.filter(calls, &is_map(&1["usage"]))

    subtotal =
      if reported == [],
        do: nil,
        else:
          Map.new(@keys, fn key ->
            {key, Enum.reduce(reported, 0, fn call, sum -> sum + call["usage"][key] end)}
          end)

    %{
      "recorded_adapter_calls" => length(calls),
      "unmeasured_slots" => length(slots) - length(calls),
      "usage_known_calls" => length(reported),
      "usage_unknown_calls" => length(calls) - length(reported),
      "usage_complete" => slots != [] and length(reported) == length(slots),
      "reported_usage_subtotal" => subtotal,
      "adapter_elapsed_ms_sum" =>
        if(calls == [], do: nil, else: Enum.sum(Enum.map(calls, & &1["elapsed_ms"]))),
      "error_calls" => Enum.count(calls, &(&1["status"] == "error")),
      "reported_output_over_allowance_calls" =>
        Enum.count(
          reported,
          &(&1["usage"]["output"] > &1["completion_allowance"])
        )
    }
  end
end
