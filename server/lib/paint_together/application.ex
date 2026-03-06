defmodule PaintTogether.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {PaintTogether.Server, port: PaintTogether.default_port()}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: PaintTogether.Supervisor)
  end
end
