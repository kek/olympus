defmodule Olympus.UsageTest do
  use ExUnit.Case
  alias Olympus.{Adapter, Usage}

  @tokens %{
    "input" => 11,
    "output" => 7,
    "cacheRead" => 0,
    "cacheWrite" => 0,
    "totalTokens" => 18
  }

  defmodule Legacy do
    @behaviour Adapter
    def respond(_, _),
      do:
        {:ok,
         %{"artifact" => %{"ok" => true}, "_olympus_call" => %{"usage" => %{"output" => 99999}}}}
  end

  defmodule Measured do
    @behaviour Adapter
    def respond(req, opts) do
      case respond_with_usage(req, opts) do
        {:ok, body, _} -> {:ok, body}
        {:error, reason, _} -> {:error, reason}
      end
    end

    def respond_with_usage(_, opts) do
      if opts[:raise], do: raise("PRIVATE_ERROR")
      meta = opts[:meta]

      if opts[:fail],
        do: {:error, :test_failure, meta},
        else: {:ok, %{"artifact" => %{"ok" => true}}, meta}
    end
  end

  defp request, do: %{action: :propose, budget: 37}

  defp meta,
    do: %{
      "provider" => "test",
      "model" => "model",
      "usage_format" => "pi-sdk",
      "usage" => @tokens
    }

  test "optional usage callback is additive and legacy model-authored metadata is not trusted" do
    {{:ok, body}, call} = Adapter.invoke(Legacy, request(), [])
    assert body["_olympus_call"]["usage"]["output"] == 99999
    assert call["usage"] == nil
    assert call["elapsed_ms"] >= 0
    assert call["completion_allowance"] == 37
    assert call["adapter"] == "Elixir.Olympus.UsageTest.Legacy"

    {{:ok, _}, call} =
      Adapter.invoke(Measured, request(), meta: Map.put(meta(), "secret", "PRIVATE"))

    assert call["usage"] == @tokens
    assert call["provider"] == "test"
    refute call |> Olympus.JSON.encode() |> IO.iodata_to_binary() |> String.contains?("PRIVATE")
  end

  test "missing, zero-filled, negative and malformed counters stay unknown" do
    for usage <- [
          nil,
          %{},
          Map.new(@tokens, fn {k, _} -> {k, 0} end),
          Map.put(@tokens, "output", -1),
          Map.put(@tokens, "input", "11")
        ] do
      {{:ok, _}, call} =
        Adapter.invoke(Measured, request(), meta: Map.put(meta(), "usage", usage))

      assert call["usage"] == nil
    end
  end

  test "failed calls can retain reported usage and exceptions do not expose errors" do
    {{:error, :test_failure}, call} =
      Adapter.invoke(Measured, request(), meta: meta(), fail: true)

    assert call["status"] == "error"
    assert call["usage"] == @tokens
    {{:error, :adapter_failed}, call} = Adapter.invoke(Measured, request(), raise: true)
    assert call["usage"] == nil

    refute call
           |> Olympus.JSON.encode()
           |> IO.iodata_to_binary()
           |> String.contains?("PRIVATE_ERROR")
  end

  test "summaries expose partial coverage and do not turn missing slots into zero consumption" do
    {_, known} = Adapter.invoke(Measured, request(), meta: meta())
    {_, legacy} = Adapter.invoke(Legacy, %{request() | action: :review}, [])

    result = %{
      rounds: [
        %{
          candidates: [
            %{
              attempts: [%{"call" => known}, %{"status" => "search_timeout"}],
              review: %{call: legacy}
            },
            %{attempts: [], call: known, review: nil}
          ]
        }
      ]
    }

    summary = Usage.summarize(result)
    assert summary["recorded_adapter_calls"] == 3
    assert summary["unmeasured_slots"] == 1
    assert summary["usage_known_calls"] == 2
    assert summary["usage_unknown_calls"] == 1
    assert summary["reported_usage_subtotal"]["totalTokens"] == 36
    refute summary["usage_complete"]
    old = Usage.summarize(%{rounds: [%{candidates: [%{review: %{reviewer: "ares"}}]}]})
    assert old["unmeasured_slots"] == 2
    assert old["reported_usage_subtotal"] == nil
    assert old["adapter_elapsed_ms_sum"] == nil
  end

  test "over-allowance usage is observable without changing acceptance" do
    reported = put_in(meta(), ["usage", "output"], 100)
    {_, call} = Adapter.invoke(Measured, request(), meta: reported, fail: true)
    summary = Usage.summarize(%{rounds: [%{candidates: [%{call: call, review: nil}]}]})
    assert summary["usage_complete"]
    assert summary["error_calls"] == 1
    assert summary["reported_output_over_allowance_calls"] == 1
  end

  test "usage summaries survive replay without reinterpreting old calls" do
    journal =
      Path.join(System.tmp_dir!(), "usage-replay-#{Base.encode16(:crypto.strong_rand_bytes(8))}")

    on_exit(fn -> File.rm(journal) end)

    fate =
      start_supervised!(
        {Olympus.Fate, [journal: journal, adapter: Measured, adapter_opts: [meta: meta()]]}
      )

    {:ok, result} =
      Olympus.pray(fate, %{
        "id" => "replay",
        "request" => "Return valid data",
        "checks" => [%{"path" => ["ok"], "op" => "eq", "value" => true}],
        "rounds" => 1
      })

    summary = Usage.summarize(result)
    assert summary["usage_complete"]
    assert summary["reported_usage_subtotal"]["totalTokens"] == 108
    stop_supervised!(Olympus.Fate)
    resumed = start_supervised!({Olympus.Fate, [journal: journal, adapter: Legacy]})
    assert {:ok, ^summary} = Olympus.usage(resumed, "replay")
  end

  test "Fate stores authority-owned call metadata outside model artifacts" do
    journal = Path.join(System.tmp_dir!(), "usage-#{Base.encode16(:crypto.strong_rand_bytes(8))}")
    on_exit(fn -> File.rm(journal) end)
    fate = start_supervised!({Olympus.Fate, [journal: journal, adapter: Legacy]})

    {:ok, result} =
      Olympus.pray(fate, %{
        "id" => "usage",
        "request" => "Return valid data",
        "checks" => [%{"path" => ["ok"], "op" => "eq", "value" => true}],
        "rounds" => 1
      })

    assert result.status == :harmonious
    assert Enum.all?(hd(result.rounds).candidates, &is_nil(&1.call["usage"]))
    assert Usage.summarize(result)["recorded_adapter_calls"] == 6
    assert {:ok, summary} = Olympus.usage(fate, "usage")
    assert summary == Usage.summarize(result)
    assert {:error, :episode_not_found} = Olympus.usage(fate, "absent")
    refute Usage.summarize(result)["usage_complete"]
  end
end
