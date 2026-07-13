# syntax=docker/dockerfile:1
# CI/test image for the multi-language Fiducia clients.
FROM rust:1.97.0-bookworm@sha256:7d0723df719e7f213b69dc7c8c595985c3f4b060cfbee4f7bc0e347a86fe3b6a
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates golang-go python3 nodejs npm
RUN useradd --create-home --uid 10001 ci \
    && install -d -o 10001 -g 10001 /app /fiducia-interfaces /home/ci/.cargo /home/ci/.cache/go
ENV HOME=/home/ci \
    CARGO_HOME=/home/ci/.cargo \
    GOCACHE=/home/ci/.cache/go
USER 10001:10001
ARG INTERFACES_REF=487e470c45ab5851e8f6f3b1dc048fe067fbf408
RUN git init /fiducia-interfaces \
    && git -C /fiducia-interfaces remote add origin https://github.com/fiducia-cloud/fiducia-interfaces.git \
    && git -C /fiducia-interfaces fetch --depth 1 origin "$INTERFACES_REF" \
    && test "$(git -C /fiducia-interfaces rev-parse FETCH_HEAD)" = "$INTERFACES_REF" \
    && git -C /fiducia-interfaces checkout --detach FETCH_HEAD \
    && test "$(git -C /fiducia-interfaces rev-parse HEAD)" = "$INTERFACES_REF"
WORKDIR /app
COPY --chown=10001:10001 . .
RUN cd clients/go \
    && go test ./... \
    && cd ../.. \
    && cargo test --locked --manifest-path clients/rust/Cargo.toml \
    && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest clients/python/fiducia_test.py
CMD ["bash", "-lc", "cd clients/go && go test ./... && cd ../.. && cargo test --locked --manifest-path clients/rust/Cargo.toml && PYTHONDONTWRITEBYTECODE=1 python3 -m unittest clients/python/fiducia_test.py"]
