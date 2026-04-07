FROM rust:1.89-bookworm AS builder
WORKDIR /app

COPY Cargo.toml ./
COPY Cargo.lock ./
COPY apps ./apps
COPY crates ./crates
COPY migrations ./migrations

RUN cargo build --release -p trixd \
    && strip /app/target/release/trixd

FROM debian:bookworm-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system trix \
    && useradd --system --gid trix --no-create-home trix

WORKDIR /srv/trix
COPY --from=builder /app/target/release/trixd /usr/local/bin/trixd
RUN mkdir -p /var/lib/trix/blobs && chown -R trix:trix /var/lib/trix

USER trix

ENV TRIX_BIND_ADDR=0.0.0.0:8080
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -sf http://localhost:8080/v0/system/health | grep -q '"ok"' || exit 1

CMD ["trixd"]
