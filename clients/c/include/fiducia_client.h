#ifndef FIDUCIA_CLIENT_H
#define FIDUCIA_CLIENT_H
#include <stdbool.h>
typedef struct { const char *base_url; const char *bearer_token; } fiducia_client;
fiducia_client fiducia_client_new(const char *base_url, const char *bearer_token);
bool fiducia_client_health(const fiducia_client *client);
#endif
