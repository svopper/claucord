defmodule Demo.Repo.Migrations.CreateChatTables do
  use Ecto.Migration

  def change do
    create table(:channels) do
      add :kind, :string, null: false
      add :name, :string, null: false
      add :title, :string, null: false
      add :topic, :string, null: false, default: ""
      add :created_by, :string
      add :created_on, :string
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:channels, [:kind, :name])

    create table(:messages) do
      add :channel, :string, null: false
      add :user_name, :string
      add :color, :string
      add :node, :string
      add :text, :text, null: false, default: ""
      add :gif, :map
      add :system, :boolean, null: false, default: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:messages, [:channel, :id])
  end
end
