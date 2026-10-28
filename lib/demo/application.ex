defmodule Demo.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # A supervisor for ad-hoc tasks. Every node in the cluster runs one under
      # the same name, so we can address `{Demo.TaskSup, node}` from anywhere.
      {Task.Supervisor, name: Demo.TaskSup},
      # The default :pg scope for cluster-wide process groups.
      %{id: :pg, start: {:pg, :start_link, []}}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Demo.Supervisor)
  end
end
