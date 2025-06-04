defmodule Fekex.Repo do
  use Ecto.Repo,
    otp_app: :fekex,
    adapter: Ecto.Adapters.Postgres
end
