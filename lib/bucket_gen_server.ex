defmodule MavuBuckets.BucketGenServer do
  use GenServer
  require Logger
  alias MavuBuckets.BucketSupervisor
  alias MavuBuckets.LiveUpdates
  alias MavuBuckets.BucketStore

  import MavuBuckets, only: [get_conf_val: 2]

  @registry :mavu_buckets_registry

  defstruct bkid: nil,
            data: %{}

  use Accessible

  ## API
  def start_link(bkid),
    do: GenServer.start_link(__MODULE__, bkid, name: via_tuple(bkid))

  def stop(bkid), do: GenServer.cast(via_tuple(bkid), :stop)

  def get_data(bkid, conf \\ []),
    do: GenServer.call(get_pid(bkid), {:get_data, conf |> Enum.into(%{})})

  def get_value(bkid, key, default \\ nil, conf \\ [])

  def get_value(nil, _, _, _), do: nil

  def get_value(bkid, key, default, conf) when is_binary(bkid) and is_binary(key),
    do: GenServer.call(get_pid(bkid), {:get_value, key, default, conf |> Enum.into(%{})})

  def set_value(bkid, key, value, conf \\ []) when is_binary(bkid) and is_binary(key),
    do: GenServer.call(get_pid(bkid), {:set_value, key, value, conf |> Enum.into(%{})})

  def update_value(bkid, key, callback, conf \\ [])
      when is_binary(bkid) and is_binary(key) and is_function(callback, 1),
      do: GenServer.call(get_pid(bkid), {:update_value, key, callback, conf |> Enum.into(%{})})

  def set_data(bkid, data, conf \\ []) when is_binary(bkid) and is_map(data),
    do: GenServer.call(get_pid(bkid), {:set_data, data, conf |> Enum.into(%{})})

  ## Callbacks
  @impl true
  def init(bkid) do
    MavuUtils.log("❖ init bucket '#{bkid}'")
    send(self(), :fetch_data)
    {:ok, %__MODULE__{bkid: bkid}}
  end

  @impl true
  def handle_cast(:work, bkid) do
    Logger.info("hola")
    {:noreply, bkid}
  end

  def handle_cast(:stop, state) do
    {:stop, :normal, state}
  end

  def handle_cast(:raise, bkid),
    do: raise(RuntimeError, message: "Error, Server #{bkid} has crashed")

  @impl true
  def handle_call({:get_data, conf}, _from, state) when is_map(conf) do
    response = state.data
    {:reply, response, state}
  end

  def handle_call({:get_value, key, default, conf}, _from, state) when is_map(conf) do
    response =
      get_in(state, [:data | get_key_parts(key)])
      |> case do
        nil -> default
        val -> val
      end

    {:reply, response, state}
  end

  def handle_call({:set_value, key, value, conf}, _from, old_state) when is_map(conf) do
    # value |> IO.inspect(label: "mwuits-debug 2020-03-15_12:05 visitor-session SET ")

    state =
      put_in(
        old_state,
        [
          :data
          # create empty map s default
          | Enum.map(get_key_parts(key), &Access.key(&1, %{}))
        ],
        value
      )

    if(state !== old_state) do
      LiveUpdates.notify_live_view(
        state.bkid,
        {:mavu_bucket, state.bkid, :set_value, value}
      )

      save_data_to_db(state.bkid, state.data, conf)
    end

    response = :ok
    {:reply, response, state}
  end

  def handle_call({:update_value, key, callback, conf}, _from, old_state) when is_map(conf) do
    # value |> IO.inspect(label: "mwuits-debug 2020-03-15_12:05 visitor-session SET ")

    state =
      update_in(
        old_state,
        [
          :data
          # create empty map s default
          | Enum.map(get_key_parts(key), &Access.key(&1, %{}))
        ],
        callback
      )

    if(state !== old_state) do
      LiveUpdates.notify_live_view(
        state.bkid,
        {:mavu_bucket, state.bkid, :update_value, nil}
      )

      save_data_to_db(state.bkid, state.data, conf)
    end

    response = :ok
    {:reply, response, state}
  end

  def handle_call({:set_data, data, conf}, _from, old_state) when is_map(conf) do
    state = put_in(old_state, [:data], data)

    if(state !== old_state) do
      LiveUpdates.notify_live_view(
        state.bkid,
        {:mavu_bucket, state.bkid, :set_data, nil}
      )

      save_data_to_db(state.bkid, state.data, conf)
    end

    response = :ok
    {:reply, response, state}
  end

  @doc """
  fetch data from db:
  """
  @impl GenServer
  def handle_info(:fetch_data, state) do
    updated_state =
      fetch_data_from_db(state.bkid)
      |> case do
        nil -> state
        data_from_db -> %__MODULE__{state | data: data_from_db}
      end

    {:noreply, updated_state}
  end

  @impl true
  def terminate(reason, _state) do
    reason
    |> IO.inspect(label: "mwuits-debug 2020-03-18_11:24 Visitor Session  exits with reason ")

    MavuUtils.log(
      reason,
      "mwuits-debug 2018-08-10_22:15 Visitor Session  exits with reason",
      :warn
    )
  end

  ## Private

  defp repo(conf \\ %{}) do
    get_conf_val(conf, :repo)
  end

  defp via_tuple(bkid),
    do: {:via, Registry, {@registry, bkid}}

  defp get_pid(bkid) do
    BucketSupervisor.find_or_create_child(bkid)
  end

  defp get_key_parts(key_str) when is_binary(key_str) do
    key_str |> String.split(["."])
  end

  def fetch_data_from_db(bkid) do
    case repo().get_by(BucketStore, bkid: bkid) do
      nil -> nil
      rec -> rec.state |> Bertex.decode()
    end
  end

  def save_data_to_db(_bkid, _data, %{skip_db: true}), do: :ok

  def save_data_to_db(bkid, data, conf) when is_map(conf) do
    case repo().get_by(BucketStore, bkid: bkid) do
      nil -> %BucketStore{bkid: bkid}
      rec -> rec
    end
    |> BucketStore.changeset(%{state: data |> Bertex.encode()})
    |> repo().insert_or_update()

    :ok
  end
end
