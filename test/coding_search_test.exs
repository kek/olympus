defmodule Olympus.CodingSearchTest do
  use ExUnit.Case, async: true
  alias Olympus.Coding.Search

  test "allowances are positive, finite and conserve the original reservation" do
    for budget <- 1..100, attempts <- 1..3 do
      caps = Search.allowances(budget, attempts)
      assert length(caps) == min(budget, attempts)
      assert Enum.all?(caps, &(&1 > 0))
      assert Enum.sum(caps) == budget
      assert Enum.max(caps) - Enum.min(caps) <= 1
    end
  end

  defmodule Probe do
    @behaviour Olympus.Adapter
    def respond(req, opts) do
      send(opts[:observer], {:called, req.budget})
      Process.sleep(opts[:sleep] || 0)
      {:ok, %{}}
    end
  end

  defp request(budget) do
    {:ok, c} =
      Olympus.Contract.compile(%{
        "id" => "deadline",
        "request" => "Make a CLI",
        "checks" => [%{"path" => [], "op" => "exists"}]
      })

    %{
      budget: budget,
      timeout_ms: 1000,
      max_bytes: 4096,
      identity: %{ambrosia: %{oaths: []}},
      contract: Map.new(Map.from_struct(c), fn {k, v} -> {Atom.to_string(k), v} end)
    }
  end

  test "an expired shared deadline never starts another attempt" do
    profile = %{"manifest" => %{"max_attempts" => 3}, "files" => %{}}
    deadline = System.monotonic_time(:millisecond)

    assert {:ok, %{"_olympus_attempts" => []}} =
             Search.run(Probe, [observer: self()], request(3), profile, deadline - 1)

    refute_receive {:called, _}

    assert {:ok, result} =
             Search.run(
               Probe,
               [observer: self(), sleep: 25],
               request(3),
               profile,
               System.monotonic_time(:millisecond) + 10
             )

    assert length(result["_olympus_attempts"]) == 1
    assert_receive {:called, 1}
    refute_receive {:called, _}
  end

  test "tiny reservations never generate zero-budget calls" do
    profile = %{"manifest" => %{"max_attempts" => 3}, "files" => %{}}

    {:ok, result} =
      Search.run(
        Probe,
        [observer: self()],
        request(1),
        profile,
        System.monotonic_time(:millisecond) + 1000
      )

    assert Enum.map(result["_olympus_attempts"], & &1["budget"]) == [1]
    assert_receive {:called, 1}
    refute_receive {:called, _}
  end

  test "large admitted attempt-audit samples fit the journal frame ceiling" do
    for {rounds, contenders, attempts} <- [{9, 12, 3}, {1, 2, 1}] do
      bytes = div(1_048_576, rounds * contenders * (attempts + 1))

      artifact = %{
        "files" => %{"main.py" => String.duplicate("x", bytes - 100)},
        "evaluation" => %{"passed" => false}
      }

      assert IO.iodata_length(Olympus.JSON.encode(artifact)) <= bytes
      oath = %{"path" => [], "op" => "neq", "value" => String.duplicate("y", 7500)}
      assert :erlang.external_size([oath]) <= 8192

      trace =
        for n <- 1..attempts,
            do: %{
              "attempt" => n,
              "budget" => 1000,
              "status" => "acceptance_failed",
              "artifact" => artifact,
              "oaths" => [oath]
            }

      candidate = %{
        artifact: artifact,
        attempts: trace,
        oaths: [oath],
        broken: [oath],
        measurement: {:error, :oath_broken},
        review: nil
      }

      result = %{
        rounds: for(_ <- 1..rounds, do: %{candidates: List.duplicate(candidate, contenders)}),
        artifact: artifact,
        status: :cut
      }

      ledger =
        Map.new(
          1..12,
          &{&1, %{oaths: [oath], memory: List.duplicate(String.duplicate("e", 128), 16)}}
        )

      frame = %{
        version: 1,
        seq: 2,
        type: :thread_cut,
        data: %{
          result: result,
          state: %{ledger: ledger, champion: artifact},
          evaluation_profile: %{
            "files" => String.duplicate("z", 262_144),
            "cases" => [
              %{"stdin" => String.duplicate("i", 8192), "stdout" => String.duplicate("o", 8192)}
            ]
          }
        }
      }

      assert :erlang.external_size(frame) < 16_777_216
    end
  end

  test "repair feedback is a bounded aggregate oracle without candidate output channels" do
    measured = %{
      "evaluation" => %{
        "passed" => false,
        "tests_passed" => 0,
        "tests_total" => 3,
        "cases" => [
          %{
            "passed" => false,
            "reason" => "completed",
            "exit_code" => 73,
            "stdout_preview" => "PRIVATE_INPUT",
            "stderr_preview" => "PRIVATE_EXPECTED",
            "stdout_sha256" => "SECRET_HASH"
          },
          %{"passed" => false, "reason" => "output_budget", "exit_code" => 0},
          %{"passed" => false, "reason" => "completed", "exit_code" => 0}
        ]
      }
    }

    feedback = Search.feedback(measured, "acceptance_failed")

    assert feedback == %{
             "status" => "acceptance_failed",
             "tests_passed" => 0,
             "tests_total" => 3,
             "failure_categories" => ["nonzero_exit", "output_budget", "stdout_mismatch"]
           }

    text = Olympus.JSON.encode(feedback) |> IO.iodata_to_binary()
    refute text =~ "PRIVATE"
    refute text =~ "SECRET"
    refute text =~ "73"

    review =
      Olympus.Coding.for_review(%{}, Map.put(measured, "files", %{"main.py" => "print(0)"}))

    refute Map.has_key?(review["evaluation"], "cases")
    assert review["files"]["main.py"] == "print(0)"
  end
end
