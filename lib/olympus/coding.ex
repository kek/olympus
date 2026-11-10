defmodule Olympus.Coding do
  @moduledoc """
  Sealed black-box coding evaluator. Acceptance cases stay outside candidate
  containers; the trusted host compares stdout and exit status independently.
  No candidate command or test runner runs in the authority VM.
  """
  alias Olympus.Subprocess

  def prepare(opts, realm \\ nil)
  def prepare(nil, _realm), do: {:ok, nil}

  def prepare(opts, realm) when is_list(opts) do
    owner =
      :crypto.hash(:sha256, realm || :crypto.strong_rand_bytes(32)) |> Base.encode16(case: :lower)

    config =
      Map.new(opts, fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.put("owner", owner)

    helper(%{"action" => "prepare", "config" => config}, 30_000, 2_097_152)
  end

  def bind(contract, nil), do: contract

  def bind(contract, profile) do
    contract = %{contract | evaluation: profile["manifest"], law_version: 2}
    fields = contract |> Map.from_struct() |> Map.delete(:digest)

    digest =
      :crypto.hash(:sha256, :erlang.term_to_binary(fields, [:deterministic]))
      |> Base.encode16(case: :lower)

    %{contract | digest: digest}
  end

  def context(nil), do: nil
  def context(profile), do: Map.take(profile, ["files", "modes", "editable", "manifest"])

  def evaluate(nil, artifact, _timeout), do: {:ok, artifact}

  def evaluate(profile, artifact, timeout) when timeout > 0 do
    helper(
      %{
        "action" => "evaluate",
        "profile" => profile,
        "artifact" => artifact,
        "timeout_ms" => timeout
      },
      timeout,
      2_097_152
    )
  end

  def evaluate(_, _, _), do: {:error, :evaluation_timeout}

  def passed?(nil, _), do: true
  def passed?(_, %{"evaluation" => %{"passed" => true}}), do: true
  def passed?(_, _), do: false

  defp helper(input, timeout, limit) do
    case System.find_executable("python3") do
      nil ->
        {:error, :python_required}

      python ->
        script = Application.app_dir(:olympus, "priv/coding/runner.py")
        Subprocess.json(python, ["-I", "-B", script], input, timeout, limit)
    end
  end
end
