defmodule MavuBuckets.BucketSupervisor do
  use DynamicSupervisor
  alias MavuBuckets.BucketGenServer
  alias MavuBuckets.BkHelpers
  @registry :mavu_buckets_registry

  def start_link(_arg),
    do: DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)

  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc false

  def find_or_create_child(bkid) when is_binary(bkid) do
    case get_pid_of_child(bkid) do
      nil ->
        case create_child(bkid) do
          {:ok, pid} -> pid
          _ -> nil
        end

      pid ->
        pid
    end
  end

  @doc false
  def get_pid_of_child(bkid) when is_binary(bkid) do
    case Registry.lookup(@registry, bkid) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc false
  def create_child(bkid) when is_binary(bkid) do
    spec = %{
      id: BucketGenServer,
      start: {BucketGenServer, :start_link, [bkid]},
      restart: :temporary
    }

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        pid
        |> BkHelpers.log("created child for #{bkid} with PID: ")

        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:error, :process_already_exists, pid}

      other ->
        {:error, other}
    end
  end
end
