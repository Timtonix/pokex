defmodule Poker.DnsServer do
  use GenServer
  require Logger

  # Répond à toutes les requêtes DNS avec l'IP du Pi
  @ip {192, 168, 4, 1}

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    case :gen_udp.open(53, [:binary, active: true, reuseaddr: true]) do
      {:ok, socket} ->
        Logger.info("DNS server listening on port 53")
        {:ok, socket}

      {:error, reason} ->
        Logger.warning("DNS server failed to bind port 53: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_info({:udp, socket, ip, port, packet}, socket) do
    case build_response(packet) do
      {:ok, response} -> :gen_udp.send(socket, ip, port, response)
      :error -> :ok
    end

    {:noreply, socket}
  end

  def handle_info(_, state), do: {:noreply, state}

  # On ne traite que les queries avec exactement 1 question (cas standard)
  defp build_response(<<id::16, _flags::16, 1::16, _::48, rest::binary>>) do
    {question_bin, _} = extract_question(rest)
    {a, b, c, d} = @ip

    # Flags: QR=1 réponse, AA=1 autoritaire, RD=1, RA=1, RCODE=0
    # 0xC00C = pointeur de compression vers l'offset 12 (début du nom dans la question)
    answer = <<
      0xC0,
      0x0C,
      0x00,
      0x01,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      0x3C,
      0x00,
      0x04,
      a,
      b,
      c,
      d
    >>

    header = <<id::16, 0x8580::16, 1::16, 1::16, 0::32>>
    {:ok, header <> question_bin <> answer}
  end

  defp build_response(_), do: :error

  defp extract_question(data) do
    {name_bin, rest} = read_labels(data, <<>>)
    <<qtype::16, qclass::16, rest2::binary>> = rest
    {name_bin <> <<qtype::16, qclass::16>>, rest2}
  end

  # Labels DNS : chaque segment est précédé de sa longueur, terminé par 0x00
  defp read_labels(<<0, rest::binary>>, acc), do: {acc <> <<0>>, rest}

  defp read_labels(<<len, rest::binary>>, acc) when len in 1..63 do
    <<label::binary-size(len), rest2::binary>> = rest
    read_labels(rest2, acc <> <<len>> <> label)
  end
end
