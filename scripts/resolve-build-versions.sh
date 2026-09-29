#!/usr/bin/env bash
# Resolve the Hindsight image version and the Cursor agent version that
# https://cursor.com/install would install right now.
#
# Hindsight comes from the OCI config label org.opencontainers.image.version
# on the published tag (manifest + config blob only; the image layers stay
# unpulled). Cursor comes from the lab version embedded in the install script.
# https://cursor.com/install/<version> is not a supported URL.
#
# Usage:
#   eval "$(bash ./scripts/resolve-build-versions.sh --export)"
#   bash ./scripts/resolve-build-versions.sh --build-arg-file
set -euo pipefail

HINDSIGHT_REGISTRY_IMAGE="${HINDSIGHT_REGISTRY_IMAGE:-ghcr.io/vectorize-io/hindsight}"
HINDSIGHT_TAG="${HINDSIGHT_TAG:-latest}"
RESOLVE_PLATFORM="${RESOLVE_PLATFORM:-linux/amd64}"
CURSOR_INSTALL_URL="${CURSOR_INSTALL_URL:-https://cursor.com/install}"

resolved="$(
  HINDSIGHT_REGISTRY_IMAGE="${HINDSIGHT_REGISTRY_IMAGE}" \
  HINDSIGHT_TAG="${HINDSIGHT_TAG}" \
  RESOLVE_PLATFORM="${RESOLVE_PLATFORM}" \
  CURSOR_INSTALL_URL="${CURSOR_INSTALL_URL}" \
  python3 - <<'PY'
import json
import os
import re
import sys
import urllib.error
import urllib.request

image = os.environ["HINDSIGHT_REGISTRY_IMAGE"]
tag = os.environ["HINDSIGHT_TAG"]
platform = os.environ["RESOLVE_PLATFORM"]
install_url = os.environ["CURSOR_INSTALL_URL"]

if "slim" in tag.lower():
    sys.exit(
        f"refusing slim tag {tag!r}; this image needs the full Hindsight build "
        "so the local embedding and reranker models are included"
    )

if image.count("/") < 1 or "/" not in platform:
    sys.exit(f"invalid image or platform: {image} {platform}")

host, repo = image.split("/", 1)
os_name, arch = platform.split("/", 1)

def fetch(url, headers, method=None):
    headers = {"User-Agent": "curl/8.7.1", **headers}
    request = urllib.request.Request(url, headers=headers, method=method)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read()
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:300]
        sys.exit(f"HTTP {exc.code} for {url}: {detail}")

def shell_quote(value):
    return "'" + value.replace("'", "'\"'\"'") + "'"

print(f"Inspecting {image}:{tag} ({platform})...", file=sys.stderr)
token_url = f"https://{host}/token?service={host}&scope=repository:{repo}:pull"
token = json.loads(fetch(token_url, {"Accept": "application/json"}))["token"]
accept_index = (
    "application/vnd.oci.image.index.v1+json, "
    "application/vnd.docker.distribution.manifest.list.v2+json, "
    "application/vnd.oci.image.manifest.v1+json"
)
index = json.loads(fetch(
    f"https://{host}/v2/{repo}/manifests/{tag}",
    {"Authorization": f"Bearer {token}", "Accept": accept_index},
))

manifest = index
manifests = index.get("manifests")
if manifests:
    digest = ""
    for entry in manifests:
        entry_platform = entry.get("platform") or {}
        if entry_platform.get("os") == os_name and entry_platform.get("architecture") == arch:
            digest = entry.get("digest") or ""
            break
    if not digest:
        sys.exit(f"no {platform} manifest on {image}:{tag}")
    manifest = json.loads(fetch(
        f"https://{host}/v2/{repo}/manifests/{digest}",
        {
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.oci.image.manifest.v1+json",
        },
    ))

config_digest = (manifest.get("config") or {}).get("digest") or ""
if not config_digest:
    sys.exit(f"manifest for {image}:{tag} has no config blob")

config = json.loads(fetch(
    f"https://{host}/v2/{repo}/blobs/{config_digest}",
    {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.oci.image.config.v1+json",
    },
))
labels = (config.get("config") or {}).get("Labels") or {}
hindsight_version = labels.get("org.opencontainers.image.version") or ""
if "slim" in hindsight_version.lower():
    sys.exit(
        f"refusing slim Hindsight version {hindsight_version!r}; "
        "the full image is required for local embedding and reranking"
    )
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:[-.][0-9A-Za-z.]+)?", hindsight_version):
    sys.exit(f"unexpected Hindsight version label: {hindsight_version!r}")

print(f"Reading Cursor agent version from {install_url}...", file=sys.stderr)
script = fetch(install_url, {"Accept": "text/plain"}).decode("utf-8", "replace")
match = re.search(r"https://downloads\.cursor\.com/lab/([^/\"']+)/", script)
if not match:
    sys.exit("Cursor install script did not contain a lab download URL")
cursor_version = match.group(1)
if not re.fullmatch(r"[0-9]{4}\.[0-9]{2}\.[0-9]{2}-[0-9a-f]+", cursor_version):
    sys.exit(f"unexpected Cursor agent version: {cursor_version!r}")

tarball = f"https://downloads.cursor.com/lab/{cursor_version}/linux/x64/agent-cli-package.tar.gz"
if arch == "arm64":
    tarball = f"https://downloads.cursor.com/lab/{cursor_version}/linux/arm64/agent-cli-package.tar.gz"
fetch(tarball, {}, method="HEAD")

revision = labels.get("org.opencontainers.image.revision") or ""
print(
    f"Resolved {image}:{tag} -> hindsight {hindsight_version} ({revision or 'no revision'}), "
    f"cursor-agent {cursor_version}",
    file=sys.stderr,
)

print(f"HINDSIGHT_VERSION={shell_quote(hindsight_version)}")
print(f"HINDSIGHT_REGISTRY_IMAGE={shell_quote(image)}")
print(f"HINDSIGHT_TAG={shell_quote(tag)}")
print(f"CURSOR_AGENT_VERSION={shell_quote(cursor_version)}")
PY
)" || exit 1
eval "${resolved}"

print_build_arg_file() {
  printf 'RESOLVED_BY_SCRIPT=true\n'
  printf 'HINDSIGHT_VERSION=%s\n' "${HINDSIGHT_VERSION}"
  printf 'CURSOR_AGENT_VERSION=%s\n' "${CURSOR_AGENT_VERSION}"
}

case "${1:-}" in
  --export)
    printf 'export HINDSIGHT_REGISTRY_IMAGE=%q\n' "${HINDSIGHT_REGISTRY_IMAGE}"
    printf 'export HINDSIGHT_TAG=%q\n' "${HINDSIGHT_TAG}"
    printf 'export HINDSIGHT_VERSION=%q\n' "${HINDSIGHT_VERSION}"
    printf 'export CURSOR_AGENT_VERSION=%q\n' "${CURSOR_AGENT_VERSION}"
    ;;
  --build-arg-file)
    print_build_arg_file
    ;;
  *)
    export HINDSIGHT_REGISTRY_IMAGE HINDSIGHT_TAG HINDSIGHT_VERSION CURSOR_AGENT_VERSION
    ;;
esac
