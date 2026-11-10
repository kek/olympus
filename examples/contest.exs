journal = System.get_env("OLYMPUS_JOURNAL", "var/demo.journal")
{:ok, realm} = Olympus.start_realm(journal: journal, adapter: Olympus.Adapters.Demo)

prayer = %{
  "id" => "first-city",
  "request" => "Build the cheapest compatible delivery plan with at least two distinct steps.",
  "checks" => [
    %{"path" => ["compatible"], "op" => "eq", "value" => true},
    %{"path" => ["steps"], "op" => "length_gte", "value" => 2},
    %{"path" => ["steps"], "op" => "unique"}
  ],
  "objective" => %{"path" => ["cost"], "direction" => "min"},
  "rounds" => 3,
  "timeout_ms" => 2_000,
  "tokens" => 2_400
}

case Olympus.pray(realm, prayer) do
  {:ok, result} ->
    IO.inspect(Map.take(result, [:status, :winner, :artifact, :sponsor]), label: "Settlement")

  {:error, :episode_exists} ->
    IO.puts("Already settled; replaying the epic.")

  error ->
    IO.inspect(error)
end

IO.puts(Olympus.epic(realm))
