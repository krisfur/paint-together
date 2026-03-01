-module(paint_together_ffi).

-export([
    io_println/1,
    start_listener/1,
    accept_nonblock/1,
    configure_client_socket/1,
    recv_nonblock/1,
    send_frame/2,
    close_socket/1,
    sleep_ms/1,
    same_socket/2,
    new_canvas/0,
    canvas_pixels/1,
    apply_pixels/2,
    split_frames/1,
    decode_draw_batch/1,
    encode_batch/2
]).

-define(WIDTH, 1920).
-define(HEIGHT, 1080).

io_println(Msg) ->
    io:format("~s~n", [Msg]),
    nil.

start_listener(Port) when is_integer(Port) ->
    {ok, Listener} = gen_tcp:listen(Port, [
        binary,
        {packet, 0},
        {active, false},
        {reuseaddr, true},
        {nodelay, true},
        {backlog, 128}
    ]),
    Listener.

accept_nonblock(Listener) ->
    case gen_tcp:accept(Listener, 0) of
        {ok, Socket} -> {accepted, Socket};
        {error, timeout} -> no_pending;
        {error, _} -> accept_failed
    end.

configure_client_socket(Socket) ->
    _ = inet:setopts(Socket, [{active, false}, {nodelay, true}]),
    nil.

recv_nonblock(Socket) ->
    case gen_tcp:recv(Socket, 0, 0) of
        {ok, Data} -> {recv_data, Data};
        {error, timeout} -> would_block;
        {error, closed} -> closed;
        {error, _} -> recv_failed
    end.

send_frame(Socket, Frame) ->
    case gen_tcp:send(Socket, Frame) of
        ok -> true;
        {error, _} -> false
    end.

close_socket(Socket) ->
    _ = gen_tcp:close(Socket),
    nil.

sleep_ms(Ms) ->
    _ = timer:sleep(Ms),
    nil.

same_socket(A, B) ->
    A =:= B.

new_canvas() ->
    ets:new(canvas, [set, private]).

canvas_pixels(Canvas) ->
    [idx_to_pixel(Idx, Color) || {Idx, Color} <- ets:tab2list(Canvas)].

apply_pixels(Canvas, Pixels) ->
    Dedup = lists:foldl(
      fun({pixel, X, Y, C}, Acc) -> maps:put({X, Y}, C, Acc) end,
      #{},
      Pixels
    ),
    maps:fold(
      fun({X, Y}, C, Out) ->
          case in_bounds(X, Y) of
              false -> Out;
              true ->
                  Idx = Y * ?WIDTH + X,
                  case C of
                      1 ->
                          ets:insert(Canvas, {Idx, 1}),
                          [{pixel, X, Y, 1} | Out];
                      0 ->
                          ets:delete(Canvas, Idx),
                          [{pixel, X, Y, 0} | Out];
                      _ ->
                          Out
                  end
          end
      end,
      [],
      Dedup
    ).

split_frames(Bin) ->
    split_frames(Bin, []).

split_frames(Bin, FramesRev) when byte_size(Bin) < 4 ->
    {lists:reverse(FramesRev), Bin};
split_frames(Bin, FramesRev) ->
    <<Len:32/big-unsigned, Tail0/binary>> = Bin,
    case byte_size(Tail0) >= Len of
        true ->
            <<Payload:Len/binary, Tail1/binary>> = Tail0,
            split_frames(Tail1, [Payload | FramesRev]);
        false ->
            {lists:reverse(FramesRev), Bin}
    end.

decode_draw_batch(<<16#01:8, Count:16/big-unsigned, Rest/binary>>) ->
    decode_pixels(Count, Rest, []);
decode_draw_batch(_) ->
    invalid.

decode_pixels(0, _Rest, AccRev) ->
    {decoded, lists:reverse(AccRev)};
decode_pixels(N, <<X:16/big-unsigned, Y:16/big-unsigned, C:8, Tail/binary>>, AccRev) ->
    decode_pixels(N - 1, Tail, [{pixel, X, Y, C} | AccRev]);
decode_pixels(_, _, _) ->
    invalid.

encode_batch(Type, Pixels) when is_integer(Type) ->
    Count = length(Pixels),
    Payload = [
        <<Type:8, Count:16/big-unsigned>>,
        [<<X:16/big-unsigned, Y:16/big-unsigned, C:8>> || {pixel, X, Y, C} <- Pixels]
    ],
    PayloadBin = iolist_to_binary(Payload),
    <<(byte_size(PayloadBin)):32/big-unsigned, PayloadBin/binary>>.

in_bounds(X, Y) ->
    X >= 0 andalso X < ?WIDTH andalso Y >= 0 andalso Y < ?HEIGHT.

idx_to_pixel(Idx, Color) ->
    X = Idx rem ?WIDTH,
    Y = Idx div ?WIDTH,
    {pixel, X, Y, Color}.
