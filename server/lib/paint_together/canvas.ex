defmodule PaintTogether.Canvas do
  @spec new() :: :ets.tid()
  def new do
    :ets.new(:canvas, [:set, :private])
  end

  @spec pixels(:ets.tid()) :: [{non_neg_integer(), non_neg_integer(), 0 | 1}]
  def pixels(canvas) do
    canvas
    |> :ets.tab2list()
    |> Enum.map(fn {idx, color} -> idx_to_pixel(idx, color) end)
  end

  @spec apply_pixels(:ets.tid(), [{integer(), integer(), integer()}]) :: [
          {non_neg_integer(), non_neg_integer(), 0 | 1}
        ]
  def apply_pixels(canvas, pixels) do
    pixels
    |> Enum.reduce(%{}, fn {x, y, color}, acc -> Map.put(acc, {x, y}, color) end)
    |> Enum.reduce([], fn {{x, y}, color}, acc ->
      if in_bounds?(x, y) do
        idx = y * PaintTogether.width() + x

        case color do
          1 ->
            true = :ets.insert(canvas, {idx, 1})
            [{x, y, 1} | acc]

          0 ->
            true = :ets.delete(canvas, idx)
            [{x, y, 0} | acc]

          _ ->
            acc
        end
      else
        acc
      end
    end)
  end

  defp in_bounds?(x, y) do
    x >= 0 and x < PaintTogether.width() and y >= 0 and y < PaintTogether.height()
  end

  defp idx_to_pixel(idx, color) do
    {rem(idx, PaintTogether.width()), div(idx, PaintTogether.width()), color}
  end
end
