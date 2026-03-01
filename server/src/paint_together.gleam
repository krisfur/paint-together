import gleam/bit_array
import gleam/list

const max_batch = 4096

pub type Pixel {
  Pixel(x: Int, y: Int, color: Int)
}

type Client {
  Client(socket: Socket, buffer: BitArray)
}

type Event {
  Event(sender: Socket, deltas: List(Pixel))
}

pub type Listener

pub type Socket

pub type Canvas

type AcceptStatus {
  Accepted(Socket)
  NoPending
  AcceptFailed
}

type RecvStatus {
  RecvData(BitArray)
  WouldBlock
  Closed
  RecvFailed
}

type DecodeStatus {
  Decoded(List(Pixel))
  Invalid
}

pub fn main() {
  let listener = start_listener(4000)
  let canvas = new_canvas()
  io_println("paint server listening on 0.0.0.0:4000")
  loop(listener, [], canvas)
}

fn loop(listener: Listener, clients: List(Client), canvas: Canvas) {
  let clients = accept_pending(listener, clients, canvas)
  let #(clients, events) = poll_clients(clients, canvas, [], [])
  broadcast_events(clients, events)
  sleep_ms(5)
  loop(listener, clients, canvas)
}

fn accept_pending(
  listener: Listener,
  clients: List(Client),
  canvas: Canvas,
) -> List(Client) {
  case accept_nonblock(listener) {
    Accepted(socket) -> {
      configure_client_socket(socket)
      send_snapshot(socket, canvas)
      accept_pending(listener, [Client(socket, <<>>), ..clients], canvas)
    }
    NoPending -> clients
    AcceptFailed -> clients
  }
}

fn poll_clients(
  clients: List(Client),
  canvas: Canvas,
  alive_acc: List(Client),
  event_acc: List(Event),
) -> #(List(Client), List(Event)) {
  case clients {
    [] -> #(list.reverse(alive_acc), list.reverse(event_acc))
    [client, ..rest] -> {
      case recv_nonblock(client.socket) {
        RecvData(data) -> {
          let buffer = bit_array.concat([client.buffer, data])
          let #(frames, rest_buffer) = split_frames(buffer)
          let deltas = process_frames(frames, canvas, [])
          let updated = Client(client.socket, rest_buffer)
          let events = case deltas {
            [] -> event_acc
            _ -> [Event(client.socket, deltas), ..event_acc]
          }
          poll_clients(rest, canvas, [updated, ..alive_acc], events)
        }
        WouldBlock ->
          poll_clients(rest, canvas, [client, ..alive_acc], event_acc)
        Closed -> {
          close_socket(client.socket)
          poll_clients(rest, canvas, alive_acc, event_acc)
        }
        RecvFailed -> {
          close_socket(client.socket)
          poll_clients(rest, canvas, alive_acc, event_acc)
        }
      }
    }
  }
}

fn process_frames(
  frames: List(BitArray),
  canvas: Canvas,
  acc: List(Pixel),
) -> List(Pixel) {
  case frames {
    [] -> list.reverse(acc)
    [frame, ..rest] ->
      case decode_draw_batch(frame) {
        Decoded(pixels) -> {
          let applied = apply_pixels(canvas, pixels)
          process_frames(rest, canvas, prepend_all(applied, acc))
        }
        Invalid -> process_frames(rest, canvas, acc)
      }
  }
}

fn prepend_all(items: List(Pixel), acc: List(Pixel)) -> List(Pixel) {
  case items {
    [] -> acc
    [item, ..rest] -> prepend_all(rest, [item, ..acc])
  }
}

fn send_snapshot(socket: Socket, canvas: Canvas) {
  send_chunks(socket, 2, canvas_pixels(canvas))
}

fn send_chunks(socket: Socket, msg_type: Int, pixels: List(Pixel)) {
  case pixels {
    [] -> Nil
    _ -> {
      let #(chunk, rest) = take_n(pixels, max_batch, [])
      let frame = encode_batch(msg_type, chunk)
      let _ = send_frame(socket, frame)
      send_chunks(socket, msg_type, rest)
    }
  }
}

fn take_n(
  items: List(Pixel),
  n: Int,
  acc: List(Pixel),
) -> #(List(Pixel), List(Pixel)) {
  case n <= 0 {
    True -> #(list.reverse(acc), items)
    False ->
      case items {
        [] -> #(list.reverse(acc), [])
        [item, ..rest] -> take_n(rest, n - 1, [item, ..acc])
      }
  }
}

fn broadcast_events(clients: List(Client), events: List(Event)) {
  case events {
    [] -> Nil
    [event, ..rest] -> {
      let frame = encode_batch(3, event.deltas)
      broadcast_one(clients, event.sender, frame)
      broadcast_events(clients, rest)
    }
  }
}

fn broadcast_one(clients: List(Client), sender: Socket, frame: BitArray) {
  case clients {
    [] -> Nil
    [client, ..rest] -> {
      case same_socket(client.socket, sender) {
        True -> Nil
        False -> {
          let _ = send_frame(client.socket, frame)
          Nil
        }
      }
      broadcast_one(rest, sender, frame)
    }
  }
}

@external(erlang, "paint_together_ffi", "io_println")
fn io_println(msg: String) -> Nil

@external(erlang, "paint_together_ffi", "start_listener")
fn start_listener(port: Int) -> Listener

@external(erlang, "paint_together_ffi", "accept_nonblock")
fn accept_nonblock(listener: Listener) -> AcceptStatus

@external(erlang, "paint_together_ffi", "configure_client_socket")
fn configure_client_socket(socket: Socket) -> Nil

@external(erlang, "paint_together_ffi", "recv_nonblock")
fn recv_nonblock(socket: Socket) -> RecvStatus

@external(erlang, "paint_together_ffi", "send_frame")
fn send_frame(socket: Socket, frame: BitArray) -> Bool

@external(erlang, "paint_together_ffi", "close_socket")
fn close_socket(socket: Socket) -> Nil

@external(erlang, "paint_together_ffi", "sleep_ms")
fn sleep_ms(ms: Int) -> Nil

@external(erlang, "paint_together_ffi", "same_socket")
fn same_socket(a: Socket, b: Socket) -> Bool

@external(erlang, "paint_together_ffi", "new_canvas")
fn new_canvas() -> Canvas

@external(erlang, "paint_together_ffi", "canvas_pixels")
fn canvas_pixels(canvas: Canvas) -> List(Pixel)

@external(erlang, "paint_together_ffi", "apply_pixels")
fn apply_pixels(canvas: Canvas, pixels: List(Pixel)) -> List(Pixel)

@external(erlang, "paint_together_ffi", "split_frames")
fn split_frames(buffer: BitArray) -> #(List(BitArray), BitArray)

@external(erlang, "paint_together_ffi", "decode_draw_batch")
fn decode_draw_batch(frame: BitArray) -> DecodeStatus

@external(erlang, "paint_together_ffi", "encode_batch")
fn encode_batch(msg_type: Int, pixels: List(Pixel)) -> BitArray
