FROM rust:1.89-bookworm AS builder
WORKDIR /app

COPY Cargo.toml ./
COPY Cargo.lock ./
COPY apps ./apps
COPY crates ./crates
COPY migrations ./migrations

RUN cargo build --release -p trixd

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /srv/trix
COPY --from=builder /app/target/release/trixd /usr/local/bin/trixd

ENV TRIX_BIND_ADDR=0.0.0.0:8080
EXPOSE 8080

CMD ["trixd"]
