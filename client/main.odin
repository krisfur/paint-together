package main

import "core:fmt"
import "core:net"
import "core:os"
import rl "vendor:raylib"

WINDOW_WIDTH  :: 1920
WINDOW_HEIGHT :: 1080
PIXEL_COUNT   :: WINDOW_WIDTH * WINDOW_HEIGHT

DEFAULT_WINDOW_WIDTH  :: 1280
DEFAULT_WINDOW_HEIGHT :: 720

MSG_DRAW_BATCH :: u8(0x01)
MSG_SNAPSHOT   :: u8(0x02)
MSG_DELTA      :: u8(0x03)

MAX_BATCH_PIXELS :: 4096
RECONNECT_INTERVAL_SECONDS :: 1.0

PixelDelta :: struct {
	x: u16,
	y: u16,
	c: u8,
}

paint_pixel :: proc(
	x: int,
	y: int,
	color: u8,
	pixel_state: []u8,
	pixels: []rl.Color,
	dirty_flags: []bool,
	dirty_indices: ^[dynamic]int,
) {
	if x < 0 || x >= WINDOW_WIDTH || y < 0 || y >= WINDOW_HEIGHT {
		return
	}

	idx := y * WINDOW_WIDTH + x
	if pixel_state[idx] == color {
		return
	}

	pixel_state[idx] = color
	if color == 1 {
		pixels[idx] = rl.WHITE
	} else {
		pixels[idx] = rl.BLACK
	}

	if !dirty_flags[idx] {
		dirty_flags[idx] = true
		append(dirty_indices, idx)
	}
}

reset_canvas :: proc(pixel_state: []u8, pixels: []rl.Color, dirty_flags: []bool, dirty_indices: ^[dynamic]int) {
	for i := 0; i < PIXEL_COUNT; i += 1 {
		pixel_state[i] = 0
		pixels[i] = rl.BLACK
		dirty_flags[i] = false
	}
	resize(dirty_indices, 0)
}

paint_brush :: proc(
	x: int,
	y: int,
	color: u8,
	brush_size: int,
	pixel_state: []u8,
	pixels: []rl.Color,
	dirty_flags: []bool,
	dirty_indices: ^[dynamic]int,
) {
	size := brush_size
	if size < 1 {
		size = 1
	}

	radius := size / 2
	for by := -radius; by <= radius; by += 1 {
		for bx := -radius; bx <= radius; bx += 1 {
			paint_pixel(x+bx, y+by, color, pixel_state, pixels, dirty_flags, dirty_indices)
		}
	}
}

abs_int :: proc(v: int) -> int {
	if v < 0 {
		return -v
	}
	return v
}

paint_stroke :: proc(
	x0: int,
	y0: int,
	x1: int,
	y1: int,
	color: u8,
	brush_size: int,
	pixel_state: []u8,
	pixels: []rl.Color,
	dirty_flags: []bool,
	dirty_indices: ^[dynamic]int,
) {
	dx := x1 - x0
	dy := y1 - y0
	steps := abs_int(dx)
	if abs_int(dy) > steps {
		steps = abs_int(dy)
	}

	if steps <= 0 {
		paint_brush(x0, y0, color, brush_size, pixel_state, pixels, dirty_flags, dirty_indices)
		return
	}

	for i := 0; i <= steps; i += 1 {
		x := x0 + (dx*i)/steps
		y := y0 + (dy*i)/steps
		paint_brush(x, y, color, brush_size, pixel_state, pixels, dirty_flags, dirty_indices)
	}
}

be_u16 :: proc(v: u16, buf: ^[dynamic]u8) {
	append(buf, u8(v >> 8))
	append(buf, u8(v & 0xFF))
}

be_u32 :: proc(v: u32, buf: ^[dynamic]u8) {
	append(buf, u8(v >> 24))
	append(buf, u8((v >> 16) & 0xFF))
	append(buf, u8((v >> 8) & 0xFF))
	append(buf, u8(v & 0xFF))
}

read_be_u16 :: proc(buf: []u8, idx: int) -> u16 {
	return (u16(buf[idx]) << 8) | u16(buf[idx+1])
}

read_be_u32 :: proc(buf: []u8, idx: int) -> u32 {
	return (u32(buf[idx]) << 24) |
		(u32(buf[idx+1]) << 16) |
		(u32(buf[idx+2]) << 8) |
		u32(buf[idx+3])
}

send_batch :: proc(sock: net.TCP_Socket, msg_type: u8, deltas: []PixelDelta) {
	if len(deltas) <= 0 {
		return
	}

	payload_len := 1 + 2 + len(deltas) * 5
	frame := make([dynamic]u8, 0, 4+payload_len)

	be_u32(u32(payload_len), &frame)
	append(&frame, msg_type)
	be_u16(u16(len(deltas)), &frame)

	for d in deltas {
		be_u16(d.x, &frame)
		be_u16(d.y, &frame)
		append(&frame, d.c)
	}

	_, send_err := net.send_tcp(sock, frame[:])
	if send_err != .None {
		fmt.eprintln("send error: %v", send_err)
	}
}

append_bytes :: proc(dst: ^[dynamic]u8, src: []u8) {
	for b in src {
		append(dst, b)
	}
}

compact_buffer :: proc(buf: ^[dynamic]u8, consumed: int) {
	if consumed <= 0 {
		return
	}

	remaining := len(buf^) - consumed
	if remaining <= 0 {
		resize(buf, 0)
		return
	}

	for i := 0; i < remaining; i += 1 {
		buf^[i] = buf^[i+consumed]
	}
	resize(buf, remaining)
}

apply_payload :: proc(payload: []u8, pixel_state: []u8, pixels: []rl.Color) {
	if len(payload) < 3 {
		return
	}

	msg_type := payload[0]
	if msg_type != MSG_SNAPSHOT && msg_type != MSG_DELTA {
		return
	}

	count := int(read_be_u16(payload, 1))
	need := 3 + count*5
	if len(payload) < need {
		return
	}

	offset := 3
	for i := 0; i < count; i += 1 {
		x := int(read_be_u16(payload, offset)); offset += 2
		y := int(read_be_u16(payload, offset)); offset += 2
		c := payload[offset]; offset += 1

		if x < 0 || x >= WINDOW_WIDTH || y < 0 || y >= WINDOW_HEIGHT {
			continue
		}

		idx := y * WINDOW_WIDTH + x
		pixel_state[idx] = c
		if c == 1 {
			pixels[idx] = rl.WHITE
		} else {
			pixels[idx] = rl.BLACK
		}
	}
}

poll_network :: proc(sock: net.TCP_Socket, rx_buf: ^[dynamic]u8, pixel_state: []u8, pixels: []rl.Color) -> bool {
	tmp: [65536]u8
	keep_running := true

	for {
		read_n, read_err := net.recv_tcp(sock, tmp[:])
		if read_err == .Would_Block {
			break
		}

		if read_err != .None {
			fmt.eprintln("recv error: %v", read_err)
			keep_running = false
			break
		}

		if read_n == 0 {
			fmt.eprintln("server closed connection")
			keep_running = false
			break
		}

		append_bytes(rx_buf, tmp[:read_n])
	}

	consumed := 0
	for {
		if len(rx_buf^) - consumed < 4 {
			break
		}

		rx := (rx_buf^)[:]

		payload_len := int(read_be_u32(rx, consumed))
		frame_need := 4 + payload_len
		if len(rx_buf^)-consumed < frame_need {
			break
		}

		start := consumed + 4
		end := start + payload_len
		apply_payload(rx[start:end], pixel_state, pixels)
		consumed += frame_need
	}

	compact_buffer(rx_buf, consumed)
	return keep_running
}

try_connect :: proc(host: string) -> (connected: bool, sock: net.TCP_Socket) {
	s, dial_err := net.dial_tcp_from_hostname_and_port_string(host)
	if dial_err != nil {
		return false, s
	}

	block_err := net.set_blocking(s, false)
	if block_err != .None {
		net.close(s)
		return false, s
	}

	return true, s
}

main :: proc() {
	host := "127.0.0.1:4000"
	if len(os.args) > 1 {
		host = os.args[1]
	}

	pixels := make([]rl.Color, PIXEL_COUNT)
	pixel_state := make([]u8, PIXEL_COUNT)
	dirty_flags := make([]bool, PIXEL_COUNT)
	dirty_indices := make([dynamic]int, 0, 4096)
	reset_canvas(pixel_state, pixels, dirty_flags, &dirty_indices)

	rx_buf := make([dynamic]u8, 0, 1<<20)

	rl.SetConfigFlags({.WINDOW_RESIZABLE})
	rl.InitWindow(DEFAULT_WINDOW_WIDTH, DEFAULT_WINDOW_HEIGHT, "paint together")
	defer rl.CloseWindow()
	rl.SetTargetFPS(60)

	image := rl.GenImageColor(WINDOW_WIDTH, WINDOW_HEIGHT, rl.BLACK)
	texture := rl.LoadTextureFromImage(image)
	rl.UnloadImage(image)
	defer rl.UnloadTexture(texture)

	left_was_down := false
	right_was_down := false
	prev_left_x, prev_left_y := 0, 0
	prev_right_x, prev_right_y := 0, 0
	connected := false
	sock: net.TCP_Socket
	next_reconnect_at := 0.0

	for !rl.WindowShouldClose() {
		now := rl.GetTime()
		if !connected && now >= next_reconnect_at {
			ok := false
			ok, sock = try_connect(host)
			if ok {
				connected = true
				resize(&rx_buf, 0)
				reset_canvas(pixel_state, pixels, dirty_flags, &dirty_indices)
				left_was_down = false
				right_was_down = false
				fmt.println("reconnected to %s", host)
			} else {
				next_reconnect_at = now + RECONNECT_INTERVAL_SECONDS
			}
		}

		if connected {
			running := poll_network(sock, &rx_buf, pixel_state, pixels)
			if !running {
				net.close(sock)
				connected = false
				next_reconnect_at = now + RECONNECT_INTERVAL_SECONDS
				left_was_down = false
				right_was_down = false
				resize(&dirty_indices, 0)
				fmt.eprintln("server not responding, reconnecting...")
			}
		}

		screen_w := int(rl.GetScreenWidth())
		screen_h := int(rl.GetScreenHeight())
		if screen_w <= 0 || screen_h <= 0 {
			screen_w = 1
			screen_h = 1
		}

		brush_x := (WINDOW_WIDTH + screen_w - 1) / screen_w
		brush_y := (WINDOW_HEIGHT + screen_h - 1) / screen_h
		draw_brush_size := brush_x
		if brush_y > draw_brush_size {
			draw_brush_size = brush_y
		}
		if draw_brush_size < 1 {
			draw_brush_size = 1
		}
		erase_brush_size := draw_brush_size*2 + 1

		scale_x := f32(screen_w) / f32(WINDOW_WIDTH)
		scale_y := f32(screen_h) / f32(WINDOW_HEIGHT)
		scale := scale_x
		if scale_y < scale {
			scale = scale_y
		}
		if scale <= 0 {
			scale = 1
		}

		draw_w := f32(WINDOW_WIDTH) * scale
		draw_h := f32(WINDOW_HEIGHT) * scale
		offset_x := (f32(screen_w) - draw_w) * 0.5
		offset_y := (f32(screen_h) - draw_h) * 0.5

		mouse := rl.GetMousePosition()
		mx := int((mouse.x - offset_x) / scale)
		my := int((mouse.y - offset_y) / scale)
		mouse_in_canvas :=
			mouse.x >= offset_x &&
			mouse.y >= offset_y &&
			mouse.x < offset_x + draw_w &&
			mouse.y < offset_y + draw_h

		if !mouse_in_canvas {
			mx = int(mouse.x * f32(WINDOW_WIDTH) / f32(screen_w))
			my = int(mouse.y * f32(WINDOW_HEIGHT) / f32(screen_h))
		}

		if mx < 0 {
			mx = 0
		} else if mx >= WINDOW_WIDTH {
			mx = WINDOW_WIDTH - 1
		}
		if my < 0 {
			my = 0
		} else if my >= WINDOW_HEIGHT {
			my = WINDOW_HEIGHT - 1
		}

		left_down := connected && rl.IsMouseButtonDown(.LEFT)
		if left_down {
			if left_was_down {
				paint_stroke(prev_left_x, prev_left_y, mx, my, 1, draw_brush_size, pixel_state, pixels, dirty_flags, &dirty_indices)
			} else {
				paint_brush(mx, my, 1, draw_brush_size, pixel_state, pixels, dirty_flags, &dirty_indices)
			}
			prev_left_x = mx
			prev_left_y = my
		}
		left_was_down = left_down

		right_down := connected && rl.IsMouseButtonDown(.RIGHT)
		if right_down {
			if right_was_down {
				paint_stroke(prev_right_x, prev_right_y, mx, my, 0, erase_brush_size, pixel_state, pixels, dirty_flags, &dirty_indices)
			} else {
				paint_brush(mx, my, 0, erase_brush_size, pixel_state, pixels, dirty_flags, &dirty_indices)
			}
			prev_right_x = mx
			prev_right_y = my
		}
		right_was_down = right_down

		if connected && len(dirty_indices) > 0 {
			batch := make([dynamic]PixelDelta, 0, MAX_BATCH_PIXELS)
			for idx in dirty_indices {
				x := idx % WINDOW_WIDTH
				y := idx / WINDOW_WIDTH
				c := pixel_state[idx]
				append(&batch, PixelDelta{x = u16(x), y = u16(y), c = c})
				dirty_flags[idx] = false

				if len(batch) >= MAX_BATCH_PIXELS {
					send_batch(sock, MSG_DRAW_BATCH, batch[:])
					resize(&batch, 0)
				}
			}

			if len(batch) > 0 {
				send_batch(sock, MSG_DRAW_BATCH, batch[:])
			}

			resize(&dirty_indices, 0)
		}

		rl.UpdateTexture(texture, raw_data(pixels))

		rl.BeginDrawing()
		rl.ClearBackground(rl.BLACK)
		src := rl.Rectangle{0, 0, f32(WINDOW_WIDTH), f32(WINDOW_HEIGHT)}
		dst := rl.Rectangle{offset_x, offset_y, draw_w, draw_h}
		rl.DrawTexturePro(texture, src, dst, rl.Vector2{0, 0}, 0, rl.WHITE)
		if !connected {
			rl.DrawRectangle(0, 0, i32(screen_w), 44, rl.Color{0, 0, 0, 180})
			rl.DrawText("SERVER NOT RESPONDING - waiting to reconnect...", 12, 12, 20, rl.WHITE)
		}
		rl.EndDrawing()
	}

	if connected {
		net.close(sock)
	}
}
