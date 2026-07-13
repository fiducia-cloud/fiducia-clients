#!/usr/bin/env bash
#
# run-node.sh — boot ONE fiducia-node for client-conformance testing and block
# until its /v1 coordination API is ready, then leave it running in the
# background. A single node self-elects leader of every shard (Raft quorum of 1),
# so the full /v1 surface is live with no cluster to stand up.
#
# Usage:
#   ./run-node.sh          # boot + wait for readiness (default MODE=cargo)
#   ./run-node.sh down     # stop whatever this script started
#   MODE=docker ./run-node.sh      # boot via docker compose instead of cargo
#
# The client/data-plane API (/healthz, /readyz, /v1/*) is served on:
#   http://localhost:${FIDUCIA_NODE_PORT:-8090}
#
# Env knobs:
#   FIDUCIA_NODE_PORT   host port for the client API           (default 8090)
#   MODE                cargo | docker                         (default cargo)
#   FIDUCIA_NODE_REPO   path to the fiducia-node.rs checkout   (default ../../fiducia-node.rs)
#   FIDUCIA_RUNTIME_DIR where the pidfile + WAL data dir live  (default $TMPDIR/fiducia-conformance)
#                       — deliberately OUTSIDE this repo so `git status` stays clean.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PORT="${FIDUCIA_NODE_PORT:-8090}"
PEER_PORT="${FIDUCIA_PEER_PORT:-9090}"
MODE="${MODE:-cargo}"
NODE_REPO="${FIDUCIA_NODE_REPO:-$HERE/../../fiducia-node.rs}"
RUNTIME_DIR="${FIDUCIA_RUNTIME_DIR:-${TMPDIR:-/tmp}/fiducia-conformance}"
PIDFILE="$RUNTIME_DIR/node.pid"
BASE="http://localhost:$PORT"

wait_ready() {
  echo "run-node: waiting for $BASE/readyz ..."
  for _ in $(seq 1 120); do
    if curl -fsS "$BASE/readyz" >/dev/null 2>&1; then
      echo "run-node: node READY on $BASE  (client API: /healthz /readyz /v1/*)"
      return 0
    fi
    sleep 1
  done
  echo "run-node: ERROR — node not ready after 120s" >&2
  return 1
}

up_cargo() {
  command -v cargo >/dev/null || { echo "run-node: cargo not found" >&2; exit 1; }
  [ -d "$NODE_REPO" ] || { echo "run-node: node repo not found at $NODE_REPO (set FIDUCIA_NODE_REPO)" >&2; exit 1; }
  mkdir -p "$RUNTIME_DIR"
  local data_dir="$RUNTIME_DIR/data"
  echo "run-node: building release binary in $NODE_REPO (first build is slow: several minutes)"
  ( cd "$NODE_REPO" && cargo build --locked --release )
  echo "run-node: starting single node  node_id=node-a  peers=[]  data_dir=$data_dir"
  # SINGLE-NODE CONFIG:
  #   FIDUCIA_PEERS unset      -> empty peer set -> self-elects every shard at t=0
  #   FIDUCIA_DATA_DIR         -> MUST be writable; the default (/var/lib/fiducia)
  #                               is not writable locally and the node PANICS on boot.
  FIDUCIA_NODE_ID="${FIDUCIA_NODE_ID:-node-a}" \
  FIDUCIA_DATA_DIR="$data_dir" \
  PORT="$PORT" FIDUCIA_PEER_PORT="$PEER_PORT" \
  RUST_LOG="${RUST_LOG:-info}" \
    "$NODE_REPO/target/release/fiducia-node" > "$RUNTIME_DIR/node.log" 2>&1 &
  echo $! > "$PIDFILE"
  echo "run-node: pid $(cat "$PIDFILE")  log $RUNTIME_DIR/node.log"
  wait_ready
}

up_docker() {
  command -v docker >/dev/null || { echo "run-node: docker not found" >&2; exit 1; }
  export FIDUCIA_NODE_PORT="$PORT" FIDUCIA_NODE_REPO="$NODE_REPO"
  echo "run-node: docker compose up (builds image from $NODE_REPO; first build is slow)"
  docker compose -f "$HERE/docker-compose.yml" up -d --build
  wait_ready
}

down() {
  if [ -f "$PIDFILE" ]; then
    pid="$(cat "$PIDFILE")"
    if kill "$pid" 2>/dev/null; then echo "run-node: stopped cargo node pid $pid"; fi
    rm -f "$PIDFILE"
  fi
  if command -v docker >/dev/null 2>&1; then
    docker compose -f "$HERE/docker-compose.yml" down 2>/dev/null || true
  fi
}

case "${1:-up}" in
  up)   case "$MODE" in cargo) up_cargo ;; docker) up_docker ;; *) echo "run-node: unknown MODE=$MODE (cargo|docker)" >&2; exit 2 ;; esac ;;
  down) down ;;
  *)    echo "usage: $0 [up|down]   (MODE=cargo|docker)" >&2; exit 2 ;;
esac
