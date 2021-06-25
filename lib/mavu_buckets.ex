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

  defp repo() do
    MyApp.Repo
  end

  # public API:
  defdelegate get_data(bkid), to: BucketGenServer

  defdelegate set_data(bkid, data), to: BucketGenServer

  defdelegate set_value(bkid, key, value), to: BucketGenServer

  defdelegate update_value(bkid, key, callback), to: BucketGenServer

  defdelegate get_value(bkid, key, default \\ nil), to: BucketGenServer

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

    BucketGenServer.save_data_to_db(archive_bkid, archive_data)
    set_data(bkid, new_data)
  end

  def get_latest_bkids(n \\ 10) when is_integer(n) do
    BucketStore
    |> Ecto.Query.select([r], {r.inserted_at, r.bkid})
    |> Ecto.Query.order_by(desc: :inserted_at)
    |> Ecto.Query.limit(^n)
    |> repo().all()
  end

  defmacro bucket_cache(bucket_name, key_name, opts \\ [], do: block) do
    quote do
      res =
        if MavuUtils.present?(unquote(opts)[:clear_cache]) or
             MavuUtils.present?(unquote(opts)[:no_cache]) do
          nil
        else
          MavuBuckets.get_value(unquote(bucket_name), unquote(key_name) |> to_string())
        end

      case res do
        nil ->
          result = unquote(block)

          unless MavuUtils.present?(unquote(opts)[:no_cache]) do
            MavuBuckets.set_value(
              unquote(bucket_name),
              unquote(key_name) |> to_string(),
              result
            )
          end

          result

        val ->
          val
      end
    end
  end
end
