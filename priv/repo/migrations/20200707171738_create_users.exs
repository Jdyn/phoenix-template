defmodule Nimble.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add(:email, :string, null: false)
      add(:first_name, :string)
      add(:last_name, :string)
      add(:avatar, :string)

      add(:phone, :string)

      add(:password_hash, :string, null: true)
      add(:confirmed_at, :naive_datetime)

      add(:is_admin, :boolean, default: false, null: false)

      timestamps()
    end

    create(constraint(:users, :valid_identifier, check: "num_nulls(email, phone) <= 1"))
    create unique_index(:users, [:email])
    create unique_index(:users, [:phone])

  end
end
