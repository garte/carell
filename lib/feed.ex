defmodule Carell.Feed.TriggerEvent do
  defstruct [:id, :address, :from, :feed, :event, :params, :reply]
end

defmodule Carell.Feed.StartEvent do
  defstruct [:id, :from, :event, :reply]
end

# TODO: trigger watches with empty payloads on stop to shut down (empty out) depending Feed.manage calls
defmodule Carell.Feed do
  require Logger
  alias Carell.Feed.StartEvent
  alias Ecto.UUID
  alias Carell.Feed.TriggerEvent

  defstruct [
    :id,
    :mod,
    :tags,
    :watch,
    :args,
    :assign,
    :state,
    :address,
    prev_event_ids: [],
    # run or trigger
    mode: :loop,
    # Is it called directly via {mod, args} for a single trigger?
    ignore_subscriptions: false,
    hooks: %{stop: []},
    changes: %{},
    patches: [],
    pubsub: Lvln2.PubSub
  ]

  @feeds_ns :carell_feeds
  @subs_ns :carell_subs

  defmacro __using__(_opts \\ []) do
    quote do
      import Carell.Feed,
        only: [
          update: 2,
          subscribe: 2,
          unsubscribe: 2,
          broadcast: 3,
          on: 3,
          get: 2,
          put: 2,
          on_old: 3,
          on_old: 4
        ]

      def loop(event, feed) do
        require Logger
        Logger.warning("Unmatched event #{inspect(event)} in #{inspect({feed.id, feed.mod})}")
      end

      def stop(feed) do
        {:ok, feed}
      end

      defoverridable stop: 1, loop: 2
    end
  end

  def on({%Carell.Feed{} = feed, event}, query, cb)
      when is_function(cb) do
    catchers = List.wrap(query)

    eq = fn
      event, f, v ->
        Enum.any?(List.wrap(v), fn
          v ->
            case Map.get(event, f) do
              nil ->
                false

              ev ->
                ev == v || String.starts_with?(ev, v)
            end
        end)
    end

    matched? =
      event.__struct__ == StartEvent ||
        Enum.any?(catchers, fn
          grp when is_list(grp) ->
            Enum.all?(grp, fn {f, v} ->
              eq.(event, f, v)
            end)

          {f, v} ->
            eq.(event, f, v)

          v when is_binary(v) ->
            eq.(event, :event, v)
        end)

    updates =
      if matched? do
        cb.()
      else
        nil
      end

    feed =
      case updates do
        x when x in [nil, false] ->
          feed

        %{} ->
          update(feed, updates)
      end

    {feed, event}
  end

  def get(%__MODULE__{state: state}, key, default \\ nil), do: Map.get(state || %{}, key, default)

  def put(%__MODULE__{state: state} = feed, changes) do
    %__MODULE__{feed | state: Enum.into(changes, state || %{})}
  end

  def patch(%__MODULE__{patches: patches} = feed, path, val) do
    %__MODULE__{feed | patches: [{:merge, path, val} | patches]}
  end

  def update(%__MODULE__{changes: changes} = feed, new_changes) do
    new_changes = Enum.into(new_changes, %{})

    %__MODULE__{feed | changes: Map.merge(changes, new_changes)}
  end

  def subscribe(%__MODULE__{} = feed, topic) do
    send(self(), {__MODULE__, :subscribe, feed, topic})

    # Don't return feed! That might lead to race conditions.
    :ok
  end

  def unsubscribe(%__MODULE__{} = feed, topic) do
    send(self(), {__MODULE__, :unsubscribe, feed, topic})

    # Don't return feed! That might lead to race conditions.
    :ok
  end

  def broadcast(%__MODULE__{pubsub: adapter} = feed, topic, event) do
    alias Phoenix.PubSub

    PubSub.broadcast(adapter, topic, {__MODULE__, :broadcast, topic, event})

    feed
  end

  def start(socket, {mod, args}, opts \\ []) do
    id = Keyword.get(opts, :id, mod)

    feed = %__MODULE__{
      id: id,
      tags: List.wrap(Keyword.get(opts, :tags, [])),
      mod: mod,
      args: args,
      mode: Keyword.get(opts, :mode, :loop),
      watch: Keyword.get(opts, :watch, []),
      assign: Keyword.get(opts, :assign),
      ignore_subscriptions: Keyword.get(opts, :ignore_subscriptions, false)
    }

    if exists?(socket, id) do
      if Keyword.get(opts, :ignore_started?, false) == false do
        {:error, "Feed id #{inspect(id)} already exists!"}
      else
        {:ok, socket}
      end
    else
      do_start(socket, feed)
    end
  end

  def stop(socket, tag: tag) do
    socket =
      Enum.reduce(by_tag(socket, tag), socket, fn {_id, feed}, socket ->
        {:ok, socket} = stop(socket, feed.id)
        socket
      end)

    {:ok, socket}
  end

  def stop(socket, id) do
    require Logger

    IO.puts("stop #{inspect({id}, pretty: true)}")
    feeds = get_feeds(socket)

    case Map.get(feeds, id) do
      nil ->
        {:ok, socket}

      feed ->
        do_stop(socket, feed)
    end
  end

  def exists?(socket, id) do
    feeds = get_feeds(socket)
    Map.has_key?(feeds, id)
  end

  def manage(socket, iter, prefix, spawn) do
    new =
      Enum.map(iter, fn
        {_, %{id: id}} -> {"#{prefix}:#{id}", id}
        %{id: id} -> {"#{prefix}:#{id}", id}
        {%{id: id}, _} -> {"#{prefix}:#{id}", id}
      end)
      |> Enum.into(%{})

    new_feed_ids = Enum.map(new, &elem(&1, 0))

    old = Enum.map(by_tag(socket, prefix), &elem(&1, 0))

    {:ok, socket} =
      do_manage(socket, old, new_feed_ids, fn socket, feed_id ->
        opts = [tags: [prefix], id: feed_id]

        {:ok, socket} = spawn.(socket, new[feed_id], opts)

        socket
      end)

    socket
  end

  def do_manage(socket, old, new, fun) do
    require Logger

    old = Enum.sort(old)
    new = Enum.sort(new)

    diff = List.myers_difference(old, new)

    socket =
      Enum.reduce(diff, socket, fn
        {:eq, _}, socket ->
          socket

        {:del, ids}, socket ->
          Enum.reduce(ids, socket, fn id, socket ->
            Logger.info("Stopping #{id}")

            {:ok, socket} = stop(socket, id)
            socket
          end)

        {:ins, ids}, socket ->
          Enum.reduce(ids, socket, fn id, socket ->
            fun.(socket, id)
          end)
      end)

    {:ok, socket}
  end

  def by_id(socket, id) do
    socket
    |> get_feeds()
    |> Map.get(id)
  end

  def by_tag(socket, tag) do
    socket
    |> get_feeds()
    |> Enum.filter(&(tag in elem(&1, 1).tags))
  end

  defp do_start(
         socket,
         %__MODULE__{mode: :trigger, mod: mod, args: args} = feed
       ) do
    {:ok, address, feed} = mod.start(feed, args)
    feed = %__MODULE__{feed | address: address, args: nil}
    {:ok, _socket} = register(socket, feed)
  end

  defp do_start(
         socket,
         %__MODULE__{mode: :loop, mod: mod, args: args} = feed
       ) do
    {:ok, address, feed} = mod.start(feed, args)
    feed = %__MODULE__{feed | address: address, args: nil}
    subscribe(feed, feed.address)
    {:ok, socket} = register(socket, feed)
    {:ok, feed} = mod.loop(%Carell.Feed.StartEvent{}, feed)
    {:ok, feed, socket} = commit_changes(feed, socket)
    socket = put_feeds(socket, Map.put(get_feeds(socket), feed.id, feed))

    {:ok, socket}
  end

  defp do_stop(
         socket,
         %__MODULE__{mod: mod, args: _args, hooks: %{stop: stop_hooks}} = feed
       ) do
    {:ok, feed} = mod.stop(feed)

    # Stop all dependent (hooked) feeds
    socket =
      Enum.reduce(stop_hooks, socket, fn {:tag, tag}, socket ->
        {:ok, socket} = stop(socket, tag: tag)
        socket
      end)

    socket = drop_subscriptions(socket, feed)
    socket = drop_assigns(socket, feed)
    {:ok, _socket} = unregister(socket, feed)
  end

  def handle_info({Carell.Feed, :trigger, id, event, params, opts}, socket) do
    socket = handle_trigger(socket, id, event, params, opts)

    {:noreply, socket}
  end

  # Noop
  def handle_info(
        {Carell.Feed, :subscribe, %__MODULE__{ignore_subscriptions: true}, _topic},
        socket
      ),
      do: {:noreply, socket}

  def handle_info(
        {Carell.Feed, :subscribe, %__MODULE__{ignore_subscriptions: false} = feed, topic},
        socket
      ) do
    socket = create_subscription(socket, feed, topic)

    {:noreply, socket}
  end

  def handle_info(
        {Carell.Feed, :unsubscribe, %__MODULE__{ignore_subscriptions: false} = feed, topic},
        socket
      ) do
    alias Phoenix.PubSub
    socket = drop_subscriptions(socket, feed, topic)

    {:noreply, socket}
  end

  # TODO: broadcast kommt mehrfach rein
  def handle_info({Carell.Feed, :broadcast, topic, event}, socket) do
    socket = commit_push(socket, topic, event)

    {:noreply, socket}
  end

  def trigger(id, event, params, opts \\ []) do
    send(self(), {__MODULE__, :trigger, id, event, params, opts})

    :ok
  end

  def handle_trigger(socket, {mod, args}, event, params, opts) do
    id = Ecto.UUID.generate()
    {:ok, socket} = start(socket, {mod, args}, id: id, mode: :trigger, ignore_subscriptions: true)
    socket = handle_trigger(socket, id, event, params, opts)
    {:ok, socket} = stop(socket, id)

    socket
  end

  def handle_trigger(socket, id, event, params, trigger_opts) do
    feeds = get_feeds(socket)
    %__MODULE__{address: address, mod: mod} = feed = Map.get(feeds, id)

    {act, feed, opts} =
      case mod.handle_trigger(feed, event, params) do
        {act, feed} -> {act, feed, []}
        {act, feed, opts} when is_map(feed) and is_list(opts) -> {act, feed, opts}
      end

    {:ok, feed, socket} = commit_changes(feed, socket)

    reply = Keyword.get(opts, :reply)
    event_id = UUID.generate()

    feed =
      case act do
        :loop ->
          broadcast(feed, address, %TriggerEvent{
            id: event_id,
            address: address,
            feed: feed,
            event: event,
            params: params,
            reply: reply
          })

        act when act in [:noloop] ->
          feed
      end

    feed =
      case Keyword.get(opts, :relay) do
        nil ->
          feed

        relays ->
          relays
          |> List.wrap()
          |> Enum.reduce(feed, fn relay, feed ->
            broadcast(feed, relay, %TriggerEvent{
              id: event_id,
              address: relay,
              from: address,
              feed: feed,
              event: event,
              params: params,
              reply: reply
            })
          end)
      end

    feeds = Map.put(feeds, id, feed)
    socket = put_feeds(socket, feeds)

    socket = Keyword.get(trigger_opts, :after_commit, fn _, socket -> socket end).(reply, socket)

    socket
  end

  defp register(socket, %__MODULE__{id: id} = feed) do
    feeds = get_feeds(socket)
    feeds = Map.put(feeds, id, feed)
    socket = put_feeds(socket, feeds)

    {:ok, socket}
  end

  defp unregister(socket, %__MODULE__{id: id}) do
    feeds = get_feeds(socket)
    feeds = Map.delete(feeds, id)
    socket = put_feeds(socket, feeds)

    {:ok, socket}
  end

  def drop_subscriptions(socket, feed, only_this_topic \\ nil) do
    alias Phoenix.PubSub

    # This function should never mutate the feed. It might lead to data race conditions!
    %__MODULE__{pubsub: adapter} = feed
    all = get_subscriptions(socket)

    all =
      Enum.map(all, fn {topic, ids} ->
        if is_nil(only_this_topic) || only_this_topic == topic do
          ids = Enum.reject(ids, &(&1 == feed.id))

          if ids == [] do
            PubSub.unsubscribe(adapter, topic)
          end

          {topic, ids}
        else
          {topic, ids}
        end
      end)

    all = Enum.into(all, %{})

    put_subscriptions(socket, all)
  end

  def drop_assigns(socket, feed) do
    import Phoenix.Component

    %__MODULE__{assign: assign} = feed

    Enum.reduce(List.wrap(assign), socket, fn
      {:mixin, key, id}, socket when is_atom(key) ->
        assign(socket, [{key, Map.delete(socket.assigns[key] || %{}, id)}])

      {:inject, superfeed_id, path}, socket when is_list(path) ->
        superfeed = by_id(socket, superfeed_id)
        superfeed = patch(superfeed, path, %{})
        {:ok, superfeed, socket} = commit_changes(superfeed, socket)

        # Important: load feeds from the socket before updating the register because commit_changes might have added
        # some new ones!
        put_feeds(socket, Map.put(get_feeds(socket), superfeed.id, superfeed))

      key, socket when is_atom(key) ->
        # This might need to be merged with data that's already there if there are incremental updates in the future!
        assign(socket, [{key, nil}])

      {_mod, id}, socket when is_binary(id) ->
        socket

      fun, socket when is_function(fun) ->
        socket
    end)
  end

  def create_subscription(socket, feed, topic) do
    alias Phoenix.PubSub

    # This function should never mutate the feed. It might lead to data race conditions!
    %__MODULE__{id: id, pubsub: adapter} = feed
    all = get_subscriptions(socket)
    subs = Map.get(all, topic, [])

    if subs == [] do
      PubSub.subscribe(adapter, topic)
    end

    subs = [id | subs] |> Enum.uniq()
    all = Map.put(all, topic, subs)

    put_subscriptions(socket, all)
  end

  def commit_push(socket, topic, event) do
    all = get_subscriptions(socket)

    # TODO warn if this is empty?
    subs = Map.get(all, topic, [])

    Enum.reduce(subs, socket, fn id, socket ->
      current_feeds = get_feeds(socket)
      feed = Map.get(current_feeds, id, [])
      if is_nil(feed), do: raise("Feed not found: #{inspect(id)}!")

      %__MODULE__{mod: mod} = feed = Map.get(current_feeds, id)

      {:ok, feed} =
        maybe_debounce(feed, event, fn feed, event ->
          mod.loop(event, feed)
        end)

      if feed.changes === %{} do
        Logger.warning(
          "Empty changeset in #{inspect(feed.mod)} feed after loop. You missed out on #{topic}: #{inspect(event.event)}!"
        )
      end

      {:ok, feed, socket} = commit_changes(feed, socket)

      # Important: load feeds from the socket before updating the register because commit_changes might have added
      # some new ones!
      put_feeds(socket, Map.put(get_feeds(socket), id, feed))
    end)
  end

  defp maybe_debounce(
         %__MODULE__{prev_event_ids: prevs} = feed,
         %TriggerEvent{id: event_id} = event,
         cb
       ) do
    {act, %__MODULE__{} = feed} =
      if event_id not in prevs do
        cb.(feed, event)
      else
        Logger.warning("Debounced #{event.id}: #{event.event} for feed #{feed.id}")
        {:ok, feed}
      end

    feed = %__MODULE__{feed | prev_event_ids: [event_id | prevs] |> Enum.take(-10)}
    {act, feed}
  end

  defp maybe_debounce(feed, _event, _cb), do: {:ok, feed}

  defp commit_changes(
         %__MODULE__{watch: watches, changes: changes} = feed,
         socket
       ) do
    {socket, feed} =
      Enum.reduce(watches, {socket, feed}, fn
        {key, {prefix, creator}}, {socket, feed} ->
          values = Map.get(changes, key)

          socket =
            if !is_nil(values) do
              new =
                Enum.map(values, fn
                  {_, %{id: id}} = v -> {"#{prefix}:#{id}", {id, v}}
                  %{id: id} = v -> {"#{prefix}:#{id}", {id, v}}
                  {%{id: id}, _} = v -> {"#{prefix}:#{id}", {id, v}}
                end)
                |> Enum.into(%{})

              new_feed_ids = Enum.map(new, &elem(&1, 0))
              old_feed_ids = Enum.map(by_tag(socket, prefix), &elem(&1, 0))

              {:ok, socket} =
                do_manage(socket, old_feed_ids, new_feed_ids, fn socket, feed_id ->
                  feed_opts = [tags: [prefix], id: feed_id]
                  {_id, value} = new[feed_id]

                  {:ok, socket} =
                    case creator.(value) do
                      # {:stop, ids} ->
                      #   socket =
                      #     Enum.reduce(ids, socket, fn id, socket ->
                      #       {:ok, socket} = stop(socket, id)
                      #       socket
                      #     end)

                      #   {:ok, socket}

                      :noop ->
                        # Do nothing
                        {:ok, socket}

                      cstr ->
                        {mod, args, feed_opts} =
                          case cstr do
                            {mod, args} ->
                              {mod, args, feed_opts}

                            {mod, args, add_opts} ->
                              {mod, args, Keyword.merge(feed_opts, add_opts)}
                          end

                        {:ok, _socket} =
                          start(
                            socket,
                            {mod, args},
                            feed_opts
                            # [ {:assign, {:inject, feed.id, [integrate_key, feed_id]}} | feed_opts ]
                          )
                    end

                  socket
                end)

              socket
            else
              socket
            end

          # NOTE: this maybe faulty!
          hooks =
            if Enum.any?(feed.hooks.stop, &(elem(&1, 1) == prefix)) do
              feed.hooks
            else
              update_in(feed.hooks, [:stop], &[{:tag, prefix} | &1])
            end

          {socket, %__MODULE__{feed | hooks: hooks}}

        {key, fun}, {socket, feed} when is_function(fun, 2) ->
          change = Map.get(changes, key)

          socket =
            if !is_nil(change) do
              fun.(socket, change)
            else
              socket
            end

          {socket, feed}
      end)

    socket =
      unless feed.changes == %{} && length(feed.patches) == 0 do
        invoke_changes(feed, socket)
      else
        socket
      end

    {:ok, %__MODULE__{feed | changes: %{}, patches: []}, socket}
  end

  defp invoke_changes(%__MODULE__{changes: changes, assign: assign} = feed, socket) do
    import Phoenix.Component
    import Phoenix.LiveView

    Enum.reduce(List.wrap(assign), socket, fn
      {:mixin, key, id}, socket when is_atom(key) ->
        base = socket.assigns[key][id] || %{}
        base = Map.merge(base, changes)
        base = apply_patches(base, feed)

        assign(socket, [{key, Map.put(socket.assigns[key] || %{}, id, base)}])

      key, socket when is_atom(key) ->
        base = socket.assigns[key] || %{}
        base = Map.merge(base, changes)
        base = apply_patches(base, feed)

        assign(socket, Map.put(%{}, key, base))

      {mod, id}, socket when is_binary(id) ->
        send_update(mod, Keyword.put(changes, :id, id))

        socket

      {:inject, superfeed_id, path}, socket when is_list(path) ->
        superfeed = by_id(socket, superfeed_id)
        superfeed = patch(superfeed, path, changes)
        {:ok, superfeed, socket} = commit_changes(superfeed, socket)

        # Important: load feeds from the socket before updating the register because commit_changes might have added
        # some new ones!
        put_feeds(socket, Map.put(get_feeds(socket), superfeed.id, superfeed))

      fun, socket when is_function(fun) ->
        fun.(socket, changes)
    end)
  end

  defp get_subscriptions(%{private: priv} = _socket), do: Map.get(priv, @subs_ns) || %{}

  defp put_subscriptions(%{private: priv} = socket, subs),
    do: %{socket | private: Map.put(priv, @subs_ns, subs)}

  defp get_feeds(%{private: priv} = _socket), do: Map.get(priv, @feeds_ns) || %{}

  defp put_feeds(%{private: priv} = socket, feeds) do
    %{socket | private: Map.put(priv, @feeds_ns, feeds)}
  end

  defp apply_patches(base, %__MODULE__{patches: patches}) do
    patches = Enum.reverse(patches)

    Enum.reduce(patches, base, fn
      {:merge, path, val}, base ->
        update_in(base, Enum.map(path, &Access.key(&1, %{})), &Map.merge(&1, val))
    end)
  end
end
