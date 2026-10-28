defmodule Demo.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # The default :pg scope for cluster-wide process groups.
      %{id: :pg, start: {:pg, :start_link, []}}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Demo.Supervisor)
  end
end
