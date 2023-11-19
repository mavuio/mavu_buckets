defmodule MavuBuckets.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children = [
      {MavuBuckets.BucketSupervisor, []},
      {MavuBuckets.GarbageCollector, []},
      {Registry, [keys: :unique, name: :mavu_buckets_registry]}
    ]

    opts = [strategy: :one_for_one, name: MavuBuckets.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
