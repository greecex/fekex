defmodule Fekex.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      FekexWeb.Telemetry,
      Fekex.Repo,
      {DNSCluster, query: Application.get_env(:fekex, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Fekex.PubSub},
      # Start the Finch HTTP client for sending emails
      {Finch, name: Fekex.Finch},
      # Start a worker by calling: Fekex.Worker.start_link(arg)
      # {Fekex.Worker, arg},
      # Start to serve requests, typically the last entry
      FekexWeb.Endpoint
    ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Fekex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FekexWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
