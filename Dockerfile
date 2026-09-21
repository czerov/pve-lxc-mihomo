# syntax=docker/dockerfile:1.7

FROM --platform=$BUILDPLATFORM debian:bookworm-slim AS downloader

ARG TARGETARCH
ARG MIHOMO_VERSION=v1.19.28
ARG ZASHBOARD_URL=https://github.com/Zephyruso/zashboard/releases/latest/download/dist.zip

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl gzip unzip \
    && rm -rf /var/lib/apt/lists/*

COPY bin/ /tmp/nexusbox-bin/
COPY config.yaml /usr/share/pve-lxc-mihomo/config.yaml
COPY rules/ /usr/share/pve-lxc-mihomo/rules/

RUN set -eu; \
    case "$TARGETARCH" in \
      amd64) \
        mihomo_asset="mihomo-linux-amd64-compatible-${MIHOMO_VERSION}.gz"; \
        nexusbox_asset="nexusbox-linux-amd64"; \
        nexusbox_sha="443af7d019f92459cb692c86cf0161a7251c240c3a9344831657a3533b6e3408" \
        ;; \
      arm64) \
        mihomo_asset="mihomo-linux-arm64-${MIHOMO_VERSION}.gz"; \
        nexusbox_asset="nexusbox-linux-arm64"; \
        nexusbox_sha="e1aad8f69667dd1f2c145ef2c93d6d6663fd5b1f8a9bbd28e2914ad190bc707a" \
        ;; \
      *) echo "unsupported architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    install -d /opt/mihomo /opt/nexusbox /usr/share/pve-lxc-mihomo/ui/zash; \
    printf '%s  %s\n' "$nexusbox_sha" "/tmp/nexusbox-bin/$nexusbox_asset" | sha256sum -c -; \
    install -m 0755 "/tmp/nexusbox-bin/$nexusbox_asset" /opt/nexusbox/nexusbox; \
    release_url="https://github.com/MetaCubeX/mihomo/releases/download/${MIHOMO_VERSION}/${mihomo_asset}"; \
    downloaded=0; \
    for url in "$release_url" "https://gh-proxy.com/$release_url" "https://gh.llkk.cc/$release_url"; do \
      if curl -fL --connect-timeout 15 --retry 2 -o /tmp/mihomo.gz "$url"; then downloaded=1; break; fi; \
    done; \
    [ "$downloaded" = 1 ]; \
    gzip -dc /tmp/mihomo.gz > /opt/mihomo/mihomo; \
    chmod 0755 /opt/mihomo/mihomo

RUN set -eu; \
    downloaded=0; \
    for url in "$ZASHBOARD_URL" "https://gh-proxy.com/$ZASHBOARD_URL" "https://gh.llkk.cc/$ZASHBOARD_URL"; do \
      if curl -fL --connect-timeout 15 --retry 2 -o /tmp/zashboard.zip "$url"; then downloaded=1; break; fi; \
    done; \
    [ "$downloaded" = 1 ]; \
    mkdir -p /tmp/zashboard; \
    unzip -q /tmp/zashboard.zip -d /tmp/zashboard; \
    if [ -s /tmp/zashboard/dist/index.html ]; then \
      cp -a /tmp/zashboard/dist/. /usr/share/pve-lxc-mihomo/ui/zash/; \
    else \
      cp -a /tmp/zashboard/. /usr/share/pve-lxc-mihomo/ui/zash/; \
    fi; \
    test -s /usr/share/pve-lxc-mihomo/ui/zash/index.html

RUN set -eu; \
    install -d /usr/share/pve-lxc-mihomo/geodata; \
    for asset in geoip.dat geosite.dat country.mmdb; do \
      downloaded=0; \
      release_url="https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/${asset}"; \
      for url in \
        "https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/${asset}" \
        "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/${asset}" \
        "https://gh-proxy.com/${release_url}" \
        "$release_url"; do \
        if curl -fL --connect-timeout 15 --retry 2 -o "/tmp/${asset}" "$url"; then downloaded=1; break; fi; \
      done; \
      [ "$downloaded" = 1 ]; \
      size="$(wc -c < "/tmp/${asset}")"; \
      [ "$size" -ge 1048576 ]; \
      install -m 0644 "/tmp/${asset}" "/usr/share/pve-lxc-mihomo/geodata/${asset}"; \
    done

FROM debian:bookworm-slim

ARG MIHOMO_VERSION=v1.19.28

LABEL org.opencontainers.image.title="PVE LXC Mihomo / NexusBox" \
      org.opencontainers.image.description="Docker runtime for the project's patched NexusBox and Mihomo configuration" \
      org.opencontainers.image.source="https://github.com/czerov/pve-lxc-mihomo"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates curl iproute2 iptables jq nftables procps tini tzdata \
    && rm -rf /var/lib/apt/lists/*

COPY --from=downloader /opt/mihomo/ /opt/mihomo/
COPY --from=downloader /opt/nexusbox/ /opt/nexusbox/
COPY --from=downloader /usr/share/pve-lxc-mihomo/ /usr/share/pve-lxc-mihomo/
COPY docker/entrypoint.sh /usr/local/bin/docker-entrypoint.sh

RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh \
    && install -d /opt/config /opt/nexusbox/var /opt/nexusbox/ui/meta /opt/nexusbox/ui/zash

ENV TZ=Asia/Shanghai \
    GOMEMLIMIT=600MiB \
    SOCKET_PATH=/opt/nexusbox/var/app.sock \
    FLUXOR_ADDR=0.0.0.0:18080 \
    BASE_URL=/ \
    FLUXOR_PID_FILE=/opt/nexusbox/var/nexusbox.pid \
    FLUXOR_BIN_DIR=/opt/nexusbox/ \
    CORE_PID_FILE=/opt/nexusbox/var/core.pid \
    CORE_BIN=/opt/mihomo/mihomo \
    CORE_SOCKET=/opt/nexusbox/var/core.sock \
    CONFIG_TARGET=/opt/config/config.yaml \
    INFO_LOG_FILE=/opt/nexusbox/var/info.log \
    CORE_WORK_DIR=/opt/config \
    FLUXOR_CONFIG_FILE=/opt/config/nexusbox.json \
    META_DIR=/opt/nexusbox/ui/meta \
    ZASH_DIR=/opt/config/ui/zash \
    MIHOMO_VERSION=${MIHOMO_VERSION}

VOLUME ["/opt/config"]

EXPOSE 53/tcp 53/udp 7877/tcp 7890/tcp 7891/tcp 7896/tcp 7896/udp 9090/tcp 18080/tcp

HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
  CMD curl -fsS http://127.0.0.1:18080/ >/dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
CMD ["/opt/nexusbox/nexusbox"]
