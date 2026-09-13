#include "fiducia_client.h"
fiducia_client fiducia_client_new(const char *base_url, const char *bearer_token) {
  fiducia_client value = {base_url, bearer_token}; return value;
}
bool fiducia_client_health(const fiducia_client *client) { return client != 0 && client->base_url != 0; }
