# zcash-devtool for the cluster wallet workflows: the CLI plus socat, which the
# workflows use to forward a local port to the zaino service.
FROM rust:1.90-bookworm AS build
ARG DEVTOOL_REF=5a26ee85
RUN apt-get update && apt-get install -y --no-install-recommends clang libclang-dev protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
RUN git clone https://github.com/zcash/zcash-devtool.git . && git checkout "$DEVTOOL_REF"
RUN cargo build --release --locked --bin zcash-devtool

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates socat \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/target/release/zcash-devtool /usr/local/bin/zcash-devtool
ENTRYPOINT []
