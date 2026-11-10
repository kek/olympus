defmodule Olympus.Homer do
  @moduledoc "A deterministic narrator. The journal, not the narration, is authoritative."
  def render(events) do
    Enum.map_join(events, "\n", fn event ->
      case event.type do
        :thread_spun ->
          c = event.data.contract
          "#{event.seq}. Clotho sealed #{c.id} (#{c.digest}); Atropos allotted #{c.timeout_ms}ms."

        :harmony ->
          r = event.data.result

          "#{event.seq}. #{r.winner} prevailed in #{r.id}, sponsored by #{r.sponsor}. Lachesis declared harmony."

        :thread_cut ->
          r = event.data.result
          "#{event.seq}. Atropos cut #{r.id}: #{r.reason}. No artifact ascended."
      end
    end)
  end
end
