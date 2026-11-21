defmodule MingaClaudeBridge.Wire.Field do
  @moduledoc false
  # Field readers shared by the wire decoders. Each reader returns `{:ok, value}` or `:error`.
  # A required field must be present with the right JSON type.
  # An optional field may be absent or `null`, which reads as `nil` (or the given default).
  # A present value of the wrong JSON type is an error, so malformed frames never decode into half-filled structs.

  @type json_map :: %{optional(String.t()) => term()}
  @type read(value) :: {:ok, value} | :error

  @spec string(json_map(), String.t()) :: read(String.t())
  def string(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> {:ok, value}
      _other -> :error
    end
  end

  @spec optional_string(json_map(), String.t()) :: read(String.t() | nil)
  def optional_string(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_binary(value) -> {:ok, value}
      _other -> :error
    end
  end

  @spec boolean(json_map(), String.t()) :: read(boolean())
  def boolean(map, key) do
    case Map.get(map, key) do
      value when is_boolean(value) -> {:ok, value}
      _other -> :error
    end
  end

  @spec optional_boolean(json_map(), String.t(), boolean()) :: read(boolean())
  def optional_boolean(map, key, default) do
    case Map.get(map, key) do
      nil -> {:ok, default}
      value when is_boolean(value) -> {:ok, value}
      _other -> :error
    end
  end

  @spec map(json_map(), String.t()) :: read(json_map())
  def map(map, key) do
    case Map.get(map, key) do
      value when is_map(value) -> {:ok, value}
      _other -> :error
    end
  end

  @spec optional_map(json_map(), String.t()) :: read(json_map() | nil)
  def optional_map(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_map(value) -> {:ok, value}
      _other -> :error
    end
  end

  @spec list(json_map(), String.t()) :: read(list())
  def list(map, key) do
    case Map.get(map, key) do
      value when is_list(value) -> {:ok, value}
      _other -> :error
    end
  end

  @spec string_list(json_map(), String.t()) :: read([String.t()])
  def string_list(map, key) do
    case Map.get(map, key) do
      value when is_list(value) -> all_strings(value)
      _other -> :error
    end
  end

  @spec optional_string_list(json_map(), String.t()) :: read([String.t()] | nil)
  def optional_string_list(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_list(value) -> all_strings(value)
      _other -> :error
    end
  end

  @spec non_neg_integer(json_map(), String.t()) :: read(non_neg_integer())
  def non_neg_integer(map, key) do
    case Map.get(map, key) do
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> :error
    end
  end

  @spec optional_non_neg_integer(json_map(), String.t()) :: read(non_neg_integer() | nil)
  def optional_non_neg_integer(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_integer(value) and value >= 0 -> {:ok, value}
      _other -> :error
    end
  end

  @spec optional_number(json_map(), String.t()) :: read(number() | nil)
  def optional_number(map, key) do
    case Map.get(map, key) do
      nil -> {:ok, nil}
      value when is_number(value) -> {:ok, value}
      _other -> :error
    end
  end

  @doc """
  Reads an optional string field and maps it through a closed table of known values. A known value becomes its atom. An unknown string becomes `{:other, string}`, so new CLI values never create atoms and never fail decoding.
  """
  @spec optional_enum(json_map(), String.t(), %{String.t() => atom()}) ::
          read(atom() | {:other, String.t()} | nil)
  def optional_enum(map, key, table) do
    case optional_string(map, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> {:ok, Map.get(table, value, {:other, value})}
      :error -> :error
    end
  end

  @spec enum(json_map(), String.t(), %{String.t() => atom()}) ::
          read(atom() | {:other, String.t()})
  def enum(map, key, table) do
    case string(map, key) do
      {:ok, value} -> {:ok, Map.get(table, value, {:other, value})}
      :error -> :error
    end
  end

  @doc "Decodes every element with `fun`, failing if any element fails."
  @spec each(list(), (term() -> read(value))) :: read([value]) when value: term()
  def each(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :error -> :error
    end
  end

  defp all_strings(values) do
    if Enum.all?(values, &is_binary/1), do: {:ok, values}, else: :error
  end
end
