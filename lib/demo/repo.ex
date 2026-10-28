# Postgres types that use Elixir's built-in JSON module for json/jsonb
# columns (Postgrex would otherwise look for the Jason library).
Postgrex.Types.define(Demo.PostgresTypes, [], json: JSON)

defmodule Demo.Repo do
  @moduledoc """
  Postgres for the chat (messages and created channels).

  Configured from the `DATABASE_URL` environment variable rather than Mix
  config, so peer nodes started with `:peer` (which inherit the environment
  but not Mix config) connect the same way.
  """
  use Ecto.Repo, otp_app: :demo, adapter: Ecto.Adapters.Postgres

  @default_url "ecto://postgres:postgres@localhost:5433/beam_chat"

  def url, do: System.get_env("DATABASE_URL", @default_url)

  @impl true
  def init(_context, config) do
    # A small pool per node: a cluster has many nodes sharing one database.
    {:ok, Keyword.merge(config, url: url(), pool_size: 2, types: Demo.PostgresTypes)}
  end

  @doc "Runs pending migrations. Called once, by the node that starts the cluster."
  def migrate! do
    path = Application.app_dir(:demo, "priv/repo/migrations")

    {:ok, _, _} =
      Ecto.Migrator.with_repo(__MODULE__, &Ecto.Migrator.run(&1, path, :up, all: true))

    :ok
  end
end

defmodule Demo.Chat.Schema.Message do
  @moduledoc false
  use Ecto.Schema

  schema "messages" do
    field :channel, :string
    field :user_name, :string
    field :color, :string
    field :node, :string
    field :text, :string, default: ""
    field :gif, :map
    field :system, :boolean, default: false
    timestamps type: :utc_datetime_usec, updated_at: false
  end
end

defmodule Demo.Chat.Schema.Channel do
  @moduledoc false
  use Ecto.Schema

  schema "channels" do
    field :kind, :string
    field :name, :string
    field :title, :string
    field :topic, :string, default: ""
    field :created_by, :string
    field :created_on, :string
    timestamps type: :utc_datetime_usec, updated_at: false
  end
end
