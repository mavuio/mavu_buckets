defmodule MavuBuckets.LiveUpdates do
  @topic inspect(__MODULE__)
  @registry :mavu_buckets_registry

  alias MavuBuckets.BkHelpers

  def pubsub do
    # Application.get_env(:my_app, :mavu_buckets, :pubsub)
    MyApp.PubSub
  end

  @doc "subscribe for all users"
  def subscribe_live_view do
    Phoenix.PubSub.subscribe(pubsub(), topic(), link: true)
  end

  @doc "subscribe for specific user"
  def subscribe_live_view(user_id) do
    Phoenix.PubSub.subscribe(pubsub(), topic(user_id), link: true)
  end

  @doc "notify for all users"
  def notify_live_view(message) do
    Phoenix.PubSub.broadcast(pubsub(), topic(), message)
  end

  @doc "notify for specific user"
  def notify_live_view(user_id, message) do
    "" |> BkHelpers.log("notify_live_view user:#{user_id}", :debug)
    Phoenix.PubSub.broadcast(pubsub(), topic(user_id), message)
  end

  defp topic, do: @topic
  defp topic(user_id), do: topic() <> to_string(user_id)
end
