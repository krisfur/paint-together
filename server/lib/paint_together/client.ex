defmodule PaintTogether.Client do
  use GenServer

  require Logger

  @spec start(:gen_tcp.socket(), pid()) :: GenServer.on_start()
  def start(socket, server) do
    GenServer.start(__MODULE__, {socket, server})
  end

  @spec activate(pid()) :: :ok
  def activate(pid) do
    GenServer.cast(pid, :activate)
  end

  @spec send_frame(pid(), binary()) :: :ok
  def send_frame(pid, frame) do
    GenServer.cast(pid, {:send_frame, frame})
  end

  @impl true
  def init({socket, server}) do
    {:ok, %{socket: socket, server: server, buffer: <<>>}}
  end

  @impl true
  def handle_cast(:activate, state) do
    :ok = :inet.setopts(state.socket, active: :once, nodelay: true)
    {:noreply, state}
  end

  def handle_cast({:send_frame, frame}, state) do
    case :gen_tcp.send(state.socket, frame) do
      :ok -> {:noreply, state}
      {:error, reason} -> {:stop, {:send_failed, reason}, state}
    end
  end

  @impl true
  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
    buffer = state.buffer <> data
    {frames, rest} = PaintTogether.Protocol.split_frames(buffer)

    Enum.each(frames, fn frame ->
      case PaintTogether.Protocol.decode_draw_batch(frame) do
        {:ok, pixels} -> send(state.server, {:client_batch, self(), pixels})
        :error -> :ok
      end
    end)

    :ok = :inet.setopts(socket, active: :once)
    {:noreply, %{state | buffer: rest}}
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state) do
    {:stop, {:tcp_error, reason}, state}
  end

  @impl true
  def terminate(reason, state) do
    case reason do
      :normal -> :ok
      {:tcp_error, _} -> :ok
      {:send_failed, _} -> :ok
      other -> Logger.warning("client stopped: #{inspect(other)}")
    end

    :gen_tcp.close(state.socket)
    :ok
  end
end
