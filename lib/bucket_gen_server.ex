defmodule MavuBuckets.BucketGenServer do
  use GenServer
  require Logger
  alias MavuBuckets.BucketSupervisor
  alias MavuBuckets.LiveUpdates
  alias MavuBuckets.BucketStore

  import MavuBuckets, only: [get_conf_val: 2]

  @registry :mavu_buckets_registry
  @persist_interval_ms 2000
  @protect_for_s 3600
  @default_lifetime_ms 3600_000

  defstruct bkid: nil,
            data: %{},
            last_persist_ts: 0,
            last_interaction_ts: 0,
            persist_timer: nil,
            idle_timer: nil,
            protect_for_s: @protect_for_s,
            lifetime_ms: @default_lifetime_ms,
            persistence_level: 10

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

  ## conf
  def lifetime_ms(_state = %{persistence_level: 100}) do
    :infinity
  end

  def lifetime_ms(_state = %{lifetime_ms: lifetime_ms}) when do
    lifetime_ms
  end

  def lifetime_ms(_state) do
    @default_lifetime_ms
  end

  ## Callbacks
  @impl true
  def init(bkid) do
    MavuUtils.log("❖ init bucket '#{bkid}'", :debug)
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
    {:reply, response, state |> record_activity_in_state()}
  end

  def handle_call({:get_value, key, default, conf}, _from, state) when is_map(conf) do
    response =
      get_in(state, [:data | get_key_parts(key)])
      |> case do
        nil -> default
        val -> val
      end

    {:reply, response, state |> record_activity_in_state()}
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
      |> handle_conf_in_state(conf)

    state =
      if(state.data !== old_state.data) do
        LiveUpdates.notify_live_view(
          state.bkid,
          {:mavu_bucket, state.bkid, :set_value, value}
        )

        state |> persist_dirty_data(conf)
      else
        state
      end

    response = :ok
    {:reply, response, state |> record_activity_in_state()}
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
      |> handle_conf_in_state(conf)

    state =
      if(state.data !== old_state.data) do
        LiveUpdates.notify_live_view(
          state.bkid,
          {:mavu_bucket, state.bkid, :update_value, nil}
        )

        state |> persist_dirty_data(conf)
      else
        state
      end

    response =
      get_in(state, [:data | get_key_parts(key)])

    {:reply, response, state |> record_activity_in_state()}
  end

  def handle_call({:set_data, data, conf}, _from, old_state) when is_map(conf) do
    state =
      put_in(old_state, [:data], data)
      |> handle_conf_in_state(conf)

    state =
      if(state.data !== old_state.data) do
        LiveUpdates.notify_live_view(
          state.bkid,
          {:mavu_bucket, state.bkid, :set_data, nil}
        )

        state |> persist_dirty_data(conf)
      else
        state
      end

    response = :ok
    {:reply, response, state |> record_activity_in_state()}
  end

  @doc """
  fetch data from db:
  """
  @impl GenServer

  def handle_info({:persist_dirty_data, conf, _call_ts}, state) do
    # MavuUtils.log("persist_dirty_data timer called #clcyan", :info)
    {:noreply, state |> persist_dirty_data(conf)}
  end

  def handle_info({:idle_timeout}, state = %{persist_timer: timer}) when not is_nil(timer) do
    # do not time out if a persist timer is still running
    {:noreply, state}
  end

  def handle_info({:idle_timeout}, state) do
    # state |> persist_dirty_data(conf)

    idle_time =
      :os.system_time(:millisecond) - state.last_interaction_ts

    if idle_time > lifetime_ms(state) do
      {:stop, :normal, state}
    else
      {:noreply, %{state | idle_timer: nil} |> ensure_idle_timer_is_running()}
    end
  end

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
  def terminate(:normal, state), do: nil

  def terminate(reason, state),
    do: MavuUtils.log(reason, "Bucket '#{state.bkid}' exits with reason", :warning)

  ## Private

  defp record_activity_in_state(store) do
    %{store | last_interaction_ts: :os.system_time(:millisecond)}
    |> ensure_idle_timer_is_running()
  end

  defp ensure_idle_timer_is_running(state = %{idle_timer: timer}) when not is_nil(timer),
    do: state

  defp ensure_idle_timer_is_running(state) do
    case lifetime_ms(state) do
      :infinity ->
        # no idle timer needed if lifetime = :infinity
        state

      lifetime_ms ->
        # start idle timer if no one is running at the moment

        %{
          state
          | idle_timer:
              Process.send_after(
                self(),
                {:idle_timeout},
                lifetime_ms
              )
        }
    end
  end

  defp handle_conf_in_state(state, conf) when is_map(conf) do
    state =
      if is_integer(conf[:persistence_level]) && conf.persistence_level != state.persistence_level &&
           conf[:persistence_level] in [1, 10, 100] do
        %{state | persistence_level: conf[:persistence_level]}
      else
        state
      end

    state =
      if is_integer(conf[:lifetime_ms]) && conf.lifetime_ms != state.lifetime_ms &&
           is_integer(conf[:lifetime_ms]) do
        %{state | lifetime_ms: conf[:lifetime_ms]}
      else
        state
      end

      case conf[:protect_for] do
        {n, :month} when is_number(n) -> %{state | protect_for_s: round(n * 86400 * 30.5)}
        {n, :week} when is_number(n) -> %{state | protect_for_s: round(n * 86400 * 7)}
        {n, :day} when is_number(n) -> %{state | protect_for_s: round(n * 86400)}
        {n, :min} when is_number(n) -> %{state | protect_for_s: round(n * 3600)}
        {n, :sec} when is_number(n) -> %{state | protect_for_s: round(n)}
        n when is_number(n) -> %{state | protect_for_s: round(n)}
        nil -> state
      end

  end

  defp persist_dirty_data(state, conf) do
    time_passed = :os.system_time(:millisecond) - state.last_persist_ts

    if time_passed <= @persist_interval_ms do
      # if not enough time passed since last db-save,
      # ➜ create timer if it doesn't exists yet

      case state.persist_timer do
        nil ->
          # MavuUtils.log(
          #   "persist later,  #{time_passed} not <= #{@persist_interval_ms}, call again in #{@persist_interval_ms - time_passed} #clcyan",
          #   :info
          # )

          %{
            state
            | persist_timer:
                Process.send_after(
                  self(),
                  {:persist_dirty_data, conf, :os.system_time(:millisecond)},
                  @persist_interval_ms - time_passed
                )
          }

        _ ->
          state.persist_timer
          # |> MavuUtils.log(
          #   "persist later,  another timer already running #clcyan",
          #   :info
          # )

          state
      end
    else
      # if persist_interval has passed since last persist, persist immediately:
      # MavuUtils.log("persist now,  #{time_passed} > #{@persist_interval_ms} #clcyan", :info)

      save_data_to_db(state, conf)
      %{state | persist_timer: nil, last_persist_ts: :os.system_time(:millisecond)}
    end
  end

  def repo(conf \\ %{}) do
    get_conf_val(conf, :repo) || MyApp.Repo
  end

  defp via_tuple(bkid),
    do: {:via, Registry, {@registry, bkid}}

  defp get_pid(bkid) do
    BucketSupervisor.find_or_create_child(bkid)
  end

  defp get_key_parts(key_str) when is_binary(key_str) do
    key_str |> String.split(["."])
  end

  def fetch_data_from_db(bkid, conf \\ []) do
    repo = repo(conf)

    if repo_running?(repo) do
      case repo.get_by(BucketStore, bkid: bkid) do
        nil -> nil
        rec -> rec.state |> Bertex.decode()
      end
    else
      nil
    end
  end

  def save_data_to_db(_state, %{skip_db: true}), do: :ok

  def save_data_to_db(state = %{bkid: bkid, data: data}, conf) when is_map(conf) do
    repo = repo(conf)

    encoded_state = data |> Bertex.encode()

    if repo_running?(repo) do
      case repo.get_by(BucketStore, bkid: bkid) do
        nil -> %BucketStore{bkid: bkid}
        rec -> rec
      end
      |> BucketStore.changeset(%{
        state: encoded_state,
        persistence_level: state.persistence_level,
        protect_until: DateTime.utc_now() |> DateTime.add(state.protect_for_s),
        size: byte_size(encoded_state)
      })
      |> repo.insert_or_update()
    end

    :ok
  end

  def repo_running?(repo) do
    Enum.member?(Ecto.Repo.all_running(), repo)
  end
end
