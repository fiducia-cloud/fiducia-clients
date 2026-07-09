let base = Printf.sprintf "http://127.0.0.1:%s" (Sys.getenv "PORT")
let c = Fiducia.create base (* default 30s timeout, redirects pinned off *)
let pf = Printf.printf
let jstr = Yojson.Safe.to_string

let expect_err name ~status f =
  try
    let r = f () in
    pf "FAIL %-26s expected error, got %s\n" name (jstr r)
  with
  | Fiducia.Fiducia_error { status = s; body } ->
    if s = status then
      pf "OK   %-26s -> Fiducia_error %d body=%s\n" name s (jstr body)
    else pf "FAIL %-26s wrong status=%d body=%s\n" name s (jstr body)
  | e -> pf "FAIL %-26s wrong exn %s\n" name (Printexc.to_string e)

let () =
  (* GET hitting a 302: must surface as error, not be followed *)
  expect_err "GET 302 not followed" ~status:302 (fun () ->
      Fiducia.lock_get c ~key:"redirectme");
  (* MUTATING PUT hitting a 302: must NOT be followed (would re-submit) *)
  expect_err "PUT 302 not re-submitted" ~status:302 (fun () ->
      Fiducia.kv_put c ~key:"redirectme" ~value:(`String "v") ~prev_revision:0 ());
  (* sanity: a normal 200 still works *)
  (match Fiducia.lock_get c ~key:"normal" with
   | `Assoc _ -> pf "OK   %-26s -> ok\n" "GET 200 sanity"
   | other -> pf "FAIL %-26s -> %s\n" "GET 200 sanity" (jstr other))
