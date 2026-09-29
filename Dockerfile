# syntax=docker/dockerfile:1
#
# HINDSIGHT_VERSION and CURSOR_AGENT_VERSION come from
# scripts/resolve-build-versions.sh. That script reads the full
# ghcr.io/vectorize-io/hindsight:latest tag (OCI label, no layer download),
# never a -slim tag, and the version embedded in https://cursor.com/install.
# The full image carries the local embedding and reranker models.
# Do not build without it:
#
#   ./scripts/verify-local.sh
#
# https://cursor.com/install/<version> returns an HTML page, not the installer.
# The current installer always downloads:
#   https://downloads.cursor.com/lab/<version>/linux/<arch>/agent-cli-package.tar.gz
# The build uses that tarball so the image matches the version CI compared.
#
# The default tag does not exist. A bare docker build fails here instead of
# pulling the full image. scripts/resolve-build-versions.sh overrides it.
ARG RESOLVED_BY_SCRIPT=false
ARG HINDSIGHT_VERSION=must-resolve-via-script

FROM ghcr.io/vectorize-io/hindsight:${HINDSIGHT_VERSION}

ARG RESOLVED_BY_SCRIPT
ARG CURSOR_AGENT_VERSION=unknown
ARG TARGETARCH

USER root

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl ca-certificates bash \
    && rm -rf /var/lib/apt/lists/*

USER hindsight
ENV PATH="/home/hindsight/.local/bin:${PATH}"

RUN if [ "${RESOLVED_BY_SCRIPT}" != "true" ]; then \
      echo "Build via scripts/resolve-build-versions.sh (see Dockerfile header)." >&2; \
      exit 1; \
    fi \
    && case "${TARGETARCH}" in \
         amd64) arch="x64" ;; \
         arm64) arch="arm64" ;; \
         *) echo "Unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
       esac \
    && version_dir="/home/hindsight/.local/share/cursor-agent/versions/${CURSOR_AGENT_VERSION}" \
    && tmp="$(mktemp -d)" \
    && curl -fsSL "https://downloads.cursor.com/lab/${CURSOR_AGENT_VERSION}/linux/${arch}/agent-cli-package.tar.gz" \
         | tar --strip-components=1 -xzf - -C "${tmp}" \
    && mkdir -p "/home/hindsight/.local/share/cursor-agent/versions" "/home/hindsight/.local/bin" \
    && rm -rf "${version_dir}" \
    && mv "${tmp}" "${version_dir}" \
    && ln -s "${version_dir}/cursor-agent" /home/hindsight/.local/bin/agent \
    && ln -s "${version_dir}/cursor-agent" /home/hindsight/.local/bin/cursor-agent \
    && cursor-agent --version
