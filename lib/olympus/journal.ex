defmodule Olympus.Journal do
  @moduledoc """
  Single-writer, fsynced, hash-chained event frames. Corruption and torn writes
  fail closed. Journals are trusted local state, not an executable interchange format.
  """
  @max_frame 16_777_216

  def open(path) do
    # Safe ETF decoding needs the fixed application atom vocabulary loaded on a cold VM.
    Enum.each(Application.spec(:olympus, :modules) || [], &Code.ensure_loaded!/1)
    File.mkdir_p!(Path.dirname(path))

    with {:ok, bytes} <- contents(path),
         {:ok, events, hash} <- replay(bytes, [], <<0::256>>, 1),
         {:ok, fd} <- :file.open(String.to_charlist(path), [:append, :binary, :raw]) do
      {:ok, %{fd: fd, hash: hash, seq: length(events)}, Enum.reverse(events)}
    end
  end

  defp contents(path) do
    case File.read(path) do
      {:error, :enoent} -> {:ok, <<>>}
      other -> other
    end
  end

  defp replay(<<>>, events, hash, _seq), do: {:ok, events, hash}

  defp replay(<<size::32, digest::binary-size(32), rest::binary>>, events, previous, seq)
       when size <= @max_frame and byte_size(rest) >= size do
    body = binary_part(rest, 0, size)
    tail = binary_part(rest, size, byte_size(rest) - size)

    if :crypto.hash(:sha256, previous <> body) == digest do
      event = :erlang.binary_to_term(body, [:safe])

      if event.version == 1 and event.seq == seq do
        replay(tail, [event | events], digest, seq + 1)
      else
        {:error, :journal_sequence}
      end
    else
      {:error, :journal_checksum}
    end
  rescue
    _ -> {:error, :journal_encoding}
  end

  defp replay(_, _, _, _), do: {:error, :journal_truncated}

  def append(journal, type, data) do
    event = %{version: 1, seq: journal.seq + 1, type: type, data: data}
    body = :erlang.term_to_binary(event, [:deterministic])
    digest = :crypto.hash(:sha256, journal.hash <> body)

    with true <- byte_size(body) <= @max_frame,
         :ok <- :file.write(journal.fd, <<byte_size(body)::32, digest::binary, body::binary>>),
         :ok <- :file.sync(journal.fd) do
      {:ok, %{journal | hash: digest, seq: event.seq}, event}
    else
      _ -> {:error, :journal_write}
    end
  end

  def close(journal), do: :file.close(journal.fd)
end
