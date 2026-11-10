defmodule Olympus.JSONTest do
  use ExUnit.Case, async: true

  test "Elixir nil roundtrips as JSON null, never source text" do
    value = %{"file" => nil, "nested" => [nil, true, false]}
    bytes = Olympus.JSON.encode(value) |> IO.iodata_to_binary()
    assert bytes =~ "null"
    refute bytes =~ "nil"
    assert Olympus.JSON.decode(bytes) == value
  end
end
