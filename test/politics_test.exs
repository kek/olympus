defmodule Olympus.PoliticsTest do
  use ExUnit.Case, async: true
  alias Olympus.{Contract, Politics}

  defp god do
    %{favor: 100, coma_until: 0, memory: [%{old: true}], generation: 0, oaths: []}
  end

  defp contract do
    {:ok, c} =
      Contract.compile(%{
        "id" => "oath",
        "request" => "Keep your word",
        "checks" => [%{"path" => [], "op" => "exists"}]
      })

    c
  end

  test "Styx binds future artifacts and broken commitments impose a two-epoch coma" do
    oath = %{"path" => ["compatible"], "op" => "eq", "value" => true}
    signed = Politics.assess(contract(), %{"compatible" => true}, %{"oaths" => [oath]}, god())
    assert signed.measurement == {:ok, 0}
    sworn = %{god() | oaths: signed.oaths}
    broken = Politics.assess(contract(), %{"compatible" => false}, %{}, sworn)
    assert broken.measurement == {:error, :oath_broken}
    candidate = Map.merge(broken, %{god: "ares"})
    result = %{rounds: [%{candidates: [candidate]}], winner: nil, id: "oath", status: :cut}
    ledger = Politics.settle(%{"ares" => sworn}, result, 3, 0)
    assert ledger["ares"].coma_until == 5
    assert ledger["ares"].oaths == [oath]
  end

  test "Titanomachy challenger context is fresh, but office changes only after winning Fate's trial" do
    durable = %{stagnation: 3, ledger: %{"ares" => god()}}
    challenger = Politics.identity(durable, "ares")
    assert challenger.memory == []
    assert challenger.generation == 1
    assert durable.ledger["ares"].generation == 0

    loss = %{rounds: [], winner: nil, id: "trial", status: :cut}
    assert Politics.settle(durable.ledger, loss, 4, 3)["ares"].generation == 0
    win = %{loss | winner: "ares", status: :harmonious}
    assert Politics.settle(durable.ledger, win, 4, 3)["ares"].generation == 1
  end

  test "Lethe caps pathological grudges without forgiving ordinary enmity" do
    assert Politics.lethe(%{{"ares", "athena"} => -20, {"hera", "zeus"} => -11}) ==
             %{{"ares", "athena"} => -10, {"hera", "zeus"} => -11}
  end

  test "oaths cannot smuggle executable checks or unbounded persistent memory" do
    assert Politics.assess(contract(), %{}, %{"oaths" => [%{"op" => "exec"}]}, god()).measurement ==
             {:error, :invalid_oath}

    huge = %{"path" => [], "op" => "neq", "value" => String.duplicate("x", 9000)}
    result = Politics.assess(contract(), %{}, %{"oaths" => [huge]}, god())
    assert result.measurement == {:error, :invalid_oath}
    assert result.oaths == []
  end
end
