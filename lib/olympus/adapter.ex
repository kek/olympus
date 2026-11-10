defmodule Olympus.Adapter do
  @moduledoc """
  Untrusted proposal source. A request has action, god, contract, budget,
  opponents, and optionally artifact. Return {:ok, JSON value} or {:error, reason}.
  Providers must honor max_tokens; Fate also bounds elapsed time and output bytes.
  Implementations run as disposable tasks, never as Fate callbacks.
  """
  @callback respond(map(), keyword()) :: {:ok, term()} | {:error, term()}
end
