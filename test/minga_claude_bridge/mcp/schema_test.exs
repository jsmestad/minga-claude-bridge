defmodule MingaClaudeBridge.MCP.SchemaTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias MingaClaudeBridge.MCP.Schema

  @string %{"type" => "string"}
  @int %{"type" => "integer"}

  describe "flatten/1" do
    test "keeps a plain object schema unchanged" do
      schema = %{
        "type" => "object",
        "properties" => %{"path" => @string},
        "required" => ["path"],
        "additionalProperties" => false
      }

      assert Schema.flatten(schema) == schema
    end

    for {label, input, output} <- [
          {"a schema without a type", %{"properties" => %{"a" => %{}}},
           %{"type" => "object", "properties" => %{"a" => %{}}}},
          {"a scalar schema", %{"type" => "string"}, %{"type" => "object", "properties" => %{}}},
          {"a non-map value", nil, %{"type" => "object", "properties" => %{}}},
          {"non-map properties", %{"type" => "object", "properties" => []},
           %{"type" => "object", "properties" => %{}}}
        ] do
      test "makes #{label} an object schema" do
        assert Schema.flatten(unquote(Macro.escape(input))) == unquote(Macro.escape(output))
      end
    end

    test "merges anyOf branches and keeps only keys every branch requires" do
      schema = %{
        "description" => "kept",
        "anyOf" => [
          %{"properties" => %{"id" => @int, "a" => @string}, "required" => ["id", "a"]},
          %{"properties" => %{"id" => @string, "b" => @string}, "required" => ["id", "b"]}
        ]
      }

      assert Schema.flatten(schema) == %{
               "description" => "kept",
               "type" => "object",
               "properties" => %{"id" => @int, "a" => @string, "b" => @string},
               "required" => ["id"]
             }
    end

    test "drops required when no key holds in every oneOf branch" do
      schema = %{
        "oneOf" => [
          %{"properties" => %{"a" => @string}, "required" => ["a"]},
          %{"properties" => %{"b" => @string}, "required" => ["b"]}
        ]
      }

      flat = Schema.flatten(schema)
      refute Map.has_key?(flat, "required")
      assert flat["properties"] == %{"a" => @string, "b" => @string}
    end

    test "keeps root and allOf requirements" do
      schema = %{
        "properties" => %{"mode" => @string},
        "required" => ["mode"],
        "allOf" => [
          %{"properties" => %{"x" => @int}, "required" => ["x"]},
          %{"properties" => %{"y" => @int}, "required" => ["y", "x"]}
        ]
      }

      assert Schema.flatten(schema)["required"] == ["mode", "x", "y"]
    end

    test "root properties win over branch properties" do
      schema = %{
        "properties" => %{"a" => @string},
        "anyOf" => [%{"properties" => %{"a" => @int}}]
      }

      assert Schema.flatten(schema)["properties"] == %{"a" => @string}
    end

    test "follows local $ref branches into $defs and definitions" do
      schema = %{
        "$defs" => %{"A" => %{"properties" => %{"a" => @string}, "required" => ["a"]}},
        "definitions" => %{"B" => %{"properties" => %{"b" => @string}}},
        "anyOf" => [
          %{"$ref" => "#/$defs/A"},
          %{"$ref" => "#/definitions/B"},
          %{"$ref" => "#/$defs/Missing"}
        ]
      }

      assert Schema.flatten(schema)["properties"] == %{"a" => @string, "b" => @string}
    end

    test "ignores combinator values that are not lists" do
      assert Schema.flatten(%{"anyOf" => "bad"}) == %{"type" => "object", "properties" => %{}}
    end
  end

  describe "constraint_note/1" do
    for {label, schema, note} <- [
          {"no combinator", %{"type" => "object"}, nil},
          {"oneOf", %{"oneOf" => [%{"required" => ["a"]}, %{"properties" => %{"b" => %{}}}]},
           "Input constraint: Provide parameters for exactly one of: (a) or (b)."},
          {"anyOf", %{"anyOf" => [%{"required" => ["a", "b"]}, %{"required" => ["c"]}]},
           "Input constraint: Provide parameters for at least one of: (a, b) or (c)."},
          {"anyOf without named groups", %{"anyOf" => [%{}, true]},
           "Input constraint: Provide parameters for at least one of the documented parameter groups (flattened from a JSON Schema anyOf)."},
          {"allOf", %{"allOf" => [%{"required" => ["a"]}]},
           "Input constraint: all listed parameters apply together (flattened from a JSON Schema allOf)."},
          {"a non-map", "string", nil}
        ] do
      test "describes #{label}" do
        assert Schema.constraint_note(unquote(Macro.escape(schema))) == unquote(note)
      end
    end
  end

  defp name, do: string(:alphanumeric, min_length: 1, max_length: 6)

  defp branch do
    gen all(
          properties <- map_of(name(), constant(%{"type" => "string"}), max_length: 4),
          required <- list_of(name(), max_length: 3)
        ) do
      %{"properties" => properties, "required" => required}
    end
  end

  defp schema do
    gen all(
          root <- branch(),
          combinators <- list_of(member_of(["anyOf", "oneOf", "allOf"]), min_length: 1),
          branch_lists <- list_of(list_of(branch(), max_length: 4), length: length(combinators))
        ) do
      combinators |> Enum.zip(branch_lists) |> Map.new() |> Map.merge(root)
    end
  end

  defp property_names(schema) do
    branches =
      ["anyOf", "oneOf", "allOf"] |> Enum.flat_map(&Map.get(schema, &1, []))

    [schema | branches] |> Enum.flat_map(&Map.keys(&1["properties"])) |> MapSet.new()
  end

  property "the output has no top-level combinators and is an object schema" do
    check all(schema <- schema()) do
      flat = Schema.flatten(schema)
      assert flat["type"] == "object"
      refute Enum.any?(["anyOf", "oneOf", "allOf"], &Map.has_key?(flat, &1))
    end
  end

  property "every property name in the root or any branch is preserved" do
    check all(schema <- schema()) do
      assert schema |> Schema.flatten() |> Map.fetch!("properties") |> Map.keys() |> MapSet.new() ==
               property_names(schema)
    end
  end

  property "a key required by every anyOf branch stays required" do
    check all(
            shared <- name(),
            branches <- list_of(branch(), min_length: 1, max_length: 4)
          ) do
      branches = Enum.map(branches, &Map.update!(&1, "required", fn keys -> [shared | keys] end))
      assert shared in Schema.required(Schema.flatten(%{"anyOf" => branches}))
    end
  end

  property "flattening is idempotent" do
    check all(schema <- schema()) do
      flat = Schema.flatten(schema)
      assert Schema.flatten(flat) == flat
    end
  end
end
