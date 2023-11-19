defmodule MavuBuckets.GarbageCollector do
  use GenServer, restart: :transient
  @run_interval 3_600_000

  require Logger

  def start_link(_arg) do
    GenServer.start_link(__MODULE__, @run_interval, name: __MODULE__)
  end

  @impl true
  def init(run_interval) do
    {:ok, run_interval, {:continue, :schedule_next_run}}
  end

  @impl true
  def handle_continue(:schedule_next_run, run_interval) do
    Process.send_after(self(), :perform_cron_work, run_interval)
    {:noreply, run_interval}
  end

  @impl true
  def handle_info(:perform_cron_work, run_interval) do
    memory_hogs =
      Process.list()
      |> Enum.map(fn pid ->
        {:memory, memory} = Process.info(pid, :memory)
        {pid, memory}
      end)
      |> Enum.sort_by(
        fn {_, memory} ->
          memory
        end,
        :desc
      )
      |> Enum.take(3)

    Logger.info("Top 3 memory hogs: #{inspect(memory_hogs)}")

    {:noreply, run_interval, {:continue, :schedule_next_run}}
  end
end
