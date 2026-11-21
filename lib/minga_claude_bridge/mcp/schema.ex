defmodule MingaClaudeBridge.MCP.Schema do
  @moduledoc """
  Prepares tool input schemas for Claude Code's MCP client.

  Claude Code drops an MCP tool whose input schema has a top-level `anyOf`, `oneOf`, or `allOf`, because the Anthropic API does not accept those at the root. `flatten/1` turns such a schema into one object schema, the same way pi-claude-bridge and Claude Code's own normalizer do:

    * Properties are merged. Root properties win over branch properties, then branches are read in `anyOf`, `oneOf`, `allOf` order and the first branch that names a property wins.
    * A branch that is a local `$ref` into the root's `$defs` or `definitions` is followed.
    * A key stays required when the root requires it, when an `allOf` branch requires it, or when every branch of an `anyOf` (or every branch of a `oneOf`) requires it. A key that only some `anyOf`/`oneOf` branches require is dropped from `required`, because it holds only for one branch.
    * The result always has `"type" => "object"` and a `"properties"` map.

  Flattening loses the "one of these groups" constraint. `constraint_note/1` restates it in Claude Code's wording, for the tool description, so the model's first call is likely to pass Minga's validation against the full schema. Minga still validates arguments against the original schema; the bridge only checks the flattened shape (see `MingaClaudeBridge.MCP`).

  Schemas use string keys, as decoded from JSON.
  """

  @combinators ["anyOf", "oneOf", "allOf"]

  @typedoc "A JSON Schema with string keys."
  @type t :: %{optional(String.t()) => term()}

  @doc """
  Returns an object schema without top-level combinators.

  A schema with no top-level combinator keeps every field and only gains `"type" => "object"` and an empty `"properties"` map when they are missing. A value that is not a map becomes an empty object schema.
  """
  @spec flatten(term()) :: t()
  def flatten(schema) when is_map(schema) do
    case present_combinators(schema) do
      [] -> ensure_object(schema)
      combinators -> merge_branches(schema, combinators)
    end
  end

  def flatten(_schema), do: %{"type" => "object", "properties" => %{}}

  @doc """
  Returns the constraint that `flatten/1` removes, as a sentence for the tool description, or `nil` when the schema has no top-level combinator.
  """
  @spec constraint_note(term()) :: String.t() | nil
  def constraint_note(schema) when is_map(schema) do
    combinators = present_combinators(schema)

    cond do
      combinators == [] ->
        nil

      "oneOf" in combinators ->
        group_note(schema, "oneOf", "Provide parameters for exactly one of")

      "anyOf" in combinators ->
        group_note(schema, "anyOf", "Provide parameters for at least one of")

      true ->
        "Input constraint: all listed parameters apply together (flattened from a JSON Schema allOf)."
    end
  end

  def constraint_note(_schema), do: nil

  @doc "Returns the `required` property names of a flattened schema."
  @spec required(t()) :: [String.t()]
  def required(%{"required" => keys}) when is_list(keys), do: Enum.filter(keys, &is_binary/1)
  def required(_schema), do: []

  defp present_combinators(schema), do: Enum.filter(@combinators, &Map.has_key?(schema, &1))

  defp ensure_object(schema) do
    schema
    |> Map.put("type", "object")
    |> Map.update("properties", %{}, &properties_or_empty/1)
  end

  defp properties_or_empty(properties) when is_map(properties), do: properties
  defp properties_or_empty(_other), do: %{}

  defp merge_branches(schema, combinators) do
    rest = Map.drop(schema, @combinators)

    properties =
      Enum.reduce(combinators, properties_of(schema), fn key, acc ->
        schema |> branches(key) |> Enum.reduce(acc, &merge_properties/2)
      end)

    required =
      [required_of(schema), all_of_required(schema) | one_branch_required(schema, combinators)]
      |> Enum.concat()
      |> Enum.uniq()

    flat = Map.merge(rest, %{"type" => "object", "properties" => properties})

    case required do
      [] -> Map.delete(flat, "required")
      keys -> Map.put(flat, "required", keys)
    end
  end

  defp merge_properties(branch, acc), do: Map.merge(properties_of(branch), acc)

  defp all_of_required(schema),
    do: schema |> branches("allOf") |> Enum.flat_map(&required_of/1)

  # A key every branch of an anyOf (or oneOf) requires holds whichever branch matches.
  defp one_branch_required(schema, combinators) do
    for key <- ["anyOf", "oneOf"], key in combinators do
      schema |> branches(key) |> required_by_all()
    end
  end

  defp required_by_all([]), do: []

  defp required_by_all([first | others]) do
    Enum.filter(required_of(first), fn name -> Enum.all?(others, &(name in required_of(&1))) end)
  end

  defp branches(schema, key) do
    case Map.get(schema, key) do
      list when is_list(list) -> Enum.map(list, &resolve_local_ref(&1, schema))
      _other -> []
    end
  end

  defp resolve_local_ref(%{"$ref" => "#/" <> pointer} = branch, root) do
    with [section, name] when section in ["$defs", "definitions"] <- String.split(pointer, "/"),
         %{^name => target} when is_map(target) <- Map.get(root, section) do
      target
    else
      _other -> branch
    end
  end

  defp resolve_local_ref(branch, _root), do: branch

  defp properties_of(%{"properties" => properties}) when is_map(properties), do: properties
  defp properties_of(_branch), do: %{}

  defp required_of(%{"required" => keys}) when is_list(keys), do: Enum.filter(keys, &is_binary/1)
  defp required_of(_branch), do: []

  defp group_note(schema, key, rule) do
    case schema
         |> branches(key)
         |> Enum.map(&branch_group/1)
         |> Enum.reject(&is_nil/1)
         |> Enum.uniq() do
      [] ->
        "Input constraint: #{rule} the documented parameter groups (flattened from a JSON Schema #{key})."

      groups ->
        "Input constraint: #{rule}: #{Enum.map_join(groups, " or ", &"(#{&1})")}."
    end
  end

  # A branch is named by its required keys, else by all of its property names.
  defp branch_group(branch) when is_map(branch) do
    case {required_of(branch), properties_of(branch) |> Map.keys()} do
      {[_ | _] = required, _keys} -> Enum.join(required, ", ")
      {[], [_ | _] = keys} -> Enum.join(keys, ", ")
      {[], []} -> nil
    end
  end

  defp branch_group(_branch), do: nil
end
