let base = Printf.sprintf "http://127.0.0.1:%s" (Sys.getenv "PORT")
let c = Fiducia.create base
let pf = Printf.printf
let jstr = Yojson.Safe.to_string

let expect_ok name f =
  try
    let r = f () in
    pf "OK   %-22s -> %s\n" name (jstr r)
  with e -> pf "FAIL %-22s raised %s\n" name (Printexc.to_string e)

let expect_err name ~status ~check f =
  try
    let r = f () in
    pf "FAIL %-22s expected error, got %s\n" name (jstr r)
  with
  | Fiducia.Fiducia_error { status = s; body } ->
    if s = status && check body then
      pf "OK   %-22s -> Fiducia_error %d body=%s\n" name s (jstr body)
    else pf "FAIL %-22s wrong error status=%d body=%s\n" name s (jstr body)
  | e -> pf "FAIL %-22s wrong exn %s\n" name (Printexc.to_string e)

let () =
  (* request-side calls (bodies/paths asserted from the server log) *)
  expect_ok "health" (fun () -> Fiducia.health c);
  expect_ok "try_lock(wait:false)" (fun () ->
      Fiducia.try_lock c ~key:"orders/checkout" ~holder:"w" ());
  expect_ok "kv_put(prev_rev:0)" (fun () ->
      Fiducia.kv_put c ~key:"cfg/x" ~value:(`String "v") ~prev_revision:0 ());
  expect_ok "idem_claim(ttl:24h)" (fun () ->
      Fiducia.idempotency_claim c ~key:"job/1" ~owner:"o" ~ttl:"24h" ());
  expect_ok "lock_release(no key)" (fun () ->
      Fiducia.lock_release c ~holder:"h" ~fencing_token:"9007199254740993" ());
  expect_ok "lock_get(enc /,sp,€)" (fun () ->
      Fiducia.lock_get c ~key:"a/b c\xe2\x82\xac");
  expect_ok "service_register(enc)" (fun () ->
      Fiducia.service_register c ~service:"svc/a" ~instance_id:"id/1"
        ~address:"1.2.3.4" ~ttl_ms:1000 ());

  (* response-side behaviors *)
  expect_err "error_json(409)" ~status:409
    ~check:(function `Assoc l -> List.mem_assoc "error" l | _ -> false)
    (fun () -> Fiducia.lock_get c ~key:"errorjson");
  expect_err "error_text(503)" ~status:503
    ~check:(function `String s -> String.length s > 0 | _ -> false)
    (fun () -> Fiducia.semaphore_get c ~key:"errortext");
  (match Fiducia.kv_delete c ~key:"emptybody" with
   | `Null -> pf "OK   %-22s -> Null\n" "empty_204"
   | other -> pf "FAIL %-22s -> %s\n" "empty_204" (jstr other));

  (* 64-bit precision: echo body carries big:9007199254740993 (2^53+1) *)
  (match Fiducia.health c with
   | `Assoc l -> (
     match List.assoc_opt "big" l with
     | Some (`Int n) ->
       pf "OK   %-22s -> Int %d (%s)\n" "bigint_precision" n
         (if n = 9007199254740993 then "exact" else "LOST")
     | Some (`Intlit s) -> pf "OK   %-22s -> Intlit %s\n" "bigint_precision" s
     | Some other -> pf "FAIL %-22s -> %s\n" "bigint_precision" (jstr other)
     | None -> pf "WARN no big field\n")
   | _ -> pf "WARN health not assoc\n");
  Fiducia.close c;
  pf "OK   %-22s -> handle freed\n" "close"
