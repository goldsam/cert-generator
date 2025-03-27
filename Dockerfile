FROM rust:alpine3.21 AS builder

RUN apk update && apk add --no-cache wget musl-dev

ARG MKCERT_VERSION=1.4.4
RUN wget -qO /usr/local/bin/mkcert https://github.com/FiloSottile/mkcert/releases/download/v${MKCERT_VERSION}/mkcert-v${MKCERT_VERSION}-linux-amd64
RUN cargo install jsonschema-cli

FROM alpine:3.21
WORKDIR /certs

RUN apk add --no-cache bash yq ca-certificates

COPY --from=builder /usr/local/cargo/bin/jsonschema-cli /usr/local/bin/jsonschema
COPY --from=builder /usr/local/bin/mkcert /usr/local/bin/mkcert
RUN chmod +x /usr/local/bin/mkcert

COPY config.schema.json /config.schema.json

COPY generate-certs.sh /usr/local/bin/generate-certs.sh
RUN chmod +x /usr/local/bin/generate-certs.sh

ENTRYPOINT ["/usr/local/bin/generate-certs.sh"]
CMD ["/config.yml"]
