(* Fiducia HTTP client (OCaml). Synchronous transport via ezcurl (libcurl);
   JSON via yojson; URL-encoding via uri. Implements PROTOCOL.md.

     let c = Fiducia.create "https://api.fiducia.cloud" in
     let resp = Fiducia.lock_acquire c ~key:"orders/checkout" ~ttl_ms:30000 () in
     (* resp : Yojson.Safe.t, e.g. resp["result"]["output"]["fencing_token"] *)
     ignore (Fiducia.lock_release c ~holder:"worker-a" ~fencing_token:tok ())

   Deps: ezcurl + curl (libcurl bindings), yojson, uri. *)

(* Raised on any HTTP response with status >= 300. [body] is the parsed JSON
   payload (or `Null for an empty body). *)
exception Fiducia_error of { status : int; body : Yojson.Safe.t }

type client = {
  base : string;
  ez : Ezcurl.t;
}

let create ?timeout base_url =
  (* trim trailing slashes from the base URL *)
  let base =
    let n = ref (String.length base_url) in
    while !n > 0 && base_url.[!n - 1] = '/' do
      decr n
    done;
    String.sub base_url 0 !n
  in
  (* ezcurl's Config exposes no timeout, so set libcurl's timeout directly on
     the shared handle. ezcurl re-applies these opts after each Curl.reset, so a
     reused client keeps the timeout on every request. [timeout] is in seconds. *)
  let set_opts (h : Curl.t) =
    match timeout with
    | Some t when t > 0. ->
      let ms = int_of_float (t *. 1000.) in
      Curl.set_timeoutms h ms;
      Curl.set_connecttimeoutms h ms
    | _ -> ()
  in
  { base; ez = Ezcurl.make ~set_opts () }

(* percent-encode a string for a path segment or query value. `Generic escapes
   everything except RFC 3986 unreserved chars, so '/', spaces, '&', '=' … are
   all encoded, which is what we want in both positions. *)
let enc (s : string) : string = Uri.pct_encode ~component:`Generic s

(* --- JSON body helpers ---
   Build an object, dropping any field whose value is None so that optional /
   compare-and-swap params are omitted rather than sent as null. *)
let req_s (s : string) : Yojson.Safe.t option = Some (`String s)

let opt_s : string option -> Yojson.Safe.t option = function
  | Some s -> Some (`String s)
  | None -> None

let req_i (n : int) : Yojson.Safe.t option = Some (`Int n)

let opt_i : int option -> Yojson.Safe.t option = function
  | Some n -> Some (`Int n)
  | None -> None

let req_b (b : bool) : Yojson.Safe.t option = Some (`Bool b)

let obj (fields : (string * Yojson.Safe.t option) list) : Yojson.Safe.t =
  `Assoc
    (List.filter_map
       (fun (k, v) -> match v with Some x -> Some (k, x) | None -> None)
       fields)

(* --- request core --- *)
let request c meth path (body : Yojson.Safe.t option) : Yojson.Safe.t =
  let url = c.base ^ path in
  let content =
    match body with
    | None -> None
    | Some j -> Some (`String (Yojson.Safe.to_string j))
  in
  let headers =
    match body with
    | None -> []
    | Some _ -> [ ("content-type", "application/json") ]
  in
  let ez_meth =
    match meth with
    | `GET -> Ezcurl.GET
    | `POST -> Ezcurl.POST []
    | `PUT -> Ezcurl.PUT
    | `DELETE -> Ezcurl.DELETE
  in
  match Ezcurl.http ~client:c.ez ?content ~headers ~url ~meth:ez_meth () with
  | Error (_code, msg) -> failwith ("fiducia: HTTP transport error: " ^ msg)
  | Ok resp ->
    let raw = resp.Ezcurl.body in
    let parsed =
      if String.length raw = 0 then `Null
      else try Yojson.Safe.from_string raw with _ -> `String raw
    in
    if resp.Ezcurl.code >= 300 then
      raise (Fiducia_error { status = resp.Ezcurl.code; body = parsed })
    else parsed

(* --- misc --- *)
let health c = request c `GET "/healthz" None
let status c = request c `GET "/v1/status" None

(* --- locks --- *)
let lock_get c ~key = request c `GET ("/v1/locks?key=" ^ enc key) None

let lock_acquire c ~key ?holder ?ttl_ms ?(wait = true) () =
  request c `POST "/v1/locks/acquire"
    (Some
       (obj
          [ ("key", req_s key);
            ("holder", opt_s holder);
            ("ttl_ms", opt_i ttl_ms);
            ("wait", req_b wait)
          ]))

let lock_acquire_many c ~keys ?holder ?ttl_ms ?(wait = true) () =
  request c `POST "/v1/locks/acquire"
    (Some
       (obj
          [ ("keys", Some (`List (List.map (fun s -> `String s) keys)));
            ("holder", opt_s holder);
            ("ttl_ms", opt_i ttl_ms);
            ("wait", req_b wait)
          ]))

let try_lock c ~key ?holder ?ttl_ms () =
  lock_acquire c ~key ?holder ?ttl_ms ~wait:false ()

let must_lock c ~key ?holder ?ttl_ms () =
  lock_acquire c ~key ?holder ?ttl_ms ~wait:true ()

let lock = must_lock

(* [key] is accepted for symmetry with [lock_acquire] but is not sent. *)
let lock_release c ?key ~holder ~fencing_token () =
  ignore (key : string option);
  request c `POST "/v1/locks/release"
    (Some (obj [ ("holder", req_s holder); ("fencing_token", req_s fencing_token) ]))

(* --- semaphores --- *)
let semaphore_get c ~key = request c `GET ("/v1/semaphores?key=" ^ enc key) None

let semaphore_acquire c ~key ~limit ?holder ?ttl_ms ?(wait = true) () =
  request c `POST "/v1/semaphores/acquire"
    (Some
       (obj
          [ ("key", req_s key);
            ("holder", opt_s holder);
            ("ttl_ms", opt_i ttl_ms);
            ("limit", req_i limit);
            ("wait", req_b wait)
          ]))

let try_semaphore c ~key ~limit ?holder ?ttl_ms () =
  semaphore_acquire c ~key ~limit ?holder ?ttl_ms ~wait:false ()

let must_semaphore c ~key ~limit ?holder ?ttl_ms () =
  semaphore_acquire c ~key ~limit ?holder ?ttl_ms ~wait:true ()

let semaphore = must_semaphore

let semaphore_release c ~key ~holder ~fencing_token =
  request c `POST "/v1/semaphores/release"
    (Some
       (obj
          [ ("key", req_s key);
            ("holder", req_s holder);
            ("fencing_token", req_s fencing_token)
          ]))

(* --- idempotency --- *)
let idempotency_get c ~key = request c `GET ("/v1/idempotency?key=" ^ enc key) None

let idempotency_claim c ~key ?owner ?ttl_ms ?ttl ?metadata () =
  request c `POST "/v1/idempotency/claim"
    (Some
       (obj
          [ ("key", req_s key);
            ("owner", opt_s owner);
            ("ttl_ms", opt_i ttl_ms);
            ("ttl", opt_i ttl);
            ("metadata", (metadata : Yojson.Safe.t option))
          ]))

let idempotency_complete c ~key ~owner ~fencing_token ?result () =
  request c `POST "/v1/idempotency/complete"
    (Some
       (obj
          [ ("key", req_s key);
            ("owner", req_s owner);
            ("fencing_token", req_s fencing_token);
            ("result", (result : Yojson.Safe.t option))
          ]))

(* --- reader-writer locks --- *)
let rw_acquire_read c ~key ?ttl_ms ?(wait = true) () =
  request c `POST
    ("/v1/rw/" ^ enc key ^ "/read")
    (Some (obj [ ("ttl_ms", opt_i ttl_ms); ("wait", req_b wait) ]))

let rw_end_read c ~key ~lock_id =
  request c `POST
    ("/v1/rw/" ^ enc key ^ "/read/end")
    (Some (obj [ ("lock_id", req_s lock_id) ]))

let rw_acquire_write c ~key ?ttl_ms ?(wait = true) () =
  request c `POST
    ("/v1/rw/" ^ enc key ^ "/write")
    (Some (obj [ ("ttl_ms", opt_i ttl_ms); ("wait", req_b wait) ]))

let rw_end_write c ~key ~lock_id =
  request c `POST
    ("/v1/rw/" ^ enc key ^ "/write/end")
    (Some (obj [ ("lock_id", req_s lock_id) ]))

(* --- config KV --- *)
let kv_get c ~key = request c `GET ("/v1/kv?key=" ^ enc key) None

let kv_put c ~key ~(value : Yojson.Safe.t) ?ttl_ms ?prev_revision () =
  request c `PUT
    ("/v1/kv?key=" ^ enc key)
    (Some
       (obj
          [ ("value", Some value);
            ("ttl_ms", opt_i ttl_ms);
            ("prev_revision", opt_i prev_revision)
          ]))

let kv_delete c ~key = request c `DELETE ("/v1/kv?key=" ^ enc key) None
let kv_list c ~prefix = request c `GET ("/v1/kv?prefix=" ^ enc prefix) None

(* --- rate limiting --- *)
let rate_limit_get c ~tenant ~key =
  request c `GET ("/v1/rate-limit/" ^ enc tenant ^ "/" ^ enc key) None

let rate_limit_check c ~tenant ~key ~algorithm ~limit ~window_ms
    ?refill_per_second ?cost () =
  request c `POST
    ("/v1/rate-limit/" ^ enc tenant ^ "/" ^ enc key ^ "/check")
    (Some
       (obj
          [ ("algorithm", req_s algorithm);
            ("limit", req_i limit);
            ("window_ms", req_i window_ms);
            ("refill_per_second", opt_i refill_per_second);
            ("cost", opt_i cost)
          ]))

(* --- cron & scheduling --- *)
let schedule_get c ~name = request c `GET ("/v1/cron/schedules/" ^ enc name) None

let schedule_upsert c ~name ~(target : Yojson.Safe.t) ?cron ?one_shot_at_ms
    ?delivery ?max_retries () =
  request c `PUT
    ("/v1/cron/schedules/" ^ enc name)
    (Some
       (obj
          [ ("target", Some target);
            ("cron", opt_s cron);
            ("one_shot_at_ms", opt_i one_shot_at_ms);
            ("delivery", (delivery : Yojson.Safe.t option));
            ("max_retries", opt_i max_retries)
          ]))

let schedule_record_run c ~name ~fire_id ?fired_at_ms () =
  request c `POST
    ("/v1/cron/schedules/" ^ enc name ^ "/runs")
    (Some (obj [ ("fire_id", req_s fire_id); ("fired_at_ms", opt_i fired_at_ms) ]))

let schedule_history c ~name =
  request c `GET ("/v1/cron/schedules/" ^ enc name ^ "/history") None

(* --- leader election --- *)
let election_get c ~name = request c `GET ("/v1/elections/" ^ enc name) None

let election_campaign c ~name ~candidate ~ttl_ms ?metadata () =
  request c `POST
    ("/v1/elections/" ^ enc name ^ "/campaign")
    (Some
       (obj
          [ ("candidate", req_s candidate);
            ("ttl_ms", req_i ttl_ms);
            ("metadata", (metadata : Yojson.Safe.t option))
          ]))

let election_renew c ~name ~candidate ~fencing_token =
  request c `POST
    ("/v1/elections/" ^ enc name ^ "/renew")
    (Some
       (obj
          [ ("candidate", req_s candidate);
            ("fencing_token", req_s fencing_token)
          ]))

let election_resign c ~name ~candidate ~fencing_token =
  request c `POST
    ("/v1/elections/" ^ enc name ^ "/resign")
    (Some
       (obj
          [ ("candidate", req_s candidate);
            ("fencing_token", req_s fencing_token)
          ]))

(* --- service discovery --- *)
let service_instances c ~service = request c `GET ("/v1/services/" ^ enc service) None

let service_register c ~service ~instance_id ~address ~ttl_ms ?metadata () =
  request c `PUT
    ("/v1/services/" ^ enc service ^ "/instances/" ^ enc instance_id)
    (Some
       (obj
          [ ("address", req_s address);
            ("ttl_ms", req_i ttl_ms);
            ("metadata", (metadata : Yojson.Safe.t option))
          ]))

let service_heartbeat c ~service ~instance_id ?ttl_ms () =
  request c `POST
    ("/v1/services/" ^ enc service ^ "/instances/" ^ enc instance_id ^ "/heartbeat")
    (Some (obj [ ("ttl_ms", opt_i ttl_ms) ]))

let service_deregister c ~service ~instance_id =
  request c `DELETE
    ("/v1/services/" ^ enc service ^ "/instances/" ^ enc instance_id)
    None

let service_list c = request c `GET "/v1/services" None
