defmodule Olympus.JSON do
  @moduledoc false
  # OTP uses :null, while Elixir callers use nil. Never serialize nil as "nil".
  def encode(value) do
    :json.encode(value, fn
      nil, _ -> "null"
      item, encoder -> :json.encode_value(item, encoder)
    end)
  end

  def decode(bytes), do: bytes |> :json.decode() |> normalize()
  defp normalize(:null), do: nil
  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  defp normalize(value) when is_map(value), do: Map.new(value, fn {k, v} -> {k, normalize(v)} end)
  defp normalize(value), do: value
end
