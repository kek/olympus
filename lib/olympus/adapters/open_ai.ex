defmodule Olympus.Adapters.OpenAI do
  @moduledoc """
  OpenAI-compatible chat completions over verified HTTPS. Options:
  :endpoint (full URL), :model, :api_key_env (default OPENAI_API_KEY).
  Never retries or invokes tools. Responses must be JSON objects.
  """
  @behaviour Olympus.Adapter

  def respond(request, opts) do
    endpoint = Keyword.fetch!(opts, :endpoint)
    uri = URI.parse(endpoint)

    if uri.scheme != "https" or not is_binary(uri.host) or uri.userinfo != nil do
      {:error, :https_required}
    else
      key = System.fetch_env!(Keyword.get(opts, :api_key_env, "OPENAI_API_KEY"))
      action = request.action

      instruction =
        if action == :propose do
          "Return only a JSON object: {\"artifact\": <your candidate>}. Compete to satisfy the sealed checks and optimize the objective."
        else
          "Return only a JSON object: {\"objections\": [zero-based indexes of sealed checks this artifact fails]}. Find real faults in your enemy's work. Never invent checks."
        end

      body =
        :json.encode(%{
          "model" => Keyword.fetch!(opts, :model),
          "max_tokens" => request.budget,
          "response_format" => %{"type" => "json_object"},
          "messages" => [
            %{"role" => "system", "content" => instruction},
            %{"role" => "user", "content" => :json.encode(wire(request)) |> IO.iodata_to_binary()}
          ]
        })
        |> IO.iodata_to_binary()

      headers = [{~c"authorization", String.to_charlist("Bearer " <> key)}]
      timeout = request.timeout_ms

      # Provider-side work may outlive a local task; the provider must enforce max_tokens.
      ssl = [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]

      with {:ok, ref} <-
             :httpc.request(
               :post,
               {String.to_charlist(endpoint), headers, ~c"application/json", body},
               [timeout: timeout, connect_timeout: timeout, ssl: ssl, autoredirect: false],
               sync: false,
               body_format: :binary
             ) do
        owner = self()

        guardian =
          spawn(fn ->
            monitor = Process.monitor(owner)

            receive do
              :done -> :ok
              {:DOWN, ^monitor, :process, ^owner, _} -> :httpc.cancel_request(ref)
            end
          end)

        try do
          receive do
            {:http, {^ref, {{_, 200, _}, _, response}}} -> decode(response, request.max_bytes)
            {:http, {^ref, _}} -> {:error, :provider_error}
          after
            timeout ->
              :httpc.cancel_request(ref)
              {:error, :provider_timeout}
          end
        after
          send(guardian, :done)
        end
      end
    end
  rescue
    _ -> {:error, :provider_error}
  end

  defp wire(request) do
    %{
      "action" => Atom.to_string(request.action),
      "god" => request.god,
      "identity" => inspect(request.identity),
      "contract" => request.contract,
      "artifact" => Map.get(request, :artifact),
      "opponents" => request.opponents
    }
  end

  defp decode(body, limit) when byte_size(body) <= limit * 4 + 8192 do
    with %{"choices" => [%{"message" => %{"content" => text}} | _]} <- :json.decode(body),
         true <- byte_size(text) <= limit,
         result when is_map(result) <- :json.decode(text) do
      {:ok, result}
    else
      _ -> {:error, :invalid_provider_response}
    end
  rescue
    _ -> {:error, :invalid_provider_response}
  end

  defp decode(_, _), do: {:error, :provider_response_budget}
end
