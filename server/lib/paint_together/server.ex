defmodule PaintTogether.Server do
  use GenServer

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    port = Keyword.get(opts, :port, PaintTogether.default_port())

    {:ok, listener} =
      :gen_tcp.listen(port, [
        :binary,
        packet: 0,
        active: false,
        reuseaddr: true,
        nodelay: true,
        backlog: 128
      ])

    canvas = PaintTogether.Canvas.new()
    server_pid = self()
    acceptor = spawn_link(fn -> accept_loop(listener, server_pid) end)

    Logger.info("paint server listening on 0.0.0.0:#{port}")

    {:ok, %{listener: listener, acceptor: acceptor, canvas: canvas, clients: %{}}}
  end

  @impl true
  def handle_info({:client_connected, client_pid}, state) do
    ref = Process.monitor(client_pid)
    send_snapshot(client_pid, state.canvas)
    {:noreply, %{state | clients: Map.put(state.clients, client_pid, ref)}}
  end

  def handle_info({:client_batch, sender_pid, pixels}, state) do
    applied = PaintTogether.Canvas.apply_pixels(state.canvas, pixels)

    if applied != [] do
      frame = PaintTogether.Protocol.encode_batch(0x03, applied)

      Enum.each(state.clients, fn {client_pid, _ref} ->
        if client_pid != sender_pid do
          PaintTogether.Client.send_frame(client_pid, frame)
        end
      end)
    end

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, client_pid, _reason}, state) do
    clients =
      case Map.get(state.clients, client_pid) do
        ^ref -> Map.delete(state.clients, client_pid)
        _ -> state.clients
      end

    {:noreply, %{state | clients: clients}}
  end

  def handle_info({:EXIT, acceptor, reason}, %{acceptor: acceptor} = state) do
    Logger.error("accept loop stopped: #{inspect(reason)}")
    {:stop, {:accept_loop_stopped, reason}, state}
  end

  @impl true
  def terminate(_reason, state) do
    :gen_tcp.close(state.listener)

    Enum.each(state.clients, fn {client_pid, _ref} ->
      Process.exit(client_pid, :shutdown)
    end)

    :ok
  end

  defp accept_loop(listener, server_pid) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        case PaintTogether.Client.start(socket, server_pid) do
          {:ok, client_pid} ->
            :ok = :gen_tcp.controlling_process(socket, client_pid)
            PaintTogether.Client.activate(client_pid)
            send(server_pid, {:client_connected, client_pid})

          {:error, reason} ->
            Logger.error("failed to start client: #{inspect(reason)}")
            :gen_tcp.close(socket)
        end

        accept_loop(listener, server_pid)

      {:error, :closed} ->
        :ok

      {:error, reason} ->
        Logger.error("accept failed: #{inspect(reason)}")
        Process.sleep(100)
        accept_loop(listener, server_pid)
    end
  end

  defp send_snapshot(client_pid, canvas) do
    canvas
    |> PaintTogether.Canvas.pixels()
    |> Enum.chunk_every(PaintTogether.max_batch())
    |> Enum.each(fn chunk ->
      PaintTogether.Client.send_frame(
        client_pid,
        PaintTogether.Protocol.encode_batch(0x02, chunk)
      )
    end)
  end
end
