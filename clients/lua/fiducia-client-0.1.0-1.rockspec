package = "fiducia-client"
version = "0.1.0-1"

source = {
  url = "git+https://github.com/fiducia-cloud/fiducia-clients.git",
}

description = {
  summary = "Fiducia HTTP client (distributed locks, semaphores, KV, rate limiting, cron, elections, service discovery).",
  detailed = [[
Thin, dependency-light Lua client for the fiducia.cloud coordination API. A
single fiducia.lua module wraps the HTTP contract described in PROTOCOL.md:
locks and semaphores, idempotency keys, reader-writer locks, config KV, rate
limiting, cron/scheduling, leader election, and service discovery. Transport is
luasocket for http and luasec for https, with JSON via dkjson.]],
  homepage = "https://github.com/fiducia-cloud/fiducia-clients/tree/main/clients/lua",
  license = "Proprietary",
  maintainer = "fiducia.cloud",
}

dependencies = {
  "lua >= 5.1",
  "luasocket",
  "luasec",
  "dkjson",
}

build = {
  type = "builtin",
  modules = {
    fiducia = "fiducia.lua",
  },
}
