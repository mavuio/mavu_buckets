# LiveUpdates broadcasts on the host app's PubSub
{:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: MyApp.PubSub}], strategy: :one_for_one)

ExUnit.start()
