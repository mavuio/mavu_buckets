defmodule MavuBuckets.Repo.Migrations.ExtendBuckets do
  use Ecto.Migration

  #update from 1.0:

  def change do
    alter table(:buckets) do
      add(:protect_until, :utc_datetime)
      add(:persistence_level, :integer, default: 10, null: false)
      add(:size, :integer, default: 0, null: false)
    end
  end
end
