# Both tools in this image ship prebuilt static binaries for musl, so this
# stage only downloads and verifies them. Nothing is compiled from source.
FROM alpine:3.21 AS builder

RUN apk add --no-cache wget unzip

ARG MKCERT_VERSION=1.4.4
RUN wget -qO /usr/local/bin/mkcert \
        "https://github.com/FiloSottile/mkcert/releases/download/v${MKCERT_VERSION}/mkcert-v${MKCERT_VERSION}-linux-amd64" \
    && chmod +x /usr/local/bin/mkcert

# sourcemeta/jsonschema publishes a statically linked musl build. It replaces a
# `cargo install jsonschema-cli` step that compiled a large Rust dependency
# tree from source on every cold build; that crate publishes no binaries.
ARG JSONSCHEMA_VERSION=16.8.0
ARG JSONSCHEMA_SHA256=48ad5af513037fb194b9ab0ff7f4cd7f0388501c5bcf23a7272b47373babaa58
RUN wget -qO /tmp/jsonschema.zip \
        "https://github.com/sourcemeta/jsonschema/releases/download/v${JSONSCHEMA_VERSION}/jsonschema-${JSONSCHEMA_VERSION}-linux-x86_64-musl.zip" \
    && echo "${JSONSCHEMA_SHA256}  /tmp/jsonschema.zip" | sha256sum -c - \
    && unzip -q /tmp/jsonschema.zip -d /tmp/jsonschema \
    && install -m 0755 \
        "/tmp/jsonschema/jsonschema-${JSONSCHEMA_VERSION}-linux-x86_64-musl/bin/jsonschema" \
        /usr/local/bin/jsonschema

FROM alpine:3.21
WORKDIR /certs

RUN apk add --no-cache bash yq ca-certificates

COPY --from=builder /usr/local/bin/jsonschema /usr/local/bin/jsonschema
COPY --from=builder /usr/local/bin/mkcert /usr/local/bin/mkcert

COPY config.schema.json /config.schema.json

COPY generate-certs.sh /usr/local/bin/generate-certs.sh
RUN chmod +x /usr/local/bin/generate-certs.sh

ENTRYPOINT ["/usr/local/bin/generate-certs.sh"]
CMD ["/config.yml"]
