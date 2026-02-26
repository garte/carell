# Carell Feeds

Using Phoenix LiveView is amazing, but one piece might be missing: reactive data feeds! With Carell Feeds you subscribe and publish your data in contained modules directly to the LiveView Socket. If something changes you call `Feed.trigger` to a feed of your choice to update its internal state and the feed will emit the changes necessary to update the view.

How and what your feeds actually represent is up to you. It could be a single record in a database, a state of some kind in your view or a whole bunch of data streamed from somewhere.

In essence it's about scaling up your LiveView code by separating concerns into these feeds. The feeds themselves can talk to each other, cascade events and watch properties for further updates.

## Feed watcher
Feeds are not nested, but

## --- AI below, I'll refine this when I get around to it ---

## Initialising a feed

A feed is a module that implements the `Carell.Feed` behaviour. It defines how data is loaded, how it reacts to events, and where its output lands in `socket.assigns`.

### 1. Define the feed module

```elixir
defmodule MyApp.Feeds.TodoList do
  use Carell.Feed

  alias MyApp.Todos

  # Called once when the feed starts.
  # Must return {:ok, address, feed} where address is the PubSub topic
  # the feed subscribes to.
  def start(feed, %{list_id: list_id}) do
    address = "todos:#{list_id}"
    feed = put(feed, %{list_id: list_id})

    {:ok, address, feed}
  end

  # Called immediately after start (with a %StartEvent{}), and again
  # whenever a broadcast arrives on the feed's address.
  def loop(event, feed) do
    list_id = get(feed, :list_id)

    {feed, _event} =
      {feed, event}
      |> on("todo_added", fn -> %{todos: Todos.list(list_id)} end)
      |> on("todo_toggled", fn -> %{todos: Todos.list(list_id)} end)
      |> on("todo_deleted", fn -> %{todos: Todos.list(list_id), last_deleted_at: DateTime.utc_now()} end)

    {:ok, feed}
  end
end
```

`start/2` receives the feed struct and the args you pass in. Use `put/2` to store internal state (private to the feed) and return the PubSub address the feed should listen on.

#### The loop and `on/3`

`loop/2` is called with a `%StartEvent{}` on first load and with broadcast events afterwards. You build a pipeline of `on/3` clauses that selectively apply changes based on the incoming event:

```elixir
{feed, _event} =
  {feed, event}
  |> on("todo_added", fn -> %{todos: Todos.list(list_id)} end)
  |> on("todo_deleted", fn -> %{todos: Todos.list(list_id), last_deleted_at: DateTime.utc_now()} end)
```

Each `on/3` checks whether the event matches its query. If it does, the callback runs and its returned map is merged into `feed.changes`. If it doesn't match, the feed passes through untouched. Only the changes from matching clauses end up in the feed — so a `"todo_added"` event will refresh `:todos` but won't touch `:last_deleted_at`.

A `%StartEvent{}` always matches every `on/3` clause, so all branches run on first load. This means the initial state is the union of all your `on/3` return maps.

You can also match on arbitrary event fields with a `{field, value}` tuple, or combine multiple field conditions in a list:

```elixir
{feed, _event} =
  {feed, event}
  |> on({:event, "todo_added"}, fn -> ... end)           # same as on("todo_added", ...)
  |> on({:address, "todos:inbox"}, fn -> ... end)        # match by source address
  |> on([event: "moved", address: "todos:inbox"], fn ->  # both must match
    ...
  end)
```

### 2. Start the feed in your LiveView

```elixir
defmodule MyAppWeb.TodoLive do
  use MyAppWeb, :live_view

  alias Carell.Feed

  def mount(%{"list_id" => list_id}, _session, socket) do
    {:ok, socket} =
      Feed.start(
        socket,
        {MyApp.Feeds.TodoList, %{list_id: list_id}},
        assign: :todo_list
      )

    {:ok, socket}
  end

  # Delegate PubSub and feed messages to Carell.
  defdelegate handle_info(event, socket), to: Carell.Feed
end
```

#### Assign modes

The `:assign` option controls how `feed.changes` map to `socket.assigns`:

```elixir
# Atom — merges changes into socket.assigns.todo_list
assign: :todo_list

# Mixin — merges into socket.assigns.todo_lists[list_id]
# Multiple feeds can write to different sub-keys of the same assign.
assign: {:mixin, :todo_lists, list_id}

# LiveComponent — sends changes via send_update/2
assign: {TodoListComponent, "component-id"}

# Inject — patches changes into another feed's assign tree at a nested path
assign: {:inject, "parent_feed_id", [:nested, :path]}

# Function — full control over how changes are applied
assign: fn socket, changes -> socket end
```

`Feed.start/3` takes the socket, a `{module, args}` tuple, and options:

| Option     | Description                                                  |
|------------|--------------------------------------------------------------|
| `:assign`  | The key (or strategy) used to push changes into `socket.assigns` |
| `:id`      | Unique identifier for the feed (defaults to the module name) |
| `:mode`    | `:loop` (default) — subscribes and reacts; `:trigger` — on-demand only |
| `:tags`    | List of tags for grouping / bulk operations                  |
| `:watch`   | Watched keys that automatically manage child feeds           |

After `start/3` returns, `socket.assigns.todo_list` contains the initial data and will stay in sync whenever a broadcast arrives on `"todos:<list_id>"`.

### 3. Trigger actions from the view

Use `Feed.trigger/4` to send commands to a feed from event handlers. The feed's `handle_trigger/3` callback processes the action, updates state, and optionally broadcasts to other subscribers.

Add `handle_trigger/3` to the feed module:

```elixir
# In MyApp.Feeds.TodoList

def handle_trigger(feed, "add_todo", %{"title" => title}) do
  list_id = get(feed, :list_id)
  {:ok, _todo} = Todos.create(list_id, title)

  # :loop broadcasts a TriggerEvent to the feed's address,
  # so every subscriber (including this feed) re-runs loop/2.
  # :noloop commits changes without broadcasting.
  {:loop, update(feed, %{todos: Todos.list(list_id)})}
end

def handle_trigger(feed, "toggle_todo", %{"id" => id}) do
  {:ok, _todo} = Todos.toggle(id)
  list_id = get(feed, :list_id)

  {:loop, update(feed, %{todos: Todos.list(list_id)})}
end

# Return a third element — a keyword list — to pass :reply or :relay.
def handle_trigger(feed, "move_todo", %{"id" => id, "target_list_id" => target}) do
  {:ok, todo} = Todos.move(id, target)
  list_id = get(feed, :list_id)

  {:loop, update(feed, %{todos: Todos.list(list_id)}),
    reply: todo,                     # attached to the TriggerEvent and passed to :after_commit
    relay: "todos:#{target}"}        # also broadcast to the target list's topic
end
```

`handle_trigger/3` returns `{action, feed}` or `{action, feed, opts}`:

| Return value | Description |
|---|---|
| `{:loop, feed}` | Commit changes, then broadcast a `%TriggerEvent{}` to subscribers |
| `{:noloop, feed}` | Commit changes silently — no broadcast |
| `{:loop, feed, opts}` | Same as `:loop`, with extra options (see below) |

Options (third element):

| Key | Description |
|---|---|
| `:reply` | Arbitrary data attached to the `%TriggerEvent{}`. Also forwarded to `:after_commit` on the caller side. |
| `:relay` | Topic or list of topics to broadcast the `%TriggerEvent{}` to, in addition to the feed's own address. |

Then call it from a LiveView event handler:

```elixir
# In MyAppWeb.TodoLive

def handle_event("add_todo", %{"title" => title}, socket) do
  Feed.trigger(MyApp.Feeds.TodoList, "add_todo", %{"title" => title})

  {:noreply, socket}
end
```

`Feed.trigger/4` sends an internal message to the LiveView process. The feed's `handle_trigger/3` runs, commits any changes to `socket.assigns`, and — when it returns `:loop` — broadcasts a `%TriggerEvent{}` so other feeds subscribed to the same address react too.
