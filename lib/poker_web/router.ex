defmodule PokerWeb.Router do
  use PokerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PokerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PokerWeb do
    pipe_through :browser

    get "/", PageController, :home

    live "/scan", ScanLive
    live "/table", TableLive


    # Vue table (lecture seule, tous les joueurs)

    # Interface Game Master (protégée par le scan du tag GM)
    live "/gm", GmLive

  end

  scope "/nfc", PokerWeb do
    pipe_through :browser

    get "/:tag_id", NfcController, :handle
  end


  # Other scopes may use custom stacks.
  # scope "/api", PokerWeb do
  #   pipe_through :api
  # end
end
