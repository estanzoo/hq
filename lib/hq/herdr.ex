defmodule Hq.Herdr do
  @moduledoc """
  Client for the Herdr control socket.

  Herdr answers exactly one request per connection: a second request written to
  the same socket is never answered. Every call therefore opens its own
  connection, which on a unix domain socket costs microseconds and is not worth
  pooling around.
  """

  @default_timeout 30_000

  @spec call(String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def call(method, params \\ %{}, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case connect(timeout) do
      {:ok, sock} ->
        try do
          with :ok <- send_request(sock, method, params),
               {:ok, line} <- :gen_tcp.recv(sock, 0, timeout) do
            decode(line)
          else
            {:error, reason} -> {:error, reason}
          end
        after
          :gen_tcp.close(sock)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec connect(pos_integer()) :: {:ok, :gen_tcp.socket()} | {:error, term()}
  def connect(timeout \\ @default_timeout) do
    :gen_tcp.connect(
      {:local, socket_path()},
      0,
      # See Hq.Control's listen socket for why `buffer` is set: without it a
      # `packet: :line` frame past ~9216 bytes truncates, in either
      # direction — a large `agent.prompt` text out, or a large `agent.list`
      # result back. The real Herdr server accepts up to 60KB; this ceiling
      # was ours alone.
      [:binary, active: false, packet: :line, buffer: 1_000_000],
      timeout
    )
  end

  @spec send_request(:gen_tcp.socket(), String.t(), map()) :: :ok | {:error, term()}
  def send_request(sock, method, params) do
    # The id must be a string; an integer is rejected as invalid_request.
    payload = JSON.encode!(%{"id" => new_id(), "method" => method, "params" => params})
    :gen_tcp.send(sock, [payload, ?\n])
  end

  @spec socket_path() :: String.t()
  def socket_path do
    Application.get_env(:hq, :herdr_socket) || Path.expand("~/.config/herdr/herdr.sock")
  end

  defp decode(line) do
    case JSON.decode(line) do
      {:ok, %{"result" => result}} -> {:ok, result}
      {:ok, %{"error" => error}} -> {:error, error}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, reason} -> {:error, {:bad_json, reason}}
    end
  end

  defp new_id, do: Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
end
