defmodule Olympus.Application do
  use Application

  def start(_type, _args) do
    Supervisor.start_link(
      [
        {Registry, keys: :unique, name: Olympus.Registry},
        {Task.Supervisor, name: Olympus.Tasks},
        {DynamicSupervisor, strategy: :one_for_one, name: Olympus.Pantheon},
        {DynamicSupervisor, strategy: :one_for_one, name: Olympus.Realms}
      ],
      strategy: :rest_for_one,
      name: Olympus.Supervisor
    )
  end
end
