defmodule Olympus.JournalTest do
  use ExUnit.Case, async: true

  test "hash chaining detects corruption, truncation and reordered frames" do
    path = Path.join(System.tmp_dir!(), "olympus-journal-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(path) end)
    {:ok, j, []} = Olympus.Journal.open(path)
    {:ok, j, first} = Olympus.Journal.append(j, :harmony, %{state: %{epoch: 1}})
    {:ok, j, second} = Olympus.Journal.append(j, :thread_cut, %{state: %{epoch: 2}})
    Olympus.Journal.close(j)
    {:ok, j, [^first, ^second]} = Olympus.Journal.open(path)
    Olympus.Journal.close(j)
    bytes = File.read!(path)
    File.write!(path, binary_part(bytes, 0, byte_size(bytes) - 1))
    assert {:error, :journal_truncated} = Olympus.Journal.open(path)
    <<size::32, _::binary-size(32), _::binary-size(size), second_frame::binary>> = bytes
    first_size = size + 36
    File.write!(path, second_frame <> binary_part(bytes, 0, first_size))
    assert {:error, :journal_checksum} = Olympus.Journal.open(path)
    <<head, tail::binary>> = bytes
    File.write!(path, <<Bitwise.bxor(head, 1), tail::binary>>)
    assert {:error, _} = Olympus.Journal.open(path)
  end
end
