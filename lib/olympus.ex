defmodule Olympus do
  @moduledoc "Public entry point for supervised, autonomous artifact contests."
  def start_realm(opts), do: DynamicSupervisor.start_child(Olympus.Realms, {Olympus.Fate, opts})
  defdelegate pray(realm, prayer), to: Olympus.Fate
  defdelegate status(realm), to: Olympus.Fate
  defdelegate events(realm), to: Olympus.Fate
  defdelegate epic(realm), to: Olympus.Fate

  def usage(realm, episode_id) do
    case Map.fetch(status(realm).episodes, episode_id) do
      {:ok, result} -> {:ok, Olympus.Usage.summarize(result)}
      :error -> {:error, :episode_not_found}
    end
  end
end
