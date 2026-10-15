defmodule MavuBuckets.BucketGenServerTest do
  use ExUnit.Case, async: true

  alias MavuBuckets.BucketGenServer
  alias MavuBuckets.BucketSupervisor

  @persist_interval_ms 2000
  @lifetime_ms 200
  @conf [lifetime_ms: @lifetime_ms, skip_db: true]

  setup do
    {:ok, bkid: "test-#{System.unique_integer([:positive])}"}
  end

  # the first write persists right away, the second one schedules a persist timer
  defp write_twice(bkid) do
    :ok = BucketGenServer.set_value(bkid, "a", 1, @conf)
    :ok = BucketGenServer.set_value(bkid, "b", 2, @conf)

    pid = BucketSupervisor.get_pid_of_child(bkid)
    state = :sys.get_state(pid)
    assert is_reference(state.persist_timer)

    {pid, state}
  end

  test "persists and exits when the persist timer fires at the interval boundary", %{
    bkid: bkid
  } do
    {pid, _state} = write_twice(bkid)
    ref = Process.monitor(pid)

    # the timer fires, but the clock says the interval has not quite passed yet
    boundary_ts = :os.system_time(:millisecond) - @persist_interval_ms + 1
    :sys.replace_state(pid, &%{&1 | last_persist_ts: boundary_ts})
    send(pid, {:persist_dirty_data, Map.new(@conf), :os.system_time(:millisecond)})

    state = :sys.get_state(pid)
    assert state.persist_timer == nil
    assert state.last_persist_ts > boundary_ts

    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, @lifetime_ms * 4
  end

  test "keeps no persist_timer whose timer has already fired", %{bkid: bkid} do
    {pid, %{persist_timer: timer, last_persist_ts: first_persist_ts}} = write_twice(bkid)

    # keep the bucket alive until the persist timer has fired
    :sys.replace_state(pid, &%{&1 | lifetime_ms: 60_000})
    Process.sleep(Process.read_timer(timer) + 50)
    assert Process.read_timer(timer) == false

    state = :sys.get_state(pid)
    assert state.persist_timer == nil
    assert state.last_persist_ts > first_persist_ts
  end

  test "persists once per interval and stays alive while being written to", %{bkid: bkid} do
    pid = BucketSupervisor.find_or_create_child(bkid)

    persist_timestamps =
      for i <- 1..25, reduce: [] do
        acc ->
          :ok = BucketGenServer.set_value(bkid, "counter", i, @conf)
          Process.sleep(div(@lifetime_ms, 2))
          [:sys.get_state(pid).last_persist_ts | acc]
      end

    assert Process.alive?(pid)
    # 25 writes over ~2.5s: one persist right away, one when the interval has passed
    assert persist_timestamps |> Enum.uniq() |> length() == 2
  end
end
