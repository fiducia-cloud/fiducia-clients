-module(fiducia_client).
-export([new/2, base_url/1]).
new(BaseUrl, BearerToken) -> #{base_url => BaseUrl, bearer_token => BearerToken}.
base_url(Client) -> maps:get(base_url, Client).
