# fiducia.client — R sources

The R source directory required by R's package layout. Holds `fiducia.R`, which
implements the entire client: the `fiducia_client` constructor plus one exported
function per `PROTOCOL.md` operation. The wire protocol is fully encapsulated
here — callers pass keys/holders and the client maps them to the HTTP contract.
