defmodule PaintTogether.Protocol do
  @draw_batch 0x01

  @spec split_frames(binary()) :: {[binary()], binary()}
  def split_frames(buffer), do: split_frames(buffer, [])

  @spec decode_draw_batch(binary()) ::
          {:ok, [{non_neg_integer(), non_neg_integer(), 0 | 1}]} | :error
  def decode_draw_batch(<<@draw_batch, count::16-big, rest::binary>>) do
    expected_size = count * 5

    if byte_size(rest) == expected_size do
      decode_pixels(rest, [])
    else
      :error
    end
  end

  def decode_draw_batch(_payload), do: :error

  @spec encode_batch(non_neg_integer(), [{non_neg_integer(), non_neg_integer(), 0 | 1}]) ::
          binary()
  def encode_batch(type, pixels) do
    payload = [<<type, length(pixels)::16-big>>, Enum.map(pixels, &encode_pixel/1)]
    payload_bin = IO.iodata_to_binary(payload)
    <<byte_size(payload_bin)::32-big, payload_bin::binary>>
  end

  defp split_frames(<<length::32-big, rest::binary>>, acc) when byte_size(rest) >= length do
    <<payload::binary-size(length), tail::binary>> = rest
    split_frames(tail, [payload | acc])
  end

  defp split_frames(buffer, acc) do
    {Enum.reverse(acc), buffer}
  end

  defp decode_pixels(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp decode_pixels(<<x::16-big, y::16-big, color, rest::binary>>, acc)
       when color in [0, 1] do
    decode_pixels(rest, [{x, y, color} | acc])
  end

  defp decode_pixels(_, _acc), do: :error

  defp encode_pixel({x, y, color}) do
    <<x::16-big, y::16-big, color>>
  end
end
