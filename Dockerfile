FROM rust:1.88-slim AS builder

WORKDIR /app
COPY . .

ARG TRIX_BIN=trix-push-gateway
RUN cargo build --release --bin "${TRIX_BIN}"

FROM debian:bookworm-slim

ARG TRIX_BIN=trix-push-gateway
RUN mkdir -p /etc/ssl/certs /var/lib/trix-device-passport \
    && useradd --system --home /nonexistent --shell /usr/sbin/nologin trix \
    && chown trix /var/lib/trix-device-passport

COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --from=builder /app/target/release/${TRIX_BIN} /usr/local/bin/trix-service
USER trix

ENTRYPOINT ["/usr/local/bin/trix-service"]
