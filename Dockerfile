FROM alpine:3.16

RUN apk add --no-cache bash openssl yq
COPY generate-certs.sh /usr/local/bin/generate-certs.sh
RUN chmod +x /usr/local/bin/generate-certs.sh
WORKDIR /certs
ENTRYPOINT ["/usr/local/bin/generate-certs.sh"]
CMD ["/config.yml", "/certs"]
