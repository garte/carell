defmodule Carell.PubSub do
  alias Phoenix.PubSub

  def subscribe(adapter, topic) do
    PubSub.subscribe(adapter, topic)
  end

  def unsubscribe(adapter, topic) do
    PubSub.unsubscribe(adapter, topic)
  end

  def broadcast(adapter, topic, event) do
    PubSub.broadcast(adapter, topic, {__MODULE__, topic, event})
  end
end
