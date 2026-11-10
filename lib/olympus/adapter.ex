defmodule Olympus.Adapter do
  @moduledoc """
  Untrusted proposal source. A request has action, god, contract, budget,
  opponents, and optionally artifact. Return {:ok, JSON value} or {:error, reason}.
  Fate may invoke coding proposals repeatedly with disjoint attempt allowances.
  Provider-supported output caps, elapsed time and output bytes bound each call;
  native Codex completion usage is checked after generation.
  Implementations run as disposable tasks, never as Fate callbacks.
  """
  @callback respond(map(), keyword()) :: {:ok, term()} | {:error, term()}
end
