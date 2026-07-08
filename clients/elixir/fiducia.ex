# Fiducia HTTP client (Elixir). Stdlib only: :httpc (inets) + :json (OTP 27+).
# Implements PROTOCOL.md.
#
#   Application.ensure_all_started(:inets)
#   Application.ensure_all_started(:ssl)
#   c = Fiducia.Client.new("https://api.fiducia.cloud")
#   {:ok, lock} = Fiducia.Client.lock_acquire(c, "orders/checkout", ttl_ms: 30_000)
#   Fiducia.Client.lock_release(c, "orders/checkout", "worker-a", lock["result"]["output"]["fencing_token"])

defmodule Fiducia.Client do
  defstruct base: nil, request_timeout_ms: nil, lock_request_timeout_ms: nil, retry_max: 0, retry_delay_ms: 0

  def new(base_url, opts \\ []) do
    %__MODULE__{
      base: String.trim_trailing(base_url, "/"),
      request_timeout_ms: opts[:request_timeout_ms],
      lock_request_timeout_ms: opts[:lock_request_timeout_ms],
      retry_max: Keyword.get(opts, :retry_max, 0),
      retry_delay_ms: Keyword.get(opts, :retry_delay_ms, 0)
    }
  end

  # --- misc ---
  def health(c), do: request(c, :get, "/healthz")
  def status(c), do: request(c, :get, "/v1/status")

  # --- locks & semaphores ---
  def lock_acquire(c, key, opts \\ []) do
    body = %{key: key, ttl_ms: opts[:ttl_ms], wait: Keyword.get(opts, :wait, true), max: Keyword.get(opts, :max, 1)}
    request(c, :post, "/v1/locks/acquire", body, Keyword.put(opts, :lock_acquire, true))
  end

  def try_lock(c, key, opts \\ []), do: lock_acquire(c, key, Keyword.put(opts, :wait, false))
  def must_lock(c, key, opts \\ []), do: lock_acquire(c, key, Keyword.put(opts, :wait, true))
  def lock(c, key, opts \\ []), do: must_lock(c, key, opts)

  def lock_release(c, _key, holder, fencing_token),
    do: request(c, :post, "/v1/locks/release", %{holder: holder, fencing_token: fencing_token})

  def semaphore_acquire(c, key, opts \\ []) do
    body = %{key: key, ttl_ms: opts[:ttl_ms], wait: Keyword.get(opts, :wait, true), limit: max(Keyword.get(opts, :max, 2), 2)}
    request(c, :post, "/v1/semaphores/acquire", body, Keyword.put(opts, :lock_acquire, true))
  end

  def try_semaphore(c, key, opts \\ []), do: semaphore_acquire(c, key, Keyword.put(opts, :wait, false))
  def must_semaphore(c, key, opts \\ []), do: semaphore_acquire(c, key, Keyword.put(opts, :wait, true))
  def semaphore(c, key, opts \\ []), do: must_semaphore(c, key, opts)

  def semaphore_release(c, key, holder, fencing_token),
    do: request(c, :post, "/v1/semaphores/release", %{key: key, holder: holder, fencing_token: fencing_token})

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
  def kv_get(c, key), do: request(c, :get, "/v1/kv?key=#{enc(key)}")
  def kv_put(c, key, value, opts \\ []),
    do: request(c, :put, "/v1/kv?key=#{enc(key)}", %{value: value, ttl_ms: opts[:ttl_ms]})

  def kv_delete(c, key), do: request(c, :delete, "/v1/kv?key=#{enc(key)}")
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
  defp do_acquire_lock(c, keys, wait, opts) do
    holder = opts[:holder] || gen_holder()
    ttl_ms = opts[:ttl_ms] || 60_000

    case lock_acquire(c, keys, holder: holder, ttl_ms: ttl_ms, wait: wait) do
      {:ok, resp} ->
        out = output(resp)

        cond do
          out["acquired"] == true ->
            {:ok, lock_map(c, keys, holder, out)}

          not wait ->
            {:ok, nil}

          true ->
            deadline = now_ms() + Keyword.get(opts, :max_wait_ms, 30_000)
            interval = Keyword.get(opts, :retry_interval_ms, 250)
            poll_lock(c, keys, holder, deadline, interval, Keyword.get(opts, :max_retries), 0)
        end

      err ->
        err
    end
  end

  defp poll_lock(_c, _keys, _holder, _deadline, _interval, max_retries, attempt)
       when is_integer(max_retries) and attempt >= max_retries,
       do: {:error, :timeout}

  defp poll_lock(c, keys, holder, deadline, interval, max_retries, attempt) do
    remaining = deadline - now_ms()

    if remaining <= 0 do
      {:error, :timeout}
    else
      Process.sleep(min(interval, remaining))

      case lock_get(c, hd(keys)) do
        {:ok, %{"lock" => lk}} when is_map(lk) ->
          if lk["holder"] == holder and lk["fencing_token"] != nil do
            {:ok,
             %{client: c, keys: keys, holder: holder, fencing_token: lk["fencing_token"], lease_expires_ms: lk["lease_expires_ms"]}}
          else
            poll_lock(c, keys, holder, deadline, interval, max_retries, attempt + 1)
          end

        {:ok, _} ->
          poll_lock(c, keys, holder, deadline, interval, max_retries, attempt + 1)

        err ->
          err
      end
    end
  end

  defp do_acquire_semaphore(c, key, limit, wait, opts) do
    holder = opts[:holder] || gen_holder()
    ttl_ms = opts[:ttl_ms] || 60_000

    case semaphore_acquire(c, key, limit, holder: holder, ttl_ms: ttl_ms, wait: wait) do
      {:ok, resp} ->
        out = output(resp)

        cond do
          out["acquired"] == true ->
            {:ok, %{client: c, key: key, holder: holder, fencing_token: out["fencing_token"], lease_expires_ms: out["lease_expires_ms"]}}

          not wait ->
            {:ok, nil}

          true ->
            deadline = now_ms() + Keyword.get(opts, :max_wait_ms, 30_000)
            interval = Keyword.get(opts, :retry_interval_ms, 250)
            poll_semaphore(c, key, holder, deadline, interval, Keyword.get(opts, :max_retries), 0)
        end

      err ->
        err
    end
  end

  defp poll_semaphore(_c, _key, _holder, _deadline, _interval, max_retries, attempt)
       when is_integer(max_retries) and attempt >= max_retries,
       do: {:error, :timeout}

  defp poll_semaphore(c, key, holder, deadline, interval, max_retries, attempt) do
    remaining = deadline - now_ms()

    if remaining <= 0 do
      {:error, :timeout}
    else
      Process.sleep(min(interval, remaining))

      case semaphore_get(c, key) do
        {:ok, %{"semaphore" => %{"holders" => holders}}} when is_list(holders) ->
          case Enum.find(holders, fn h -> h["holder"] == holder and h["fencing_token"] != nil end) do
            nil ->
              poll_semaphore(c, key, holder, deadline, interval, max_retries, attempt + 1)

            slot ->
              {:ok, %{client: c, key: key, holder: holder, fencing_token: slot["fencing_token"], lease_expires_ms: slot["lease_expires_ms"]}}
          end

        {:ok, _} ->
          poll_semaphore(c, key, holder, deadline, interval, max_retries, attempt + 1)

        err ->
          err
      end
    end
  end

  defp lock_map(c, keys, holder, out),
    do: %{client: c, keys: keys, holder: holder, fencing_token: out["fencing_token"], lease_expires_ms: out["lease_expires_ms"]}

  defp output(resp) when is_map(resp), do: (resp["result"] || %{})["output"] || %{}
  defp output(_), do: %{}

  defp gen_holder, do: "fdc-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  defp now_ms, do: System.monotonic_time(:millisecond)

  defp enc(s), do: URI.encode_www_form(to_string(s))

  defp request(c, method, path, body \\ nil, opts \\ []) do
    do_request(c, method, path, body, opts, 0, resolve_retries(c, opts))
  end

  defp do_request(c, method, path, body, opts, attempt, max_retries) do
    case request_once(c, method, path, body, opts) do
      {:ok, data} ->
        {:ok, data}

      {:error, reason} = err ->
        if attempt < max_retries and retryable?(reason) do
          delay = resolve_retry_delay_ms(c, opts)
          if delay > 0, do: :timer.sleep(delay)
          do_request(c, method, path, body, opts, attempt + 1, max_retries)
        else
          err
        end
    end
  end

  defp request_once(c, method, path, body, opts) do
    url = String.to_charlist(c.base <> path)

    http_request =
      if body do
        {url, [], ~c"application/json", :json.encode(body)}
      else
        {url, []}
      end

    http_opts =
      case resolve_timeout_ms(c, opts) do
        nil -> []
        timeout -> [timeout: timeout, connect_timeout: timeout]
      end

    case :httpc.request(method, http_request, http_opts, body_format: :binary) do
      {:ok, {{_v, status, _r}, _headers, resp_body}} ->
        data = if resp_body in ["", <<>>], do: nil, else: :json.decode(resp_body)
        if status >= 300, do: {:error, {status, data}}, else: {:ok, data}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_timeout_ms(c, opts) do
    opts[:lock_request_timeout_ms] ||
      opts[:request_timeout_ms] ||
      opts[:timeout_ms] ||
      if(opts[:lock_acquire], do: c.lock_request_timeout_ms, else: nil) ||
      c.request_timeout_ms
  end

  defp resolve_retries(c, opts),
    do: max(opts[:max_retries] || opts[:retry_max] || opts[:retries] || c.retry_max || 0, 0)

  defp resolve_retry_delay_ms(c, opts),
    do: max(opts[:retry_delay_ms] || c.retry_delay_ms || 0, 0)

  defp retryable?({status, _body}) when status in [408, 425, 429, 500, 502, 503, 504], do: true
  defp retryable?({_status, _body}), do: false
  defp retryable?(_reason), do: true
end
