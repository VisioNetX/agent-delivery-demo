# openshell-tools: the OpenShell CLI and policy prover, plus the demo's automation
# scripts. Used by the gateway setup Job (Argo CD), the Kargo Custom Steps, and
# the Kargo verification Job.
FROM debian:bookworm-slim

# The image is tagged with this version (0.1.6, 0.1.6-1, ...). See
# .github/workflows/openshell-tools.yaml.
ARG OPENSHELL_VERSION=0.1.6
ARG TARGETARCH

# openssh-client: `openshell sandbox upload` and `sandbox create --upload` stream
# files over ssh (with `openshell ssh-proxy` as the ProxyCommand).
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl openssh-client python3 python3-yaml \
    && rm -rf /var/lib/apt/lists/*

# The CLI and prover ship as static musl binaries on the GitHub release.
# Each download is verified against the release's checksum file.
RUN set -eu; \
    case "${TARGETARCH:-amd64}" in \
      amd64) arch=x86_64 ;; \
      arm64) arch=aarch64 ;; \
      *) echo "unsupported arch ${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    base="https://github.com/NVIDIA/OpenShell/releases/download/v${OPENSHELL_VERSION}"; \
    cd /tmp; \
    for bin in openshell openshell-prover; do \
      tarball="${bin}-${arch}-unknown-linux-musl.tar.gz"; \
      curl -fsSLO "${base}/${tarball}"; \
      curl -fsSL "${base}/${bin}-checksums-sha256.txt" | grep " ${tarball}\$" | sha256sum -c -; \
      tar -xzf "${tarball}" -C /usr/local/bin "${bin}"; \
      rm "${tarball}"; \
    done; \
    openshell --version; openshell-prover --version

COPY bin/ /usr/local/bin/

# Kargo runs custom steps as UID 65532 with a read-only home, so the CLI keeps
# its config (gateway TLS material) under /tmp.
ENV XDG_CONFIG_HOME=/tmp/openshell-config \
    OPENSHELL_GATEWAY=openshell \
    OPENSHELL_GATEWAY_ENDPOINT=https://openshell.openshell.svc.cluster.local:8080

# ssh refuses to run for a UID with no passwd entry.
RUN useradd --uid 65532 --no-create-home --home-dir /tmp --shell /usr/sbin/nologin openshell

USER 65532
