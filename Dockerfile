# syntax=docker/dockerfile:1
# CI/test image for the multi-language Fiducia clients.
FROM rust:1.97.1-bookworm@sha256:77fac8b98f9f46062bb680b6d25d5bcaabfc400143952ebc572e924bcbedc3fa
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates python3 nodejs npm
# bookworm's apt `golang-go` is 1.19, but the generated go client's go.mod
# requires >=1.21 (it uses strings.ContainsFunc). Bring a modern, multi-arch Go
# from the official pinned image instead. GOTOOLCHAIN=local keeps the build
# offline — it uses exactly this toolchain rather than fetching go.mod's version.
COPY --from=golang:1.24-bookworm@sha256:1a6d4452c65dea36aac2e2d606b01b4a029ec90cc1ae53890540ce6173ea77ac /usr/local/go /usr/local/go
RUN useradd --create-home --uid 10001 ci \
    && install -d -o 10001 -g 10001 /app /fiducia-interfaces /home/ci/.cargo /home/ci/.cache/go
ENV HOME=/home/ci \
    CARGO_HOME=/home/ci/.cargo \
    GOCACHE=/home/ci/.cache/go \
    GOTOOLCHAIN=local \
    PATH=/usr/local/go/bin:${PATH}
USER 10001:10001
ARG INTERFACES_REF=6e20a3f4df2e52b99a0ad6add83d4528262b5dbc
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
