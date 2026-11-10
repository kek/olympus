defmodule Olympus.God do
  @moduledoc "Supervised identity and disposable working context. Durable ambrosia belongs to Fate."
  use GenServer

  @catalog [
    {"zeus", "settlement", "athena"},
    {"athena", "architecture", "hephaestus"},
    {"ares", "speed and adversarial testing", "aphrodite"},
    {"hephaestus", "implementation and tooling", "hera"},
    {"aphrodite", "ergonomics", "ares"},
    {"hera", "compatibility", "hephaestus"},
    {"apollo", "clarity and performance", "athena"},
    {"hermes", "integration", "dionysus"},
    {"hades", "deprecation", "hera"},
    {"dionysus", "exploration and fuzzing", "hermes"},
    {"nemesis", "complexity", "hera"},
    {"eris", "competing alternatives", "dionysus"}
  ]

  def catalog, do: @catalog
  def names, do: Enum.map(@catalog, &elem(&1, 0))
  def allies(name), do: for({^name, _, ally} <- @catalog, do: ally)
  def domain(name), do: Enum.find_value(@catalog, fn {n, d, _} -> if n == name, do: d end)

  def start_link({realm, name}) do
    GenServer.start_link(__MODULE__, name, name: via(realm, name))
  end

  def child_spec(args),
    do: %{id: args, start: {__MODULE__, :start_link, [args]}, restart: :permanent}

  defp via(realm, name), do: {:via, Registry, {Olympus.Registry, {realm, name}}}
  def init(name), do: {:ok, %{name: name, context: []}}

  def context(realm, name, ambrosia) do
    GenServer.call(via(realm, name), {:context, ambrosia})
  end

  def lethe(realm, name), do: GenServer.call(via(realm, name), :lethe)

  def handle_call({:context, ambrosia}, _, state) do
    {:reply, Map.merge(state, %{domain: domain(state.name), ambrosia: ambrosia}), state}
  end

  def handle_call(:lethe, _, state), do: {:reply, :ok, %{state | context: []}}
end
