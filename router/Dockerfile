FROM alpine:3.20

ARG SING_BOX_VERSION=1.12.4
ARG TARGETARCH

RUN apk add --no-cache bash ca-certificates curl iproute2 nftables

RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) arch='amd64' ;; \
      arm64) arch='arm64' ;; \
      *) echo "Unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box-${SING_BOX_VERSION}-linux-${arch}.tar.gz" -o /tmp/sing-box.tar.gz; \
    tar -xzf /tmp/sing-box.tar.gz -C /tmp; \
    install -m 0755 "/tmp/sing-box-${SING_BOX_VERSION}-linux-${arch}/sing-box" /usr/local/bin/sing-box; \
    rm -rf /tmp/sing-box*

COPY entrypoint.sh /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
