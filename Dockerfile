# syntax=docker/dockerfile:1
# CI/test image for the multi-language Fiducia clients.
FROM rust:1.97.0-bookworm@sha256:8fa55b2f3ddf97471ab6a767bfa3f37e6bad0986ba823e75fea57e2a2a5c3073
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates golang-go python3 nodejs npm
RUN useradd --create-home --uid 10001 ci \
    && install -d -o 10001 -g 10001 /app /fiducia-interfaces /home/ci/.cargo /home/ci/.cache/go
ENV HOME=/home/ci \
    CARGO_HOME=/home/ci/.cargo \
    GOCACHE=/home/ci/.cache/go
USER 10001:10001
ARG INTERFACES_REF=e3dba39566e036ad61de91e2e6c1d625ec2b5411
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
