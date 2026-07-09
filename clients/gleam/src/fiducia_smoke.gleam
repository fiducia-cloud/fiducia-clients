import fiducia
import gleam/json
import gleam/option.{None, Some}

pub fn main() {
  // trailing slash exercises drop_trailing_slashes
  let c = fiducia.new("http://127.0.0.1:8799/")

  echo fiducia.health(c)
  // GET success -> Ok(Dynamic)
  echo fiducia.status(c)
  // 404 -> Error(Http(404, <parsed body>))
  echo fiducia.kv_get(c, "does/not exist")

  // POST with arbitrary-JSON metadata; echoed body confirms encoding
  let meta = json.object([#("region", json.string("us-east-1"))])
  echo fiducia.service_register(c, "api", "i-1", "10.0.0.1:9000", 10_000, Some(meta))

  // optional fields present -> body includes holder/ttl_ms
  echo fiducia.lock_acquire(c, "orders/checkout", Some("worker-a"), Some(30_000), False)
  // optional fields None -> body must OMIT holder & ttl_ms (CAS semantics)
  echo fiducia.lock_acquire(c, "k2", None, None, True)

  // dead port -> Error(Transport(_))
  let dead = fiducia.new("http://127.0.0.1:9")
  echo fiducia.health(dead)
}
