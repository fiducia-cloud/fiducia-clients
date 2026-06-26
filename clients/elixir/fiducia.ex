# Fiducia HTTP client (Elixir). Stdlib only: :httpc (inets) + :json (OTP 27+).
# Implements PROTOCOL.md.
#
#   Application.ensure_all_started(:inets)
#   Application.ensure_all_started(:ssl)
#   c = Fiducia.Client.new("https://api.fiducia.cloud")
#   {:ok, lock} = Fiducia.Client.lock_acquire(c, "orders/checkout", ttl_ms: 30_000)
#   Fiducia.Client.lock_release(c, "orders/checkout", lock["result"]["lock_id"])

defmodule Fiducia.Client do
  defstruct base: nil

  def new(base_url), do: %__MODULE__{base: String.trim_trailing(base_url, "/")}

  # --- misc ---
  def health(c), do: request(c, :get, "/healthz")
  def status(c), do: request(c, :get, "/v1/status")

  # --- locks & semaphores ---
  def lock_acquire(c, key, opts \\ []) do
    body = %{ttl_ms: opts[:ttl_ms], wait: Keyword.get(opts, :wait, true), max: Keyword.get(opts, :max, 1)}
    request(c, :post, "/v1/locks/#{enc(key)}/acquire", body)
  end

  def lock_release(c, key, lock_id),
    do: request(c, :post, "/v1/locks/#{enc(key)}/release", %{lock_id: lock_id})

  # --- reader-writer locks ---
  def rw_acquire_read(c, key, opts \\ []),
    do: request(c, :post, "/v1/rw/#{enc(key)}/read", %{ttl_ms: opts[:ttl_ms], wait: Keyword.get(opts, :wait, true)})

  def rw_end_read(c, key, lock_id),
    do: request(c, :post, "/v1/rw/#{enc(key)}/read/end", %{lock_id: lock_id})

  def rw_acquire_write(c, key, opts \\ []),
    do: request(c, :post, "/v1/rw/#{enc(key)}/write", %{ttl_ms: opts[:ttl_ms], wait: Keyword.get(opts, :wait, true)})

  def rw_end_write(c, key, lock_id),
    do: request(c, :post, "/v1/rw/#{enc(key)}/write/end", %{lock_id: lock_id})

  # --- config KV ---
  def kv_get(c, key), do: request(c, :get, "/v1/kv/#{enc(key)}")
  def kv_put(c, key, value, opts \\ []),
    do: request(c, :put, "/v1/kv/#{enc(key)}", %{value: value, ttl_ms: opts[:ttl_ms]})

  def kv_delete(c, key), do: request(c, :delete, "/v1/kv/#{enc(key)}")
  def kv_list(c, prefix), do: request(c, :get, "/v1/kv?prefix=#{enc(prefix)}")

  # --- leader election ---
  def election_campaign(c, name, candidate, ttl_ms),
    do: request(c, :post, "/v1/elections/#{enc(name)}/campaign", %{candidate: candidate, ttl_ms: ttl_ms})

  def election_renew(c, name, candidate, fencing_token),
    do: request(c, :post, "/v1/elections/#{enc(name)}/renew", %{candidate: candidate, fencing_token: fencing_token})

  def election_resign(c, name, candidate, fencing_token),
    do: request(c, :post, "/v1/elections/#{enc(name)}/resign", %{candidate: candidate, fencing_token: fencing_token})

  def election_get(c, name), do: request(c, :get, "/v1/elections/#{enc(name)}")

  # --- service discovery ---
  def service_register(c, service, instance_id, address, ttl_ms),
    do: request(c, :put, "/v1/services/#{enc(service)}/instances/#{enc(instance_id)}", %{address: address, ttl_ms: ttl_ms})

  def service_heartbeat(c, service, instance_id),
    do: request(c, :post, "/v1/services/#{enc(service)}/instances/#{enc(instance_id)}/heartbeat")

  def service_deregister(c, service, instance_id),
    do: request(c, :delete, "/v1/services/#{enc(service)}/instances/#{enc(instance_id)}")

  def service_instances(c, service), do: request(c, :get, "/v1/services/#{enc(service)}")
  def service_list(c), do: request(c, :get, "/v1/services")

  # --- internals ---
  defp enc(s), do: URI.encode_www_form(to_string(s))

  defp request(c, method, path, body \\ nil) do
    url = String.to_charlist(c.base <> path)

    http_request =
      if body do
        {url, [], ~c"application/json", :json.encode(body)}
      else
        {url, []}
      end

    case :httpc.request(method, http_request, [], body_format: :binary) do
      {:ok, {{_v, status, _r}, _headers, resp_body}} ->
        data = if resp_body in ["", <<>>], do: nil, else: :json.decode(resp_body)
        if status >= 300, do: {:error, {status, data}}, else: {:ok, data}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
