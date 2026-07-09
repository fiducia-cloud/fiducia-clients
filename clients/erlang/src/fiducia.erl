%% Fiducia HTTP client (Erlang). Zero third-party deps: httpc (inets) + json (OTP 27+).
%% Implements PROTOCOL.md. Requires OTP 27+.
%%
%% Start the HTTP stack once in your app, then create a client and call operations:
%%   application:ensure_all_started(inets),
%%   application:ensure_all_started(ssl),
%%   C = fiducia:new(<<"https://api.fiducia.cloud">>),
%%   {ok, Lock} = fiducia:lock_acquire(C, <<"orders/checkout">>, #{ttl_ms => 30000}),
%%   #{<<"result">> := #{<<"output">> := #{<<"fencing_token">> := Tok}}} = Lock,
%%   {ok, _} = fiducia:lock_release(C, <<"orders/checkout">>, <<"worker-a">>, Tok).
%%
%% Return convention: {ok, Decoded} on HTTP status < 300 and {error, {Status, Body}}
%% on status >= 300. Decoded/Body are the JSON payload parsed to maps with binary
%% keys (empty body -> the atom null). Transport failures surface as {error, Reason}
%% straight from httpc. String arguments should be binaries; pass optional fields in
%% the trailing Opts map with atom keys, e.g. #{holder => <<"w">>, ttl_ms => 30000}.
%% Only opts the caller supplies are sent (nulls omitted) so CAS semantics hold.
-module(fiducia).
-moduledoc """
Thin, dependency-light HTTP client for the fiducia.cloud coordination API.

Uses only the standard library: `httpc` (inets) for transport and `json`
(OTP 27+) for encoding. Every operation takes the client map returned by
`new/1` as its first argument and returns `{ok, Decoded} | {error, {Status, Body}}`.
""".

-export([new/1]).
%% misc
-export([health/1, status/1]).
%% locks
-export([lock_get/2,
         lock_acquire/2, lock_acquire/3,
         lock_acquire_many/2, lock_acquire_many/3,
         try_lock/2, try_lock/3,
         must_lock/2, must_lock/3,
         lock/2, lock/3,
         lock_release/4]).
%% semaphores
-export([semaphore_get/2,
         semaphore_acquire/3, semaphore_acquire/4,
         try_semaphore/3, try_semaphore/4,
         must_semaphore/3, must_semaphore/4,
         semaphore/3, semaphore/4,
         semaphore_release/4]).
%% idempotency
-export([idempotency_get/2,
         idempotency_claim/2, idempotency_claim/3,
         idempotency_complete/4, idempotency_complete/5]).
%% reader-writer locks
-export([rw_acquire_read/2, rw_acquire_read/3,
         rw_end_read/3,
         rw_acquire_write/2, rw_acquire_write/3,
         rw_end_write/3]).
%% config KV
-export([kv_get/2,
         kv_put/3, kv_put/4,
         kv_delete/2,
         kv_list/2]).
%% rate limiting
-export([rate_limit_get/3,
         rate_limit_check/6, rate_limit_check/7]).
%% cron & scheduling
-export([schedule_get/2,
         schedule_upsert/3, schedule_upsert/4,
         schedule_record_run/3, schedule_record_run/4,
         schedule_history/2]).
%% leader election
-export([election_get/2,
         election_campaign/4, election_campaign/5,
         election_renew/4,
         election_resign/4]).
%% service discovery
-export([service_instances/2,
         service_register/5, service_register/6,
         service_heartbeat/3, service_heartbeat/4,
         service_deregister/3,
         service_list/1]).

-export_type([client/0, result/0]).

-type client() :: #{base := binary()}.
-type result() :: {ok, term()} | {error, {non_neg_integer(), term()} | term()}.

%% @doc Build a client from a base URL. Trailing slashes are trimmed.
-spec new(binary() | string()) -> client().
new(BaseUrl) ->
    #{base => re:replace(to_bin(BaseUrl), <<"/+$">>, <<>>, [{return, binary}])}.

%% --- misc ---
-spec health(client()) -> result().
health(C) -> request(C, get, <<"/healthz">>).

-spec status(client()) -> result().
status(C) -> request(C, get, <<"/v1/status">>).

%% --- locks ---
-spec lock_get(client(), binary() | string()) -> result().
lock_get(C, Key) ->
    request(C, get, <<"/v1/locks?key=", (enc(Key))/binary>>).

-spec lock_acquire(client(), binary() | string()) -> result().
lock_acquire(C, Key) -> lock_acquire(C, Key, #{}).

-spec lock_acquire(client(), binary() | string(), map()) -> result().
lock_acquire(C, Key, Opts) ->
    Body = with_opts(#{key => to_bin(Key), wait => maps:get(wait, Opts, true)},
                     Opts, [holder, ttl_ms]),
    request(C, post, <<"/v1/locks/acquire">>, Body).

-spec lock_acquire_many(client(), [binary() | string()]) -> result().
lock_acquire_many(C, Keys) -> lock_acquire_many(C, Keys, #{}).

-spec lock_acquire_many(client(), [binary() | string()], map()) -> result().
lock_acquire_many(C, Keys, Opts) ->
    Body = with_opts(#{keys => [to_bin(K) || K <- Keys], wait => maps:get(wait, Opts, true)},
                     Opts, [holder, ttl_ms]),
    request(C, post, <<"/v1/locks/acquire">>, Body).

-spec try_lock(client(), binary() | string()) -> result().
try_lock(C, Key) -> try_lock(C, Key, #{}).

-spec try_lock(client(), binary() | string(), map()) -> result().
try_lock(C, Key, Opts) -> lock_acquire(C, Key, Opts#{wait => false}).

-spec must_lock(client(), binary() | string()) -> result().
must_lock(C, Key) -> must_lock(C, Key, #{}).

-spec must_lock(client(), binary() | string(), map()) -> result().
must_lock(C, Key, Opts) -> lock_acquire(C, Key, Opts#{wait => true}).

%% @doc Alias for must_lock/2.
-spec lock(client(), binary() | string()) -> result().
lock(C, Key) -> must_lock(C, Key).

%% @doc Alias for must_lock/3.
-spec lock(client(), binary() | string(), map()) -> result().
lock(C, Key, Opts) -> must_lock(C, Key, Opts).

%% @doc Key is accepted for symmetry but is not sent in the body.
-spec lock_release(client(), binary() | string(), binary() | string(), term()) -> result().
lock_release(C, _Key, Holder, FencingToken) ->
    request(C, post, <<"/v1/locks/release">>,
            #{holder => to_bin(Holder), fencing_token => FencingToken}).

%% --- semaphores ---
-spec semaphore_get(client(), binary() | string()) -> result().
semaphore_get(C, Key) ->
    request(C, get, <<"/v1/semaphores?key=", (enc(Key))/binary>>).

-spec semaphore_acquire(client(), binary() | string(), integer()) -> result().
semaphore_acquire(C, Key, Limit) -> semaphore_acquire(C, Key, Limit, #{}).

-spec semaphore_acquire(client(), binary() | string(), integer(), map()) -> result().
semaphore_acquire(C, Key, Limit, Opts) ->
    Body = with_opts(#{key => to_bin(Key), limit => Limit, wait => maps:get(wait, Opts, true)},
                     Opts, [holder, ttl_ms]),
    request(C, post, <<"/v1/semaphores/acquire">>, Body).

-spec try_semaphore(client(), binary() | string(), integer()) -> result().
try_semaphore(C, Key, Limit) -> try_semaphore(C, Key, Limit, #{}).

-spec try_semaphore(client(), binary() | string(), integer(), map()) -> result().
try_semaphore(C, Key, Limit, Opts) -> semaphore_acquire(C, Key, Limit, Opts#{wait => false}).

-spec must_semaphore(client(), binary() | string(), integer()) -> result().
must_semaphore(C, Key, Limit) -> must_semaphore(C, Key, Limit, #{}).

-spec must_semaphore(client(), binary() | string(), integer(), map()) -> result().
must_semaphore(C, Key, Limit, Opts) -> semaphore_acquire(C, Key, Limit, Opts#{wait => true}).

%% @doc Alias for must_semaphore/3.
-spec semaphore(client(), binary() | string(), integer()) -> result().
semaphore(C, Key, Limit) -> must_semaphore(C, Key, Limit).

%% @doc Alias for must_semaphore/4.
-spec semaphore(client(), binary() | string(), integer(), map()) -> result().
semaphore(C, Key, Limit, Opts) -> must_semaphore(C, Key, Limit, Opts).

-spec semaphore_release(client(), binary() | string(), binary() | string(), term()) -> result().
semaphore_release(C, Key, Holder, FencingToken) ->
    request(C, post, <<"/v1/semaphores/release">>,
            #{key => to_bin(Key), holder => to_bin(Holder), fencing_token => FencingToken}).

%% --- idempotency ---
-spec idempotency_get(client(), binary() | string()) -> result().
idempotency_get(C, Key) ->
    request(C, get, <<"/v1/idempotency?key=", (enc(Key))/binary>>).

-spec idempotency_claim(client(), binary() | string()) -> result().
idempotency_claim(C, Key) -> idempotency_claim(C, Key, #{}).

-spec idempotency_claim(client(), binary() | string(), map()) -> result().
idempotency_claim(C, Key, Opts) ->
    Body = with_opts(#{key => to_bin(Key)}, Opts, [owner, ttl_ms, ttl, metadata]),
    request(C, post, <<"/v1/idempotency/claim">>, Body).

-spec idempotency_complete(client(), binary() | string(), binary() | string(), term()) -> result().
idempotency_complete(C, Key, Owner, FencingToken) ->
    idempotency_complete(C, Key, Owner, FencingToken, #{}).

-spec idempotency_complete(client(), binary() | string(), binary() | string(), term(), map()) -> result().
idempotency_complete(C, Key, Owner, FencingToken, Opts) ->
    Body = with_opts(#{key => to_bin(Key), owner => to_bin(Owner), fencing_token => FencingToken},
                     Opts, [result]),
    request(C, post, <<"/v1/idempotency/complete">>, Body).

%% --- reader-writer locks ---
-spec rw_acquire_read(client(), binary() | string()) -> result().
rw_acquire_read(C, Key) -> rw_acquire_read(C, Key, #{}).

-spec rw_acquire_read(client(), binary() | string(), map()) -> result().
rw_acquire_read(C, Key, Opts) ->
    Body = with_opts(#{wait => maps:get(wait, Opts, true)}, Opts, [ttl_ms]),
    request(C, post, <<"/v1/rw/", (enc(Key))/binary, "/read">>, Body).

-spec rw_end_read(client(), binary() | string(), term()) -> result().
rw_end_read(C, Key, LockId) ->
    request(C, post, <<"/v1/rw/", (enc(Key))/binary, "/read/end">>,
            #{lock_id => to_bin(LockId)}).

-spec rw_acquire_write(client(), binary() | string()) -> result().
rw_acquire_write(C, Key) -> rw_acquire_write(C, Key, #{}).

-spec rw_acquire_write(client(), binary() | string(), map()) -> result().
rw_acquire_write(C, Key, Opts) ->
    Body = with_opts(#{wait => maps:get(wait, Opts, true)}, Opts, [ttl_ms]),
    request(C, post, <<"/v1/rw/", (enc(Key))/binary, "/write">>, Body).

-spec rw_end_write(client(), binary() | string(), term()) -> result().
rw_end_write(C, Key, LockId) ->
    request(C, post, <<"/v1/rw/", (enc(Key))/binary, "/write/end">>,
            #{lock_id => to_bin(LockId)}).

%% --- config KV ---
-spec kv_get(client(), binary() | string()) -> result().
kv_get(C, Key) ->
    request(C, get, <<"/v1/kv?key=", (enc(Key))/binary>>).

-spec kv_put(client(), binary() | string(), term()) -> result().
kv_put(C, Key, Value) -> kv_put(C, Key, Value, #{}).

%% @doc Value is sent as-is; pass a binary for a JSON string or a map/list for a
%% structured value.
-spec kv_put(client(), binary() | string(), term(), map()) -> result().
kv_put(C, Key, Value, Opts) ->
    Body = with_opts(#{value => Value}, Opts, [ttl_ms, prev_revision]),
    request(C, put, <<"/v1/kv?key=", (enc(Key))/binary>>, Body).

-spec kv_delete(client(), binary() | string()) -> result().
kv_delete(C, Key) ->
    request(C, delete, <<"/v1/kv?key=", (enc(Key))/binary>>).

-spec kv_list(client(), binary() | string()) -> result().
kv_list(C, Prefix) ->
    request(C, get, <<"/v1/kv?prefix=", (enc(Prefix))/binary>>).

%% --- rate limiting ---
-spec rate_limit_get(client(), binary() | string(), binary() | string()) -> result().
rate_limit_get(C, Tenant, Key) ->
    request(C, get, <<"/v1/rate-limit/", (enc(Tenant))/binary, "/", (enc(Key))/binary>>).

-spec rate_limit_check(client(), binary() | string(), binary() | string(),
                       binary() | string(), integer(), integer()) -> result().
rate_limit_check(C, Tenant, Key, Algorithm, Limit, WindowMs) ->
    rate_limit_check(C, Tenant, Key, Algorithm, Limit, WindowMs, #{}).

-spec rate_limit_check(client(), binary() | string(), binary() | string(),
                       binary() | string(), integer(), integer(), map()) -> result().
rate_limit_check(C, Tenant, Key, Algorithm, Limit, WindowMs, Opts) ->
    Body = with_opts(#{algorithm => to_bin(Algorithm), limit => Limit, window_ms => WindowMs},
                     Opts, [refill_per_second, cost]),
    request(C, post,
            <<"/v1/rate-limit/", (enc(Tenant))/binary, "/", (enc(Key))/binary, "/check">>,
            Body).

%% --- cron & scheduling ---
-spec schedule_get(client(), binary() | string()) -> result().
schedule_get(C, Name) ->
    request(C, get, <<"/v1/cron/schedules/", (enc(Name))/binary>>).

-spec schedule_upsert(client(), binary() | string(), term()) -> result().
schedule_upsert(C, Name, Target) -> schedule_upsert(C, Name, Target, #{}).

%% @doc Target is an arbitrary JSON object, e.g. #{kind => <<"webhook">>, url => <<"...">>}.
-spec schedule_upsert(client(), binary() | string(), term(), map()) -> result().
schedule_upsert(C, Name, Target, Opts) ->
    Body = with_opts(#{target => Target}, Opts, [cron, one_shot_at_ms, delivery, max_retries]),
    request(C, put, <<"/v1/cron/schedules/", (enc(Name))/binary>>, Body).

-spec schedule_record_run(client(), binary() | string(), binary() | string()) -> result().
schedule_record_run(C, Name, FireId) -> schedule_record_run(C, Name, FireId, #{}).

-spec schedule_record_run(client(), binary() | string(), binary() | string(), map()) -> result().
schedule_record_run(C, Name, FireId, Opts) ->
    Body = with_opts(#{fire_id => to_bin(FireId)}, Opts, [fired_at_ms]),
    request(C, post, <<"/v1/cron/schedules/", (enc(Name))/binary, "/runs">>, Body).

-spec schedule_history(client(), binary() | string()) -> result().
schedule_history(C, Name) ->
    request(C, get, <<"/v1/cron/schedules/", (enc(Name))/binary, "/history">>).

%% --- leader election ---
-spec election_get(client(), binary() | string()) -> result().
election_get(C, Name) ->
    request(C, get, <<"/v1/elections/", (enc(Name))/binary>>).

-spec election_campaign(client(), binary() | string(), binary() | string(), integer()) -> result().
election_campaign(C, Name, Candidate, TtlMs) ->
    election_campaign(C, Name, Candidate, TtlMs, #{}).

-spec election_campaign(client(), binary() | string(), binary() | string(), integer(), map()) -> result().
election_campaign(C, Name, Candidate, TtlMs, Opts) ->
    Body = with_opts(#{candidate => to_bin(Candidate), ttl_ms => TtlMs}, Opts, [metadata]),
    request(C, post, <<"/v1/elections/", (enc(Name))/binary, "/campaign">>, Body).

-spec election_renew(client(), binary() | string(), binary() | string(), term()) -> result().
election_renew(C, Name, Candidate, FencingToken) ->
    request(C, post, <<"/v1/elections/", (enc(Name))/binary, "/renew">>,
            #{candidate => to_bin(Candidate), fencing_token => FencingToken}).

-spec election_resign(client(), binary() | string(), binary() | string(), term()) -> result().
election_resign(C, Name, Candidate, FencingToken) ->
    request(C, post, <<"/v1/elections/", (enc(Name))/binary, "/resign">>,
            #{candidate => to_bin(Candidate), fencing_token => FencingToken}).

%% --- service discovery ---
-spec service_instances(client(), binary() | string()) -> result().
service_instances(C, Service) ->
    request(C, get, <<"/v1/services/", (enc(Service))/binary>>).

-spec service_register(client(), binary() | string(), binary() | string(),
                       binary() | string(), integer()) -> result().
service_register(C, Service, InstanceId, Address, TtlMs) ->
    service_register(C, Service, InstanceId, Address, TtlMs, #{}).

-spec service_register(client(), binary() | string(), binary() | string(),
                       binary() | string(), integer(), map()) -> result().
service_register(C, Service, InstanceId, Address, TtlMs, Opts) ->
    Body = with_opts(#{address => to_bin(Address), ttl_ms => TtlMs}, Opts, [metadata]),
    request(C, put,
            <<"/v1/services/", (enc(Service))/binary, "/instances/", (enc(InstanceId))/binary>>,
            Body).

-spec service_heartbeat(client(), binary() | string(), binary() | string()) -> result().
service_heartbeat(C, Service, InstanceId) -> service_heartbeat(C, Service, InstanceId, #{}).

-spec service_heartbeat(client(), binary() | string(), binary() | string(), map()) -> result().
service_heartbeat(C, Service, InstanceId, Opts) ->
    Body = with_opts(#{}, Opts, [ttl_ms]),
    request(C, post,
            <<"/v1/services/", (enc(Service))/binary, "/instances/", (enc(InstanceId))/binary,
              "/heartbeat">>,
            Body).

-spec service_deregister(client(), binary() | string(), binary() | string()) -> result().
service_deregister(C, Service, InstanceId) ->
    request(C, delete,
            <<"/v1/services/", (enc(Service))/binary, "/instances/", (enc(InstanceId))/binary>>).

-spec service_list(client()) -> result().
service_list(C) ->
    request(C, get, <<"/v1/services">>).

%% --- internals ---

%% Add each key from Opts into Body when the caller supplied it (nulls omitted).
with_opts(Body, Opts, Keys) ->
    lists:foldl(
      fun(K, Acc) ->
              case maps:find(K, Opts) of
                  {ok, V} -> Acc#{K => V};
                  error -> Acc
              end
      end, Body, Keys).

%% Percent-encode a value for use in a path segment or query value.
enc(X) -> uri_string:quote(to_bin(X)).

to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> unicode:characters_to_binary(L);
to_bin(A) when is_atom(A) -> atom_to_binary(A, utf8);
to_bin(I) when is_integer(I) -> integer_to_binary(I);
to_bin(F) when is_float(F) -> float_to_binary(F, [short]).

request(C, Method, Path) -> request(C, Method, Path, undefined).

request(#{base := Base}, Method, Path, Body) ->
    Url = unicode:characters_to_list(<<Base/binary, Path/binary>>),
    Request =
        case Body of
            undefined -> {Url, []};
            _ -> {Url, [], "application/json", iolist_to_binary(json:encode(Body))}
        end,
    case httpc:request(Method, Request, [], [{body_format, binary}]) of
        {ok, {{_Version, Status, _Reason}, _Headers, RespBody}} ->
            Data = decode_body(RespBody),
            case Status >= 300 of
                true -> {error, {Status, Data}};
                false -> {ok, Data}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

decode_body(<<>>) -> null;
decode_body(Body) when is_binary(Body) ->
    %% Fall back to the raw bytes when the body is not valid JSON (e.g. a proxy
    %% error page or plain-text error) so a non-JSON response never crashes.
    try json:decode(Body)
    catch _:_ -> Body
    end.
