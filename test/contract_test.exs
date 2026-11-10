defmodule Olympus.ContractTest do
  use ExUnit.Case, async: true
  alias Olympus.Contract

  def prayer do
    %{
      "id" => "test",
      "request" => "Build a bounded plan",
      "checks" => [%{"path" => ["ok"], "op" => "eq", "value" => true}],
      "rounds" => 1
    }
  end

  test "Clotho seals equivalent prayers identically and rejects ambiguous or executable ones" do
    assert {:ok, c} = Contract.compile(prayer())
    assert {:ok, ^c} = Contract.compile(Map.new(Enum.reverse(Map.to_list(prayer()))))
    assert {:error, :invalid_contract} = Contract.compile("please build something")
    assert {:error, :invalid_contract} = Contract.compile(Map.put(prayer(), "command", "true"))

    for checks <- [
          [],
          [%{"path" => [], "op" => "eval", "value" => "true"}],
          [%{"path" => [], "op" => "eq", "value" => true, "override" => true}]
        ] do
      assert {:error, :invalid_contract} = Contract.compile(Map.put(prayer(), "checks", checks))
    end
  end

  test "Lachesis measures data rather than agent claims" do
    assert {:ok, c} = Contract.compile(prayer())
    assert {:ok, 0} = Contract.measure(c, %{"ok" => true})

    assert {:error, {:invariants, [0]}} =
             Contract.measure(c, %{"ok" => false, "approved" => true})

    assert {:error, :not_json} = Contract.measure(c, %{ok: true})
  end

  test "closed predicates handle wrong types and missing paths safely" do
    for op <- ~w(length_lte length_gte) do
      refute Contract.holds?(%{"path" => [], "op" => op, "value" => 0}, 123)
    end

    assert Contract.holds?(%{"path" => ["a", 0], "op" => "eq", "value" => 3}, %{"a" => [3]})
    refute Contract.holds?(%{"path" => ["a", 1], "op" => "exists"}, %{"a" => [3]})
    assert Contract.holds?(%{"path" => [], "op" => "unique"}, [1, 2])
    refute Contract.holds?(%{"path" => [], "op" => "unique"}, [1, 1])
    assert Contract.holds?(%{"path" => [], "op" => "contains", "value" => 1}, [1, 2])
  end

  test "objective and complexity budget are mandatory gates when specified" do
    p = prayer() |> Map.put("objective", %{"path" => ["cost"], "direction" => "min"})
    {:ok, c} = Contract.compile(p)
    assert {:ok, -3} = Contract.measure(c, %{"ok" => true, "cost" => 3})
    assert {:error, :missing_numeric_objective} = Contract.measure(c, %{"ok" => true})
    {:ok, tiny} = Contract.compile(Map.put(p, "max_bytes", 1))
    assert {:error, :artifact_budget} = Contract.measure(tiny, %{"ok" => true, "cost" => 3})
  end
end
