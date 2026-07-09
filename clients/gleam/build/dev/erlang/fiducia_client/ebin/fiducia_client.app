{application, fiducia_client, [
    {vsn, "0.1.0"},
    {applications, [gleam_http,
                    gleam_httpc,
                    gleam_json,
                    gleam_stdlib]},
    {description, "Thin HTTP client for fiducia.cloud (distributed locks, semaphores, KV, cron, elections, service discovery)."},
    {modules, []},
    {registered, []}
]}.
