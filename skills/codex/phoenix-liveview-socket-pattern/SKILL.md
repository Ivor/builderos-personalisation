---
name: phoenix-liveview-socket-pattern
description: Use when writing or refactoring Phoenix LiveView or LiveComponent callbacks that return {:noreply, socket}, especially handle_event/3, handle_info/2, or handle_async/3 callbacks with case, if, or with branches. Enforces assigning socket transformations and returning the updated socket once.
---

# Phoenix LiveView Socket Pattern

Enforce a consistent pattern in Phoenix LiveView and LiveComponent event handlers where socket transformations are collected and a single `{:noreply, socket}` is returned at the end of the function.

## When to Use This Skill

Use this skill when:
- Writing new `handle_event` functions in LiveViews or LiveComponents
- Refactoring existing event handlers that have multiple `{:noreply, socket}` returns
- Code review identifies inconsistent socket return patterns
- Event handlers contain complex conditional logic (case/if/with statements)

## The Pattern

### Problem

Event handlers with multiple return points are harder to maintain and track socket state:

```elixir
def handle_event("save", params, socket) do
  case validate(params) do
    {:ok, data} ->
      {:noreply, socket |> assign(:data, data) |> put_flash(:info, "Saved")}

    {:error, reason} ->
      {:noreply, put_flash(socket, :error, reason)}
  end
end
```

### Solution

Assign the socket transformation result, then return once:

```elixir
def handle_event("save", params, socket) do
  socket =
    case validate(params) do
      {:ok, data} ->
        socket
        |> assign(:data, data)
        |> put_flash(:info, "Saved")

      {:error, reason} ->
        put_flash(socket, :error, reason)
    end

  {:noreply, socket}
end
```

## Implementation Steps

When refactoring an event handler:

1. **Identify all return points** - Find every `{:noreply, socket}` or `{:noreply, ...}` in the function

2. **Extract socket transformations** - For each branch:
   - Remove the `{:noreply, ...}` wrapper
   - Keep only the socket transformation expression
   - Ensure the expression returns the socket

3. **Assign to socket variable** - Wrap the case/if/with statement:
   ```elixir
   socket =
     case ... do
       pattern -> socket_transformation
     end
   ```

4. **Add single return** - End the function with:
   ```elixir
   {:noreply, socket}
   ```

## Examples

### Example 1: Simple Case Statement

**Before:**
```elixir
def handle_event("toggle", %{"id" => id}, socket) do
  case toggle_item(id) do
    {:ok, item} ->
      {:noreply, assign(socket, :item, item)}

    {:error, _} ->
      {:noreply, put_flash(socket, :error, "Failed")}
  end
end
```

**After:**
```elixir
def handle_event("toggle", %{"id" => id}, socket) do
  socket =
    case toggle_item(id) do
      {:ok, item} ->
        assign(socket, :item, item)

      {:error, _} ->
        put_flash(socket, :error, "Failed")
    end

  {:noreply, socket}
end
```

### Example 2: Nested If/Else

**Before:**
```elixir
def handle_event("submit", params, socket) do
  if valid?(params) do
    case save(params) do
      {:ok, record} ->
        {:noreply, assign(socket, :record, record)}
      {:error, _} ->
        {:noreply, socket}
    end
  else
    {:noreply, put_flash(socket, :error, "Invalid")}
  end
end
```

**After:**
```elixir
def handle_event("submit", params, socket) do
  socket =
    if valid?(params) do
      case save(params) do
        {:ok, record} ->
          assign(socket, :record, record)
        {:error, _} ->
          socket
      end
    else
      put_flash(socket, :error, "Invalid")
    end

  {:noreply, socket}
end
```

### Example 3: With Statement

**Before:**
```elixir
def handle_event("process", params, socket) do
  with {:ok, data} <- parse(params),
       {:ok, result} <- process(data) do
    {:noreply,
     socket
     |> assign(:result, result)
     |> put_flash(:info, "Success")}
  else
    {:error, reason} ->
      {:noreply, put_flash(socket, :error, reason)}
  end
end
```

**After:**
```elixir
def handle_event("process", params, socket) do
  socket =
    with {:ok, data} <- parse(params),
         {:ok, result} <- process(data) do
      socket
      |> assign(:result, result)
      |> put_flash(:info, "Success")
    else
      {:error, reason} ->
        put_flash(socket, :error, reason)
    end

  {:noreply, socket}
end
```

## Benefits

1. **Consistency** - All event handlers follow the same pattern
2. **Maintainability** - Socket state flow is clear and traceable
3. **Debuggability** - Single place to add logging or debugging
4. **Refactoring-friendly** - Easy to add additional socket transformations
5. **Review-friendly** - Clear socket flow makes code review easier

## Common Mistakes to Avoid

### Mistake 1: Returning from inside the case

```elixir
# Wrong
socket =
  case foo do
    :ok -> {:noreply, socket}  # Don't return here
  end

{:noreply, socket}
```

```elixir
# Correct
socket =
  case foo do
    :ok -> socket  # Just return the socket
  end

{:noreply, socket}
```

### Mistake 2: Not assigning the result

```elixir
# Wrong
case foo do
  :ok -> assign(socket, :data, data)
  :error -> socket
end

{:noreply, socket}  # socket hasn't been updated!
```

```elixir
# Correct
socket =
  case foo do
    :ok -> assign(socket, :data, data)
    :error -> socket
  end

{:noreply, socket}
```

### Mistake 3: Forgetting to return socket from branches

```elixir
# Wrong
socket =
  case foo do
    :ok ->
      Logger.info("Success")  # Returns :ok, not socket!
  end

{:noreply, socket}
```

```elixir
# Correct
socket =
  case foo do
    :ok ->
      Logger.info("Success")
      socket  # Explicitly return socket
  end

{:noreply, socket}
```

## Related Patterns

This pattern also applies to:
- `handle_info/2` callbacks
- `handle_async/3` callbacks
- Any LiveView/LiveComponent callback that returns `{:noreply, socket}`

The same principle applies: collect socket transformations, return once.
