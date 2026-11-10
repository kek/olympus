defmodule Olympus do
  @moduledoc "Public entry point for supervised, autonomous artifact contests."
  def start_realm(opts), do: DynamicSupervisor.start_child(Olympus.Realms, {Olympus.Fate, opts})
  defdelegate pray(realm, prayer), to: Olympus.Fate
  defdelegate status(realm), to: Olympus.Fate
  defdelegate events(realm), to: Olympus.Fate
  defdelegate epic(realm), to: Olympus.Fate
end
