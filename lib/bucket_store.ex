defmodule MavuBuckets.BucketStore do
  use Ecto.Schema
  import Ecto.Changeset

  schema "buckets" do
    field(:bkid, :string)
    field(:state, :binary)
    field(:protect_until, :utc_datetime)
    # ↓ 100 keep ,10 keep if possible,1: remove
    field(:persistence_level, :integer)
    field(:size, :integer)
    timestamps()
  end

  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [
      :bkid,
      :state,
      :protect_until,
      :persistence_level,
      :size
    ])
  end
end
