defmodule MavuBuckets.LiveUpdates do
  @topic inspect(__MODULE__)

  def pubsub do
    # Application.get_env(:my_app, :mavu_buckets, :pubsub)
    MyApp.PubSub
  end

  @doc "subscribe for all buckets"
  def subscribe_live_view do
    Phoenix.PubSub.subscribe(pubsub(), topic(), link: true)
  end

  @doc "subscribe for specific bucket"
  def subscribe_live_view(bkid) do
    Phoenix.PubSub.subscribe(pubsub(), topic(bkid), link: true)
  end

  @doc "notify for all bkids"
  def notify_live_view(message) do
    Phoenix.PubSub.broadcast(pubsub(), topic(), message)
  end

  @doc "notify for specific bucket"
  def notify_live_view(bkid, message) do
    Phoenix.PubSub.broadcast(pubsub(), topic(bkid), message)
  end

  defp topic, do: @topic
  defp topic(bkid), do: topic() <> to_string(bkid)
end
