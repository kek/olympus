defmodule Olympus.Adapters.Demo do
  @moduledoc "Offline deterministic contenders for the runnable example; not an LLM."
  @behaviour Olympus.Adapter

  def respond(%{action: :propose, god: god}, _) do
    case god do
      "ares" ->
        {:ok, %{"artifact" => %{"steps" => ["ship"], "cost" => 1, "compatible" => false}}}

      "athena" ->
        {:ok,
         %{
           "artifact" => %{
             "steps" => ["design", "build", "verify"],
             "cost" => 3,
             "compatible" => true
           }
         }}

      _ ->
        {:ok,
         %{"artifact" => %{"steps" => ["build", "verify"], "cost" => 2, "compatible" => true}}}
    end
  end

  def respond(%{action: :review, contract: contract, artifact: artifact}, _) do
    objections =
      contract["checks"]
      |> Enum.with_index()
      |> Enum.reject(fn {check, _} ->
        Olympus.Contract.holds?(check, artifact)
      end)
      |> Enum.map(&elem(&1, 1))

    {:ok, %{"objections" => objections}}
  end
end
