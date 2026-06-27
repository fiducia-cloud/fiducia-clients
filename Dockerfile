# syntax=docker/dockerfile:1
# CI/test image for the multi-language Fiducia clients.
FROM rust:1-bookworm
RUN apt-get update \
    && apt-get install -y --no-install-recommends golang-go python3 nodejs npm
WORKDIR /app
COPY . .
RUN cd clients/go \
    && go test ./... \
    && cd ../.. \
    && cargo test --manifest-path clients/rust/Cargo.toml \
    && PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile clients/python/fiducia.py
CMD ["bash", "-lc", "cd clients/go && go test ./... && cd ../.. && cargo test --manifest-path clients/rust/Cargo.toml && PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile clients/python/fiducia.py"]
