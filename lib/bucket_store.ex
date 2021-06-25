defmodule MavuBuckets.BucketStore do
  use Ecto.Schema
  import Ecto.Changeset

  schema "buckets" do
    field(:bkid, :string)
    field(:state, :binary)
    timestamps()
  end

  def changeset(struct, params \\ %{}) do
    struct
    |> cast(params, [
      :bkid,
      :state
    ])
  end
end
