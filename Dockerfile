ARG TRIX_BIN=trixd

FROM rust:1.89-bookworm AS builder
ARG TRIX_BIN
WORKDIR /app

COPY Cargo.toml ./
COPY Cargo.lock ./
COPY apps ./apps
COPY crates ./crates
COPY migrations ./migrations

RUN cargo build --release -p "${TRIX_BIN}" \
    && strip "/app/target/release/${TRIX_BIN}"

FROM debian:bookworm-slim
ARG TRIX_BIN
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --system trix \
    && useradd --system --gid trix --no-create-home trix

WORKDIR /srv/trix
COPY --from=builder /app/target/release/${TRIX_BIN} /usr/local/bin/trix-service
RUN mkdir -p /var/lib/trix/blobs && chown -R trix:trix /var/lib/trix

USER trix

ENV TRIX_BIND_ADDR=0.0.0.0:8080
ENV TRIX_HEALTHCHECK_URL=http://localhost:8080/v0/system/health
EXPOSE 8080 8090

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl -sf "$TRIX_HEALTHCHECK_URL" | grep -q '"ok"' || exit 1

CMD ["trix-service"]
