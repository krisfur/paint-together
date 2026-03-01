# Paint Together Protocol (TCP)

All messages are sent over a single TCP stream with a length-prefixed frame:

- `length`: `u32` big-endian payload byte length
- `payload`: message bytes

## Common values

- Canvas size: `1920 x 1080`
- Pixel color in network payloads:
  - `0` = black (erase)
  - `1` = white (draw)

## Message Types

### `0x01` ClientDrawBatch (client -> server)

- `type`: `u8` (`0x01`)
- `count`: `u16` big-endian
- `pixels[count]`:
  - `x`: `u16` big-endian
  - `y`: `u16` big-endian
  - `color`: `u8`

Total payload size: `1 + 2 + count * 5`

### `0x02` SnapshotChunk (server -> client)

Sent on new client connection. Contains only non-black pixels.

- `type`: `u8` (`0x02`)
- `count`: `u16` big-endian
- `pixels[count]` as above

May be chunked across multiple frames.

### `0x03` DeltaBroadcast (server -> clients excluding sender)

- `type`: `u8` (`0x03`)
- `count`: `u16` big-endian
- `pixels[count]` as above

Carries the authoritative changed pixels accepted by the server.

## Notes

- Server validates all incoming `(x, y)` bounds.
- For duplicate coordinates in one batch, last write wins.
- Recommended max batch size per frame: `4096` pixels.
