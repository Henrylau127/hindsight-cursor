#!/usr/bin/env bash
# Resolve versions, build linux/amd64, and check cursor-agent is the pinned build.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

IMAGE="${IMAGE:-hindsight-cursor:verify}"
PLATFORM="${PLATFORM:-linux/amd64}"

if [ -n "${BUILD_ARG_FILE:-}" ] && [ -f "${BUILD_ARG_FILE}" ]; then
  echo "==> Using pre-resolved build args from ${BUILD_ARG_FILE}"
else
  BUILD_ARG_FILE="$(mktemp)"
  trap 'rm -f "${BUILD_ARG_FILE}"' EXIT
  RESOLVE_PLATFORM="${PLATFORM}" bash "${SCRIPT_DIR}/resolve-build-versions.sh" --build-arg-file >"${BUILD_ARG_FILE}"
fi

HINDSIGHT_VERSION=""
CURSOR_AGENT_VERSION=""
BUILD_ARGS=()
while IFS= read -r line || [ -n "${line}" ]; do
  [ -z "${line}" ] && continue
  BUILD_ARGS+=(--build-arg "${line}")
  key="${line%%=*}"
  value="${line#*=}"
  case "${key}" in
    HINDSIGHT_VERSION) HINDSIGHT_VERSION="${value}" ;;
    CURSOR_AGENT_VERSION) CURSOR_AGENT_VERSION="${value}" ;;
  esac
done <"${BUILD_ARG_FILE}"

: "${HINDSIGHT_VERSION:?Failed to resolve HINDSIGHT_VERSION}"
: "${CURSOR_AGENT_VERSION:?Failed to resolve CURSOR_AGENT_VERSION}"

echo "==> Resolved hindsight ${HINDSIGHT_VERSION} with cursor-agent ${CURSOR_AGENT_VERSION}"

echo "==> Build for ${PLATFORM}"
docker build \
  --platform "${PLATFORM}" \
  "${BUILD_ARGS[@]}" \
  -t "${IMAGE}" \
  "${ROOT_DIR}"

echo "==> Verify cursor-agent version and full-image models"
docker run --rm --platform "${PLATFORM}" --entrypoint bash "${IMAGE}" -c "
  set -eu
  cursor-agent --version | grep -F '${CURSOR_AGENT_VERSION}'
  test -d /home/hindsight/.cache/huggingface/hub/models--BAAI--bge-small-en-v1.5
  test -d /home/hindsight/.cache/huggingface/hub/models--cross-encoder--ms-marco-MiniLM-L-6-v2
"

echo "Checks passed (hindsight ${HINDSIGHT_VERSION}, cursor-agent ${CURSOR_AGENT_VERSION}, local embedding and reranker present)."
