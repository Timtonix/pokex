defmodule PokerWeb.PageController do
  use PokerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
