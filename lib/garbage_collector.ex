defmodule MavuBuckets.GarbageCollector do
  use GenServer, restart: :transient

  require Logger
  alias MavuBuckets.BucketStore

  import MavuBuckets.BucketGenServer, only: [repo: 1, repo_running?: 1]

  require Ecto.Query

  def start_link(_arg) do
    GenServer.start_link(__MODULE__, get_conf_val(:run_interval), name: __MODULE__)
  end

  def get_conf_val(:run_interval) do
    System.get_env("MAVU_BUCKETS_GC_INTERVAL_SECONDS", "300")
    |> MavuUtils.to_int()
    |> case do
      time_s when is_integer(time_s) -> time_s * 1_000
      _ -> 300
    end
  end

  @doc """
    Get max amount of items to be pruned in one run
  """
  def get_conf_val(:max_amount_to_prune_in_one_run) do
    System.get_env("MAVU_BUCKETS_GC_INTERVAL_MAX_AMOUNT", "1000")
    |> MavuUtils.to_int()
    |> case do
      n when is_integer(n) -> n
      _ -> 1000
    end
  end

  def get_conf_val(:bytes_to_keep) do
    System.get_env("MAVU_BUCKETS_GC_MB_TO_KEEP", "100")
    |> Float.parse()
    |> case do
      {n, _} when is_float(n) -> (n * 1_000_000) |> round()
      _ -> 100 * 1_000_000
    end
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
    # memory_hogs =
    #   Process.list()
    #   |> Enum.map(fn pid ->
    #     {:memory, memory} = Process.info(pid, :memory)
    #     {pid, memory}
    #   end)
    #   |> Enum.sort_by(
    #     fn {_, memory} ->
    #       memory
    #     end,
    #     :desc
    #   )
    #   |> Enum.take(3)
    do_garbage_collect()

    {:noreply, run_interval, {:continue, :schedule_next_run}}
  end

  def do_garbage_collect(opts \\ []) do
    prune_items(opts)
  end

  @doc """
    Get all items to be pruned, ordered by persistence_level

  ## Options

    * `:type` - type of query, `:query_all` or `:prune_more` (default: :prune_default)
  """
  def get_items_query(opts \\ []) do
    if opts[:type] == :query_all do
      BucketStore
    else
      now = NaiveDateTime.utc_now()

      # persistence_level:
      # ↓ 100 keep ,10 keep if possible,1: remove

      persistence_level_keep =
        case opts[:type] do
          :prune_more -> 100
          :prune_default -> 10
          nil -> raise "type must be one of :prune_more, :prune_default, or :query_all"
        end

      BucketStore
      |> Ecto.Query.where([r], r.protect_until < ^now)
      |> Ecto.Query.where([r], r.persistence_level < ^persistence_level_keep)
      |> Ecto.Query.order_by([r], asc: r.persistence_level, asc: r.protect_until)
    end
  end

  @doc """
    Get count of items to be pruned,
  """
  def get_items_count(opts \\ []) do
    repo = repo(opts |> Enum.into(%{}))

    if repo_running?(repo) do
      get_items_query(opts)
      |> repo.aggregate(:count, :id)
    end
  end

  @doc """
    Get size of all items to be pruned,

    ## Options

      * `:human_readable` - return size in human readable format (default: true)

  """
  def get_items_size(opts \\ []) do
    repo = repo(opts |> Enum.into(%{}))

    if repo_running?(repo) do
      size_in_bytes =
        get_items_query(opts)
        |> repo.aggregate(:sum, :size) ||
          0

      unless opts[:human_readable] == false do
        size_in_bytes |> format_as_mb()
      else
        size_in_bytes
      end
    end
  end

  def format_as_mb(size_in_bytes) do
    :io_lib.format("~.2fM", [(size_in_bytes || 0) / 1_000_000]) |> List.to_string()
  end

  def prune_items(opts \\ []) do
    repo = repo(opts |> Enum.into(%{}))

    if repo_running?(repo) do
      n_max_from_conf = get_conf_val(:max_amount_to_prune_in_one_run)

      # prune all items below persistence_level 10

      possible_items_to_prune =
        get_items_query(type: :prune_default)
        |> Ecto.Query.select([r], %{bkid: r.bkid, size: r.size})
        |> Ecto.Query.limit(^n_max_from_conf)
        |> Ecto.Query.exclude(:order_by)
        |> repo.all()

      n_deleted =
        for %{bkid: bkid, size: size} <- possible_items_to_prune,
            reduce: 0 do
          n_deleted ->
            repo.get_by!(BucketStore, bkid: bkid)
            |> repo.delete()
            |> case do
              {:ok, _} ->
                n_deleted + 1

              _ ->
                n_deleted
            end
        end
        |> case do
          count when count > 0 ->
            Logger.info("mavu_buckets_gc: pruned #{count} items with persistence_level < 10")
            count

          _ ->
            Logger.info("mavu_buckets_gc: no items found to prune with persistence_level < 10")

            0
        end

      n_still_able_to_prune = n_max_from_conf - n_deleted

      if n_still_able_to_prune > 0 do
        size_used = get_items_size(type: :query_all, human_readable: false)
        size_limit = get_conf_val(:bytes_to_keep)
        size_needed_pruned = size_used

        if size_needed_pruned > 0 do
          possible_items_to_prune =
            get_items_query(type: :prune_more)
            |> Ecto.Query.select([r], %{bkid: r.bkid, size: r.size})
            |> Ecto.Query.limit(^n_still_able_to_prune)
            |> repo.all()

          for %{bkid: bkid, size: size} <- possible_items_to_prune,
              reduce: {0, size_needed_pruned} do
            {n_deleted_also, size_still_needed_pruned} ->
              {new_n_deleted_also, new_size_still_needed_pruned} =
                repo.get_by!(BucketStore, bkid: bkid)
                |> repo.delete()
                |> case do
                  {:ok, _} ->
                    Logger.info(
                      "mavu_buckets_gc: pruned item #{bkid} #{size} bytes, size_needed #{size_still_needed_pruned |> format_as_mb()}"
                    )

                    {n_deleted_also + 1, size_still_needed_pruned - size}

                  _ ->
                    {n_deleted_also, size_still_needed_pruned}
                end

              {new_n_deleted_also, new_size_still_needed_pruned}
          end
          |> case do
            {n_deleted_also, size_still_needed_pruned} ->
              Logger.info(
                "mavu_buckets_gc: pruned (#{n_deleted}+#{n_deleted_also}) items with persistence_level < 100 because of size used: #{size_used |> format_as_mb()} > size to keep: #{size_limit |> format_as_mb()} "
              )

              if size_still_needed_pruned > 0 do
                Logger.info(
                  "mavu_buckets_gc: #{size_still_needed_pruned |> format_as_mb()} open for next run"
                )
              end
          end
        else
          Logger.info(
            "mavu_buckets_gc: size used #{size_used |> format_as_mb()} is less than #{size_limit |> format_as_mb()}, nothing to prune"
          )
        end

        # prune all items below persistence_level 100
      end

      size_total_str = get_items_size(type: :query_all, human_readable: true)
      count_total = get_items_count(type: :query_all)

      Logger.info("mavu_buckets_gc: #{count_total} items in total, using #{size_total_str}")
    end
  end
end
