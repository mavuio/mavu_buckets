defmodule MavuBuckets.Repo.Migrations.CreateBuckets do
  use Ecto.Migration

  def change do
    create table(:buckets) do
      add(:bkid, :string, null: false)
      add(:state, :binary)
      add(:protect_until, :utc_datetime)
      add(:persistence_level, :integer, default: 10, null: false)
      add(:size, :integer, default: 0, null: false)
      timestamps()
    end

    create(unique_index(:buckets, [:bkid]))
  end
end
