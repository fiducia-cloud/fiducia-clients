-module(fiducia).
-compile([no_auto_import, nowarn_unused_vars, nowarn_unused_function, nowarn_nomatch, inline]).
-define(FILEPATH, "src/fiducia.gleam").
-export([new/1, health/1, status/1, lock_get/2, lock_acquire/5, lock_acquire_many/5, try_lock/4, must_lock/4, lock/4, lock_release/4, semaphore_get/2, semaphore_acquire/6, try_semaphore/5, must_semaphore/5, semaphore/5, semaphore_release/4, idempotency_get/2, idempotency_claim/6, idempotency_complete/5, rw_acquire_read/4, rw_end_read/3, rw_acquire_write/4, rw_end_write/3, kv_get/2, kv_put/5, kv_delete/2, kv_list/2, rate_limit_get/3, rate_limit_check/8, schedule_get/2, schedule_upsert/7, schedule_record_run/4, schedule_history/2, election_get/2, election_campaign/5, election_renew/4, election_resign/4, service_instances/2, service_register/6, service_heartbeat/4, service_deregister/3, service_list/1]).
-export_type([fiducia_error/0, client/0]).

-if(?OTP_RELEASE >= 27).
-define(MODULEDOC(Str), -moduledoc(Str)).
-define(DOC(Str), -doc(Str)).
-else.
-define(MODULEDOC(Str), -compile([])).
-define(DOC(Str), -compile([])).
-endif.

?MODULEDOC(
    " Fiducia HTTP client (Gleam). Transport: gleam_httpc; JSON: gleam_json; plus\n"
    " gleam_stdlib. Implements PROTOCOL.md.\n"
    "\n"
    "   import fiducia\n"
    "   import gleam/option.{None, Some}\n"
    "   let c = fiducia.new(\"https://api.fiducia.cloud\")\n"
    "   let assert Ok(lock) =\n"
    "     fiducia.lock_acquire(c, \"orders/checkout\", None, Some(30_000), True)\n"
    "   // `lock` is a Dynamic: pull result.output.fencing_token with a\n"
    "   // gleam/dynamic/decode decoder, then:\n"
    "   //   fiducia.lock_release(c, \"orders/checkout\", \"worker-a\", token)\n"
).

-type fiducia_error() :: {http, integer(), gleam@dynamic:dynamic_()} |
    {transport, binary()}.

-opaque client() :: {client, binary()}.

-file("src/fiducia.gleam", 687).
-spec drop_trailing_slashes(binary()) -> binary().
drop_trailing_slashes(Value) ->
    case gleam_stdlib:string_ends_with(Value, <<"/"/utf8>>) of
        true ->
            drop_trailing_slashes(gleam@string:drop_end(Value, 1));

        false ->
            Value
    end.

-file("src/fiducia.gleam", 40).
?DOC(
    " Create a client for `base_url`. Trailing slashes are trimmed so paths join\n"
    " cleanly. Every method returns `Result(Dynamic, FiduciaError)`; decode the\n"
    " `Dynamic` with `gleam/dynamic/decode` when you need typed fields.\n"
).
-spec new(binary()) -> client().
new(Base_url) ->
    {client, drop_trailing_slashes(Base_url)}.

-file("src/fiducia.gleam", 676).
-spec string_dynamic(binary()) -> gleam@dynamic:dynamic_().
string_dynamic(Raw) ->
    Value@1 = case gleam@json:parse(
        gleam@json:to_string(gleam@json:string(Raw)),
        {decoder, fun gleam@dynamic@decode:decode_dynamic/1}
    ) of
        {ok, Value} -> Value;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"fiducia"/utf8>>,
                        function => <<"string_dynamic"/utf8>>,
                        line => 677,
                        value => _assert_fail,
                        start => 18359,
                        'end' => 18446,
                        pattern_start => 18370,
                        pattern_end => 18379})
    end,
    Value@1.

-file("src/fiducia.gleam", 671).
-spec null_dynamic() -> gleam@dynamic:dynamic_().
null_dynamic() ->
    Value@1 = case gleam@json:parse(
        <<"null"/utf8>>,
        {decoder, fun gleam@dynamic@decode:decode_dynamic/1}
    ) of
        {ok, Value} -> Value;
        _assert_fail ->
            erlang:error(#{gleam_error => let_assert,
                        message => <<"Pattern match failed, no pattern matched the value."/utf8>>,
                        file => <<?FILEPATH/utf8>>,
                        module => <<"fiducia"/utf8>>,
                        function => <<"null_dynamic"/utf8>>,
                        line => 672,
                        value => _assert_fail,
                        start => 18244,
                        'end' => 18301,
                        pattern_start => 18255,
                        pattern_end => 18264})
    end,
    Value@1.

-file("src/fiducia.gleam", 660).
?DOC(
    " Parse a response body into a `Dynamic`. Empty body → JSON null; non-JSON is\n"
    " wrapped as a JSON string so callers always get a value.\n"
).
-spec decode_body(binary()) -> gleam@dynamic:dynamic_().
decode_body(Body) ->
    case gleam@string:trim(Body) of
        <<""/utf8>> ->
            null_dynamic();

        _ ->
            case gleam@json:parse(
                Body,
                {decoder, fun gleam@dynamic@decode:decode_dynamic/1}
            ) of
                {ok, Value} ->
                    Value;

                {error, _} ->
                    string_dynamic(Body)
            end
    end.

-file("src/fiducia.gleam", 645).
-spec apply_body(
    gleam@http@request:request(binary()),
    gleam@option:option(gleam@json:json())
) -> gleam@http@request:request(binary()).
apply_body(Req, Body) ->
    case Body of
        none ->
            Req;

        {some, Payload} ->
            _pipe = Req,
            _pipe@1 = gleam@http@request:set_header(
                _pipe,
                <<"content-type"/utf8>>,
                <<"application/json"/utf8>>
            ),
            gleam@http@request:set_body(_pipe@1, gleam@json:to_string(Payload))
    end.

-file("src/fiducia.gleam", 615).
-spec send(
    client(),
    gleam@http:method(),
    binary(),
    gleam@option:option(gleam@json:json())
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
send(Client, Method, Path, Body) ->
    Url = <<(erlang:element(2, Client))/binary, Path/binary>>,
    case gleam@http@request:to(Url) of
        {error, _} ->
            {error,
                {transport,
                    <<"fiducia: could not build request url: "/utf8,
                        Url/binary>>}};

        {ok, Base_request} ->
            Req = begin
                _pipe = Base_request,
                _pipe@1 = gleam@http@request:set_method(_pipe, Method),
                apply_body(_pipe@1, Body)
            end,
            case gleam@httpc:send(Req) of
                {error, Err} ->
                    {error,
                        {transport,
                            <<"fiducia: transport error: "/utf8,
                                (gleam@string:inspect(Err))/binary>>}};

                {ok, Response} ->
                    Parsed = decode_body(erlang:element(4, Response)),
                    case erlang:element(2, Response) >= 300 of
                        true ->
                            {error, {http, erlang:element(2, Response), Parsed}};

                        false ->
                            {ok, Parsed}
                    end
            end
    end.

-file("src/fiducia.gleam", 47).
?DOC(" `GET /healthz` — liveness probe.\n").
-spec health(client()) -> {ok, gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
health(Client) ->
    send(Client, get, <<"/healthz"/utf8>>, none).

-file("src/fiducia.gleam", 52).
?DOC(" `GET /v1/status` — per-shard consensus status.\n").
-spec status(client()) -> {ok, gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
status(Client) ->
    send(Client, get, <<"/v1/status"/utf8>>, none).

-file("src/fiducia.gleam", 683).
?DOC(" Percent-encode a path segment or query value.\n").
-spec enc(binary()) -> binary().
enc(Value) ->
    gleam_stdlib:percent_encode(Value).

-file("src/fiducia.gleam", 59).
?DOC(" `GET /v1/locks?key=…` — inspect a lock member key.\n").
-spec lock_get(client(), binary()) -> {ok, gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
lock_get(Client, Key) ->
    send(Client, get, <<"/v1/locks?key="/utf8, (enc(Key))/binary>>, none).

-file("src/fiducia.gleam", 694).
-spec opt(binary(), gleam@option:option(gleam@json:json())) -> list({binary(),
    gleam@json:json()}).
opt(Name, Value) ->
    case Value of
        {some, Payload} ->
            [{Name, Payload}];

        none ->
            []
    end.

-file("src/fiducia.gleam", 705).
-spec opt_int(binary(), gleam@option:option(integer())) -> list({binary(),
    gleam@json:json()}).
opt_int(Name, Value) ->
    opt(Name, gleam@option:map(Value, fun gleam@json:int/1)).

-file("src/fiducia.gleam", 701).
-spec opt_string(binary(), gleam@option:option(binary())) -> list({binary(),
    gleam@json:json()}).
opt_string(Name, Value) ->
    opt(Name, gleam@option:map(Value, fun gleam@json:string/1)).

-file("src/fiducia.gleam", 64).
?DOC(" `POST /v1/locks/acquire` — acquire a single-key lock (try-lock unless `wait`).\n").
-spec lock_acquire(
    client(),
    binary(),
    gleam@option:option(binary()),
    gleam@option:option(integer()),
    boolean()
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
lock_acquire(Client, Key, Holder, Ttl_ms, Wait) ->
    Body = gleam@json:object(
        lists:append(
            [[{<<"key"/utf8>>, gleam@json:string(Key)}],
                opt_string(<<"holder"/utf8>>, Holder),
                opt_int(<<"ttl_ms"/utf8>>, Ttl_ms),
                [{<<"wait"/utf8>>, gleam@json:bool(Wait)}]]
        )
    ),
    send(Client, post, <<"/v1/locks/acquire"/utf8>>, {some, Body}).

-file("src/fiducia.gleam", 84).
?DOC(" `POST /v1/locks/acquire` — multi-key UNION lock (all-or-nothing across `keys`).\n").
-spec lock_acquire_many(
    client(),
    list(binary()),
    gleam@option:option(binary()),
    gleam@option:option(integer()),
    boolean()
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
lock_acquire_many(Client, Keys, Holder, Ttl_ms, Wait) ->
    Body = gleam@json:object(
        lists:append(
            [[{<<"keys"/utf8>>, gleam@json:array(Keys, fun gleam@json:string/1)}],
                opt_string(<<"holder"/utf8>>, Holder),
                opt_int(<<"ttl_ms"/utf8>>, Ttl_ms),
                [{<<"wait"/utf8>>, gleam@json:bool(Wait)}]]
        )
    ),
    send(Client, post, <<"/v1/locks/acquire"/utf8>>, {some, Body}).

-file("src/fiducia.gleam", 104).
?DOC(" `lock_acquire` with `wait=false`: take the lock now or fail fast.\n").
-spec try_lock(
    client(),
    binary(),
    gleam@option:option(binary()),
    gleam@option:option(integer())
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
try_lock(Client, Key, Holder, Ttl_ms) ->
    lock_acquire(Client, Key, Holder, Ttl_ms, false).

-file("src/fiducia.gleam", 114).
?DOC(" `lock_acquire` with `wait=true`: reserve a FIFO slot.\n").
-spec must_lock(
    client(),
    binary(),
    gleam@option:option(binary()),
    gleam@option:option(integer())
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
must_lock(Client, Key, Holder, Ttl_ms) ->
    lock_acquire(Client, Key, Holder, Ttl_ms, true).

-file("src/fiducia.gleam", 124).
?DOC(" Alias of `must_lock`.\n").
-spec lock(
    client(),
    binary(),
    gleam@option:option(binary()),
    gleam@option:option(integer())
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
lock(Client, Key, Holder, Ttl_ms) ->
    must_lock(Client, Key, Holder, Ttl_ms).

-file("src/fiducia.gleam", 135).
?DOC(
    " `POST /v1/locks/release` — release the whole grant by its fencing token.\n"
    " `key` is accepted for call-site symmetry but is not sent in the body.\n"
).
-spec lock_release(client(), binary(), binary(), integer()) -> {ok,
        gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
lock_release(Client, Key, Holder, Fencing_token) ->
    _ = Key,
    Body = gleam@json:object(
        [{<<"holder"/utf8>>, gleam@json:string(Holder)},
            {<<"fencing_token"/utf8>>, gleam@json:int(Fencing_token)}]
    ),
    send(Client, post, <<"/v1/locks/release"/utf8>>, {some, Body}).

-file("src/fiducia.gleam", 153).
?DOC(" `GET /v1/semaphores?key=…` — inspect a semaphore.\n").
-spec semaphore_get(client(), binary()) -> {ok, gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
semaphore_get(Client, Key) ->
    send(Client, get, <<"/v1/semaphores?key="/utf8, (enc(Key))/binary>>, none).

-file("src/fiducia.gleam", 161).
?DOC(" `POST /v1/semaphores/acquire` — take a permit (try unless `wait`).\n").
-spec semaphore_acquire(
    client(),
    binary(),
    integer(),
    gleam@option:option(binary()),
    gleam@option:option(integer()),
    boolean()
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
semaphore_acquire(Client, Key, Limit, Holder, Ttl_ms, Wait) ->
    Body = gleam@json:object(
        lists:append(
            [[{<<"key"/utf8>>, gleam@json:string(Key)}],
                opt_string(<<"holder"/utf8>>, Holder),
                opt_int(<<"ttl_ms"/utf8>>, Ttl_ms),
                [{<<"limit"/utf8>>, gleam@json:int(Limit)},
                    {<<"wait"/utf8>>, gleam@json:bool(Wait)}]]
        )
    ),
    send(Client, post, <<"/v1/semaphores/acquire"/utf8>>, {some, Body}).

-file("src/fiducia.gleam", 182).
?DOC(" `semaphore_acquire` with `wait=false`.\n").
-spec try_semaphore(
    client(),
    binary(),
    integer(),
    gleam@option:option(binary()),
    gleam@option:option(integer())
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
try_semaphore(Client, Key, Limit, Holder, Ttl_ms) ->
    semaphore_acquire(Client, Key, Limit, Holder, Ttl_ms, false).

-file("src/fiducia.gleam", 193).
?DOC(" `semaphore_acquire` with `wait=true`.\n").
-spec must_semaphore(
    client(),
    binary(),
    integer(),
    gleam@option:option(binary()),
    gleam@option:option(integer())
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
must_semaphore(Client, Key, Limit, Holder, Ttl_ms) ->
    semaphore_acquire(Client, Key, Limit, Holder, Ttl_ms, true).

-file("src/fiducia.gleam", 204).
?DOC(" Alias of `must_semaphore`.\n").
-spec semaphore(
    client(),
    binary(),
    integer(),
    gleam@option:option(binary()),
    gleam@option:option(integer())
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
semaphore(Client, Key, Limit, Holder, Ttl_ms) ->
    must_semaphore(Client, Key, Limit, Holder, Ttl_ms).

-file("src/fiducia.gleam", 215).
?DOC(" `POST /v1/semaphores/release` — return one permit.\n").
-spec semaphore_release(client(), binary(), binary(), integer()) -> {ok,
        gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
semaphore_release(Client, Key, Holder, Fencing_token) ->
    Body = gleam@json:object(
        [{<<"key"/utf8>>, gleam@json:string(Key)},
            {<<"holder"/utf8>>, gleam@json:string(Holder)},
            {<<"fencing_token"/utf8>>, gleam@json:int(Fencing_token)}]
    ),
    send(Client, post, <<"/v1/semaphores/release"/utf8>>, {some, Body}).

-file("src/fiducia.gleam", 233).
?DOC(" `GET /v1/idempotency?key=…` — inspect an active idempotency record.\n").
-spec idempotency_get(client(), binary()) -> {ok, gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
idempotency_get(Client, Key) ->
    send(Client, get, <<"/v1/idempotency?key="/utf8, (enc(Key))/binary>>, none).

-file("src/fiducia.gleam", 242).
?DOC(
    " `POST /v1/idempotency/claim` — claim a key; first claimant wins until TTL.\n"
    " `metadata` is arbitrary JSON.\n"
).
-spec idempotency_claim(
    client(),
    binary(),
    gleam@option:option(binary()),
    gleam@option:option(integer()),
    gleam@option:option(binary()),
    gleam@option:option(gleam@json:json())
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
idempotency_claim(Client, Key, Owner, Ttl_ms, Ttl, Metadata) ->
    Body = gleam@json:object(
        lists:append(
            [[{<<"key"/utf8>>, gleam@json:string(Key)}],
                opt_string(<<"owner"/utf8>>, Owner),
                opt_int(<<"ttl_ms"/utf8>>, Ttl_ms),
                opt_string(<<"ttl"/utf8>>, Ttl),
                opt(<<"metadata"/utf8>>, Metadata)]
        )
    ),
    send(Client, post, <<"/v1/idempotency/claim"/utf8>>, {some, Body}).

-file("src/fiducia.gleam", 265).
?DOC(
    " `POST /v1/idempotency/complete` — mark a claim complete; `result` is arbitrary\n"
    " JSON stored for replay.\n"
).
-spec idempotency_complete(
    client(),
    binary(),
    binary(),
    integer(),
    gleam@option:option(gleam@json:json())
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
idempotency_complete(Client, Key, Owner, Fencing_token, Result) ->
    Body = gleam@json:object(
        lists:append(
            [[{<<"key"/utf8>>, gleam@json:string(Key)},
                    {<<"owner"/utf8>>, gleam@json:string(Owner)},
                    {<<"fencing_token"/utf8>>, gleam@json:int(Fencing_token)}],
                opt(<<"result"/utf8>>, Result)]
        )
    ),
    send(Client, post, <<"/v1/idempotency/complete"/utf8>>, {some, Body}).

-file("src/fiducia.gleam", 289).
?DOC(" `POST /v1/rw/<key>/read` — acquire a shared read lock.\n").
-spec rw_acquire_read(
    client(),
    binary(),
    gleam@option:option(integer()),
    boolean()
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
rw_acquire_read(Client, Key, Ttl_ms, Wait) ->
    Body = gleam@json:object(
        lists:append(
            [opt_int(<<"ttl_ms"/utf8>>, Ttl_ms),
                [{<<"wait"/utf8>>, gleam@json:bool(Wait)}]]
        )
    ),
    send(
        Client,
        post,
        <<<<"/v1/rw/"/utf8, (enc(Key))/binary>>/binary, "/read"/utf8>>,
        {some, Body}
    ).

-file("src/fiducia.gleam", 303).
?DOC(" `POST /v1/rw/<key>/read/end` — release a read lock by its lock id.\n").
-spec rw_end_read(client(), binary(), binary()) -> {ok,
        gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
rw_end_read(Client, Key, Lock_id) ->
    Body = gleam@json:object([{<<"lock_id"/utf8>>, gleam@json:string(Lock_id)}]),
    send(
        Client,
        post,
        <<<<"/v1/rw/"/utf8, (enc(Key))/binary>>/binary, "/read/end"/utf8>>,
        {some, Body}
    ).

-file("src/fiducia.gleam", 313).
?DOC(" `POST /v1/rw/<key>/write` — acquire an exclusive write lock.\n").
-spec rw_acquire_write(
    client(),
    binary(),
    gleam@option:option(integer()),
    boolean()
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
rw_acquire_write(Client, Key, Ttl_ms, Wait) ->
    Body = gleam@json:object(
        lists:append(
            [opt_int(<<"ttl_ms"/utf8>>, Ttl_ms),
                [{<<"wait"/utf8>>, gleam@json:bool(Wait)}]]
        )
    ),
    send(
        Client,
        post,
        <<<<"/v1/rw/"/utf8, (enc(Key))/binary>>/binary, "/write"/utf8>>,
        {some, Body}
    ).

-file("src/fiducia.gleam", 327).
?DOC(" `POST /v1/rw/<key>/write/end` — release a write lock by its lock id.\n").
-spec rw_end_write(client(), binary(), binary()) -> {ok,
        gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
rw_end_write(Client, Key, Lock_id) ->
    Body = gleam@json:object([{<<"lock_id"/utf8>>, gleam@json:string(Lock_id)}]),
    send(
        Client,
        post,
        <<<<"/v1/rw/"/utf8, (enc(Key))/binary>>/binary, "/write/end"/utf8>>,
        {some, Body}
    ).

-file("src/fiducia.gleam", 339).
?DOC(" `GET /v1/kv?key=…` — read a config key.\n").
-spec kv_get(client(), binary()) -> {ok, gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
kv_get(Client, Key) ->
    send(Client, get, <<"/v1/kv?key="/utf8, (enc(Key))/binary>>, none).

-file("src/fiducia.gleam", 345).
?DOC(
    " `PUT /v1/kv?key=…` — write a config key. `prev_revision` is a compare-and-swap\n"
    " guard (0 = must-not-exist); when omitted the write is unconditional.\n"
).
-spec kv_put(
    client(),
    binary(),
    binary(),
    gleam@option:option(integer()),
    gleam@option:option(integer())
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
kv_put(Client, Key, Value, Ttl_ms, Prev_revision) ->
    Body = gleam@json:object(
        lists:append(
            [[{<<"value"/utf8>>, gleam@json:string(Value)}],
                opt_int(<<"ttl_ms"/utf8>>, Ttl_ms),
                opt_int(<<"prev_revision"/utf8>>, Prev_revision)]
        )
    ),
    send(Client, put, <<"/v1/kv?key="/utf8, (enc(Key))/binary>>, {some, Body}).

-file("src/fiducia.gleam", 364).
?DOC(" `DELETE /v1/kv?key=…` — delete a config key.\n").
-spec kv_delete(client(), binary()) -> {ok, gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
kv_delete(Client, Key) ->
    send(Client, delete, <<"/v1/kv?key="/utf8, (enc(Key))/binary>>, none).

-file("src/fiducia.gleam", 369).
?DOC(" `GET /v1/kv?prefix=…` — list config keys under a prefix.\n").
-spec kv_list(client(), binary()) -> {ok, gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
kv_list(Client, Prefix) ->
    send(Client, get, <<"/v1/kv?prefix="/utf8, (enc(Prefix))/binary>>, none).

-file("src/fiducia.gleam", 379).
?DOC(" `GET /v1/rate-limit/<tenant>/<key>` — current limiter state.\n").
-spec rate_limit_get(client(), binary(), binary()) -> {ok,
        gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
rate_limit_get(Client, Tenant, Key) ->
    send(
        Client,
        get,
        <<<<<<"/v1/rate-limit/"/utf8, (enc(Tenant))/binary>>/binary, "/"/utf8>>/binary,
            (enc(Key))/binary>>,
        none
    ).

-file("src/fiducia.gleam", 709).
-spec opt_float(binary(), gleam@option:option(float())) -> list({binary(),
    gleam@json:json()}).
opt_float(Name, Value) ->
    opt(Name, gleam@option:map(Value, fun gleam@json:float/1)).

-file("src/fiducia.gleam", 389).
?DOC(
    " `POST /v1/rate-limit/<tenant>/<key>/check` — atomic check-and-decrement.\n"
    " `algorithm` is `token_bucket` or `sliding_window`.\n"
).
-spec rate_limit_check(
    client(),
    binary(),
    binary(),
    binary(),
    integer(),
    integer(),
    gleam@option:option(float()),
    gleam@option:option(integer())
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
rate_limit_check(
    Client,
    Tenant,
    Key,
    Algorithm,
    Limit,
    Window_ms,
    Refill_per_second,
    Cost
) ->
    Body = gleam@json:object(
        lists:append(
            [[{<<"algorithm"/utf8>>, gleam@json:string(Algorithm)},
                    {<<"limit"/utf8>>, gleam@json:int(Limit)},
                    {<<"window_ms"/utf8>>, gleam@json:int(Window_ms)}],
                opt_float(<<"refill_per_second"/utf8>>, Refill_per_second),
                opt_int(<<"cost"/utf8>>, Cost)]
        )
    ),
    send(
        Client,
        post,
        <<<<<<<<"/v1/rate-limit/"/utf8, (enc(Tenant))/binary>>/binary,
                    "/"/utf8>>/binary,
                (enc(Key))/binary>>/binary,
            "/check"/utf8>>,
        {some, Body}
    ).

-file("src/fiducia.gleam", 422).
?DOC(" `GET /v1/cron/schedules/<name>` — read a schedule definition.\n").
-spec schedule_get(client(), binary()) -> {ok, gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
schedule_get(Client, Name) ->
    send(Client, get, <<"/v1/cron/schedules/"/utf8, (enc(Name))/binary>>, none).

-file("src/fiducia.gleam", 432).
?DOC(
    " `PUT /v1/cron/schedules/<name>` — create/update a schedule. `target` is\n"
    " arbitrary JSON, e.g. `{kind: \"webhook\", url: \"…\"}`. Provide exactly one of\n"
    " `cron` / `one_shot_at_ms`.\n"
).
-spec schedule_upsert(
    client(),
    binary(),
    gleam@json:json(),
    gleam@option:option(binary()),
    gleam@option:option(integer()),
    gleam@option:option(binary()),
    gleam@option:option(integer())
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
schedule_upsert(
    Client,
    Name,
    Target,
    Cron,
    One_shot_at_ms,
    Delivery,
    Max_retries
) ->
    Body = gleam@json:object(
        lists:append(
            [[{<<"target"/utf8>>, Target}],
                opt_string(<<"cron"/utf8>>, Cron),
                opt_int(<<"one_shot_at_ms"/utf8>>, One_shot_at_ms),
                opt_string(<<"delivery"/utf8>>, Delivery),
                opt_int(<<"max_retries"/utf8>>, Max_retries)]
        )
    ),
    send(
        Client,
        put,
        <<"/v1/cron/schedules/"/utf8, (enc(Name))/binary>>,
        {some, Body}
    ).

-file("src/fiducia.gleam", 456).
?DOC(
    " `POST /v1/cron/schedules/<name>/runs` — record a fire; duplicate `fire_id` is\n"
    " deduped (exactly-once).\n"
).
-spec schedule_record_run(
    client(),
    binary(),
    binary(),
    gleam@option:option(integer())
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
schedule_record_run(Client, Name, Fire_id, Fired_at_ms) ->
    Body = gleam@json:object(
        lists:append(
            [[{<<"fire_id"/utf8>>, gleam@json:string(Fire_id)}],
                opt_int(<<"fired_at_ms"/utf8>>, Fired_at_ms)]
        )
    ),
    send(
        Client,
        post,
        <<<<"/v1/cron/schedules/"/utf8, (enc(Name))/binary>>/binary,
            "/runs"/utf8>>,
        {some, Body}
    ).

-file("src/fiducia.gleam", 473).
?DOC(" `GET /v1/cron/schedules/<name>/history` — recent run history.\n").
-spec schedule_history(client(), binary()) -> {ok, gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
schedule_history(Client, Name) ->
    send(
        Client,
        get,
        <<<<"/v1/cron/schedules/"/utf8, (enc(Name))/binary>>/binary,
            "/history"/utf8>>,
        none
    ).

-file("src/fiducia.gleam", 483).
?DOC(" `GET /v1/elections/<name>` — observe the current holder.\n").
-spec election_get(client(), binary()) -> {ok, gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
election_get(Client, Name) ->
    send(Client, get, <<"/v1/elections/"/utf8, (enc(Name))/binary>>, none).

-file("src/fiducia.gleam", 492).
?DOC(
    " `POST /v1/elections/<name>/campaign` — campaign for leadership. `metadata`\n"
    " (arbitrary JSON) is published on the leadership record.\n"
).
-spec election_campaign(
    client(),
    binary(),
    binary(),
    integer(),
    gleam@option:option(gleam@json:json())
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
election_campaign(Client, Name, Candidate, Ttl_ms, Metadata) ->
    Body = gleam@json:object(
        lists:append(
            [[{<<"candidate"/utf8>>, gleam@json:string(Candidate)},
                    {<<"ttl_ms"/utf8>>, gleam@json:int(Ttl_ms)}],
                opt(<<"metadata"/utf8>>, Metadata)]
        )
    ),
    send(
        Client,
        post,
        <<<<"/v1/elections/"/utf8, (enc(Name))/binary>>/binary,
            "/campaign"/utf8>>,
        {some, Body}
    ).

-file("src/fiducia.gleam", 510).
?DOC(" `POST /v1/elections/<name>/renew` — extend the lease with the held token.\n").
-spec election_renew(client(), binary(), binary(), integer()) -> {ok,
        gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
election_renew(Client, Name, Candidate, Fencing_token) ->
    Body = gleam@json:object(
        [{<<"candidate"/utf8>>, gleam@json:string(Candidate)},
            {<<"fencing_token"/utf8>>, gleam@json:int(Fencing_token)}]
    ),
    send(
        Client,
        post,
        <<<<"/v1/elections/"/utf8, (enc(Name))/binary>>/binary, "/renew"/utf8>>,
        {some, Body}
    ).

-file("src/fiducia.gleam", 525).
?DOC(" `POST /v1/elections/<name>/resign` — step down with the held token.\n").
-spec election_resign(client(), binary(), binary(), integer()) -> {ok,
        gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
election_resign(Client, Name, Candidate, Fencing_token) ->
    Body = gleam@json:object(
        [{<<"candidate"/utf8>>, gleam@json:string(Candidate)},
            {<<"fencing_token"/utf8>>, gleam@json:int(Fencing_token)}]
    ),
    send(
        Client,
        post,
        <<<<"/v1/elections/"/utf8, (enc(Name))/binary>>/binary, "/resign"/utf8>>,
        {some, Body}
    ).

-file("src/fiducia.gleam", 542).
?DOC(" `GET /v1/services/<service>` — list live instances of a service.\n").
-spec service_instances(client(), binary()) -> {ok, gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
service_instances(Client, Service) ->
    send(Client, get, <<"/v1/services/"/utf8, (enc(Service))/binary>>, none).

-file("src/fiducia.gleam", 551).
?DOC(
    " `PUT /v1/services/<service>/instances/<instance_id>` — register/refresh an\n"
    " instance with a TTL lease and optional `metadata` (arbitrary JSON).\n"
).
-spec service_register(
    client(),
    binary(),
    binary(),
    binary(),
    integer(),
    gleam@option:option(gleam@json:json())
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
service_register(Client, Service, Instance_id, Address, Ttl_ms, Metadata) ->
    Body = gleam@json:object(
        lists:append(
            [[{<<"address"/utf8>>, gleam@json:string(Address)},
                    {<<"ttl_ms"/utf8>>, gleam@json:int(Ttl_ms)}],
                opt(<<"metadata"/utf8>>, Metadata)]
        )
    ),
    send(
        Client,
        put,
        <<<<<<"/v1/services/"/utf8, (enc(Service))/binary>>/binary,
                "/instances/"/utf8>>/binary,
            (enc(Instance_id))/binary>>,
        {some, Body}
    ).

-file("src/fiducia.gleam", 575).
?DOC(" `POST /v1/services/<service>/instances/<instance_id>/heartbeat` — renew a lease.\n").
-spec service_heartbeat(
    client(),
    binary(),
    binary(),
    gleam@option:option(integer())
) -> {ok, gleam@dynamic:dynamic_()} | {error, fiducia_error()}.
service_heartbeat(Client, Service, Instance_id, Ttl_ms) ->
    Body = gleam@json:object(opt_int(<<"ttl_ms"/utf8>>, Ttl_ms)),
    send(
        Client,
        post,
        <<<<<<<<"/v1/services/"/utf8, (enc(Service))/binary>>/binary,
                    "/instances/"/utf8>>/binary,
                (enc(Instance_id))/binary>>/binary,
            "/heartbeat"/utf8>>,
        {some, Body}
    ).

-file("src/fiducia.gleam", 595).
?DOC(" `DELETE /v1/services/<service>/instances/<instance_id>` — remove an instance.\n").
-spec service_deregister(client(), binary(), binary()) -> {ok,
        gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
service_deregister(Client, Service, Instance_id) ->
    send(
        Client,
        delete,
        <<<<<<"/v1/services/"/utf8, (enc(Service))/binary>>/binary,
                "/instances/"/utf8>>/binary,
            (enc(Instance_id))/binary>>,
        none
    ).

-file("src/fiducia.gleam", 609).
?DOC(" `GET /v1/services` — list all registered services.\n").
-spec service_list(client()) -> {ok, gleam@dynamic:dynamic_()} |
    {error, fiducia_error()}.
service_list(Client) ->
    send(Client, get, <<"/v1/services"/utf8>>, none).
