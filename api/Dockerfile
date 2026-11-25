# The API tier. Built from the repository root, because the crate embeds two
# files from outside its own directory: the migrations and the reference page.
#
#   docker build -f api/Dockerfile -t dephealth-api .
#
# SQLX_OFFLINE makes the build use the committed query data in api/.sqlx rather
# than a live database, which is what lets the image build anywhere.

FROM rust:1.100-trixie AS build

WORKDIR /src

# The manifests first, so a change to the source does not re-download every
# dependency
COPY api/Cargo.toml api/Cargo.lock ./api/
RUN mkdir -p api/src && echo 'fn main() {}' > api/src/main.rs \
    && echo '' > api/src/lib.rs \
    && cd api && cargo fetch --locked

COPY api ./api
COPY db/migrations ./db/migrations
COPY docs/api/index.html ./docs/api/index.html

ENV SQLX_OFFLINE=true
RUN cd api && cargo build --release --locked --bin dephealth-api --bin migrate

FROM debian:trixie-slim AS runtime

# Certificates for the TLS a managed database requires, since a deployment
# connects with sslmode=verify-full and needs a trust store. curl is here for
# the health check and nothing else
RUN apt-get update \
    && apt-get install --yes --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Nothing here needs to be root, and the service writes no files at all
RUN useradd --system --no-create-home --uid 10001 dephealth
USER 10001

COPY --from=build /src/api/target/release/dephealth-api /usr/local/bin/
COPY --from=build /src/api/target/release/migrate /usr/local/bin/dephealth-migrate

# Inside a container the service has to listen on every interface, since
# nothing else can reach a loopback address here
ENV API_BIND=0.0.0.0:8080
EXPOSE 8080

# Liveness, not readiness. A container that cannot reach the database should not
# be restarted for it, and a database with no completed ingestion run is not a
# fault in this process. Readiness is for deciding whether to send traffic,
# which is the load balancer's question rather than the runtime's
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD ["curl", "-fsS", "-o", "/dev/null", "http://127.0.0.1:8080/health/live"]

CMD ["/usr/local/bin/dephealth-api"]
