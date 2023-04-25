defmodule MavuBuckets do
  @moduledoc false
  def default_conf(local_conf \\ %{}) do
    %{
      repo: MyApp.Repo
    }
    |> Map.merge(local_conf)
  end

  def get_conf_val(conf, key) when is_atom(key) do
    conf =
      if MavuUtils.empty?(conf) do
        default_conf()
      else
        conf
      end

    conf[key]
  end

  require Ecto.Query

  alias MavuBuckets.BucketStore

  alias MavuBuckets.BucketGenServer
  alias MavuBuckets.LiveUpdates

  defp repo() do
    MyApp.Repo
  end

  # public API:
  defdelegate get_data(bkid, conf \\ []), to: BucketGenServer

  defdelegate set_data(bkid, data, conf \\ []), to: BucketGenServer

  defdelegate set_value(bkid, key, value, conf \\ []), to: BucketGenServer

  defdelegate update_value(bkid, key, callback, conf \\ []), to: BucketGenServer

  defdelegate get_value(bkid, key, default \\ nil, conf \\ []), to: BucketGenServer

  defdelegate subscribe_live_view(), to: LiveUpdates
  defdelegate subscribe_live_view(bkid), to: LiveUpdates

  def merge_into(bkid, key, values) when is_map(values) do
    merged =
      get_value(bkid, key, %{})
      |> Map.merge(values)

    set_value(bkid, key, merged)
    merged
  end

  def clean_and_archive(bkid, empty_data_record, archive_bkid)
      when is_map(empty_data_record) and is_binary(archive_bkid) do
    data = get_data(bkid)

    archive_data = data
    new_data = data |> Map.merge(empty_data_record)

    BucketGenServer.save_data_to_db(archive_bkid, archive_data, %{})
    set_data(bkid, new_data)
  end

  def get_latest_bkids(n \\ 10) when is_integer(n) do
    BucketStore
    |> Ecto.Query.select([r], {r.inserted_at, r.bkid})
    |> Ecto.Query.order_by(desc: :inserted_at)
    |> Ecto.Query.limit(^n)
    |> repo().all()
  end

  defmacro bucket_cache(bucket_name, key_name, opts, ttl, do: block) do
    quote do
      MavuBuckets.cache_read(unquote(bucket_name), unquote(key_name), unquote(opts), unquote(ttl))
      |> case do
        {:miss, _, _} ->
          result = unquote(block)

          result
          |> MavuBuckets.cache_write(
            unquote(bucket_name),
            unquote(key_name),
            unquote(opts),
            unquote(ttl)
          )

        {:hit, _, val} ->
          val
      end
    end
  end

  def cache_read(bucket_name, key_name, opts \\ [], ttl \\ nil)
      when is_binary(bucket_name) and (is_atom(key_name) or is_binary(key_name)) and
             is_list(opts) and (is_integer(ttl) or is_nil(ttl)) do
    {type, info, value} =
      if MavuUtils.true?(opts[:clear_cache]) or
           MavuUtils.true?(opts[:no_cache]) do
        {:miss, :clear_or_no_cache_given, nil}
      else
        {cachetime, value} =
          MavuBuckets.get_value(bucket_name, key_name |> to_string(), :value_not_found)
          |> decode_cache_time_from_value()

        expires_in =
          case {cachetime, ttl} do
            {cachetime, ttl} when is_integer(cachetime) and is_integer(ttl) ->
              cachetime + ttl - :os.system_time(:seconds)

            _ ->
              nil
          end

        cond do
          value == :value_not_found -> {:miss, :value_not_found, nil}
          cachetime == nil -> {:hit, :no_cachetime_stored, value}
          ttl == nil -> {:hit, :no_ttl_given, value}
          expires_in == nil -> {:hit, :expires_in_is_nil, value}
          expires_in > 0 -> {:hit, {:expires_in, expires_in}, value}
          MavuUtils.true?(opts[:cache_reuse]) -> {:hit, {:cache_reuse_forced, expires_in}, value}
          expires_in <= 0 -> {:miss, {:expired_before, expires_in}, value}
        end
      end

    if MavuUtils.true?(opts[:cache_debug]) do
      {type, info, "value"} |> MavuUtils.log("bucket cache clcyan", :info)
    end

    {type, info, value}
  end

  def cache_write(result, bucket_name, key_name, opts \\ [], ttl \\ nil)
      when is_binary(bucket_name) and (is_atom(key_name) or is_binary(key_name)) and
             is_list(opts) and (is_integer(ttl) or is_nil(ttl)) do
    if MavuUtils.false?(opts[:no_cache]) do
      MavuBuckets.set_value(
        bucket_name,
        key_name |> to_string(),
        result |> encode_cache_time_to_value()
      )
    end

    result
  end

  defp encode_cache_time_to_value(value) do
    {:cached_at, :os.system_time(:seconds), value}
  end

  defp decode_cache_time_from_value(_, default_cachetime \\ nil)

  defp decode_cache_time_from_value({:cached_at, cachetime, value}, _default_cachetime) do
    {cachetime, value}
  end

  defp decode_cache_time_from_value(value, default_cachetime), do: {default_cachetime, value}
end
