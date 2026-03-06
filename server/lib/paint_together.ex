defmodule PaintTogether do
  @width 1920
  @height 1080
  @max_batch 4096
  @default_port 4000

  def width, do: @width
  def height, do: @height
  def max_batch, do: @max_batch
  def default_port, do: @default_port
end
