# Stage 1: Build jsonschema-cli
FROM rust:alpine3.21 AS builder

RUN apk add --no-cache musl-dev

RUN cargo install jsonschema-cli

# Stage 2: Install dependencies and copy jsonschema-cli
FROM alpine:3.21

RUN apk add --no-cache bash openssl yq

COPY --from=builder /usr/local/cargo/bin/jsonschema-cli /usr/local/bin/jsonschema
COPY config.schema.json /config.schema.json
COPY generate-certs.sh /usr/local/bin/generate-certs.sh

RUN chmod +x /usr/local/bin/generate-certs.sh

WORKDIR /certs
ENTRYPOINT ["/usr/local/bin/generate-certs.sh"]
CMD ["/config.yml", "/certs"]
