FROM rust:1.88-slim AS builder

WORKDIR /app
COPY . .

ARG TRIX_BIN=trix-push-gateway
RUN cargo build --release --bin "${TRIX_BIN}"

FROM debian:bookworm-slim

ARG TRIX_BIN=trix-push-gateway
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --system --home /nonexistent --shell /usr/sbin/nologin trix

COPY --from=builder /app/target/release/${TRIX_BIN} /usr/local/bin/trix-service
USER trix

ENTRYPOINT ["/usr/local/bin/trix-service"]
