# fiducia (C++)

Header-only C++17 HTTP client for [fiducia.cloud](https://github.com/fiducia-cloud/fiducia-clients).
A thin wrapper over the fiducia HTTP contract — see `PROTOCOL.md`. Every method
performs one request and returns an `nlohmann::json` value.

## Requirements

- A C++17 compiler.
- **[libcurl](https://curl.se/libcurl/)** — the HTTP transport. Link with `-lcurl`.
- **[nlohmann/json](https://github.com/nlohmann/json)** — header-only JSON,
  included as `<nlohmann/json.hpp>`.

## Install

This client is distributed as a single header, `fiducia.hpp`, published via
**GitHub Releases** (there is no universal C++ package registry). Grab the header
from the `clients/cpp/v<version>` release, or vendor this directory.

### CMake

An `INTERFACE` target `fiducia::client` is provided. It requires C++17 and links
libcurl + nlohmann/json for you:

```cmake
add_subdirectory(path/to/clients/cpp)   # or FetchContent
target_link_libraries(my_app PRIVATE fiducia::client)
```

`find_package(CURL REQUIRED)` and `find_package(nlohmann_json REQUIRED)` must be
satisfiable (e.g. `brew install curl nlohmann-json`, `apt install libcurl4-openssl-dev
nlohmann-json3-dev`, or vcpkg `curl` + `nlohmann-json`).

### Manual

Drop `fiducia.hpp` on your include path and compile against libcurl and
nlohmann/json yourself:

```sh
c++ -std=c++17 app.cpp -lcurl -o app
```

## Usage

```cpp
#include "fiducia.hpp"
#include <iostream>

int main() {
    fiducia::Client c("https://api.fiducia.cloud");

    // Acquire a lock (holder omitted, 30s TTL).
    auto lock = c.lock_acquire("orders/checkout", std::nullopt, 30000);
    auto token = lock["result"]["output"]["fencing_token"].get<std::int64_t>();
    c.lock_release("orders/checkout", "worker-a", token);

    // Config KV with a compare-and-swap guard.
    c.kv_put("features/flag", "on", std::nullopt, /*prev_revision=*/0);
    std::cout << c.kv_get("features/flag").dump(2) << "\n";
}
```

Optional parameters are `std::optional<>`; pass `std::nullopt` to omit a field
from the request body (this matters for compare-and-swap semantics). Arbitrary
JSON objects (`metadata`, `result`, `target`) are plain `nlohmann::json`; the
default `nullptr` omits them.

The full method surface (locks, semaphores, idempotency, reader-writer locks,
config KV, rate limiting, cron/scheduling, leader election, service discovery)
mirrors `PROTOCOL.md`.

## Errors

Any response with HTTP status `>= 300` throws `fiducia::Error`, which derives
from `std::runtime_error` and carries the numeric `status` and the parsed JSON
`body`:

```cpp
try {
    c.lock_release("orders/checkout", "worker-a", 999);
} catch (const fiducia::Error& e) {
    std::cerr << e.status << " " << e.body.dump() << "\n";
}
```

Transport-level failures (connection refused, timeout, …) throw
`std::runtime_error`.

## License

UNLICENSED — proprietary. All rights reserved unless fiducia.cloud grants a
separate license.
