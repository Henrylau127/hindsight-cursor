#!/usr/bin/env bash
# Resolve published Hindsight and Cursor agent versions and decide whether a
# new image build is needed. Compares against .ci/last-built-version, which
# CI restores from the Actions cache.
#
# Usage:
#   bash ./scripts/check-build-version.sh
#   FORCE_BUILD=true bash ./scripts/check-build-version.sh
#
# Outputs (when GITHUB_OUTPUT is set):
#   build_needed, hindsight_version, cursor_agent_version, image_tag
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

LAST_BUILT_FILE="${LAST_BUILT_FILE:-${ROOT_DIR}/.ci/last-built-version}"
BUILD_ARG_FILE="${BUILD_ARG_FILE:-}"
FORCE_BUILD="${FORCE_BUILD:-false}"
RESOLVE_PLATFORM="${RESOLVE_PLATFORM:-linux/amd64}"

eval "$(RESOLVE_PLATFORM="${RESOLVE_PLATFORM}" bash "${SCRIPT_DIR}/resolve-build-versions.sh" --export)"

if [ -z "${BUILD_ARG_FILE}" ]; then
  BUILD_ARG_FILE="$(mktemp)"
  trap 'rm -f "${BUILD_ARG_FILE}"' EXIT
fi

# Write the build args from this snapshot. A second resolve could observe a
# newer Cursor or Hindsight release than the versions compared below.
{
  printf 'RESOLVED_BY_SCRIPT=true\n'
  printf 'HINDSIGHT_VERSION=%s\n' "${HINDSIGHT_VERSION}"
  printf 'CURSOR_AGENT_VERSION=%s\n' "${CURSOR_AGENT_VERSION}"
} >"${BUILD_ARG_FILE}"

IMAGE_TAG="${HINDSIGHT_VERSION}-cursor-${CURSOR_AGENT_VERSION}"

LAST_HINDSIGHT_VERSION=""
LAST_CURSOR_AGENT_VERSION=""
LAST_UPSTREAM=""
if [ -f "${LAST_BUILT_FILE}" ]; then
  while IFS= read -r line || [ -n "${line}" ]; do
    [ -z "${line}" ] && continue
    key="${line%%=*}"
    value="${line#*=}"
    case "${key}" in
      HINDSIGHT_VERSION) LAST_HINDSIGHT_VERSION="${value}" ;;
      CURSOR_AGENT_VERSION) LAST_CURSOR_AGENT_VERSION="${value}" ;;
      UPSTREAM) LAST_UPSTREAM="${value}" ;;
    esac
  done <"${LAST_BUILT_FILE}"
fi

UPSTREAM="${HINDSIGHT_REGISTRY_IMAGE}:${HINDSIGHT_TAG}"
BUILD_NEEDED="true"
SKIP_REASON=""

if [ "${FORCE_BUILD}" = "true" ]; then
  SKIP_REASON="force_build enabled"
elif [ -n "${LAST_HINDSIGHT_VERSION}" ] \
  && [ "${LAST_HINDSIGHT_VERSION}" = "${HINDSIGHT_VERSION}" ] \
  && [ "${LAST_CURSOR_AGENT_VERSION}" = "${CURSOR_AGENT_VERSION}" ] \
  && [ "${LAST_UPSTREAM}" = "${UPSTREAM}" ]; then
  BUILD_NEEDED="false"
  SKIP_REASON="hindsight ${HINDSIGHT_VERSION} and cursor-agent ${CURSOR_AGENT_VERSION} already built"
else
  changes=""
  if [ -z "${LAST_HINDSIGHT_VERSION}" ] && [ -z "${LAST_CURSOR_AGENT_VERSION}" ]; then
    changes="no previous build recorded"
  else
    if [ "${LAST_UPSTREAM}" != "${UPSTREAM}" ]; then
      changes="upstream ${LAST_UPSTREAM:-none} -> ${UPSTREAM}"
    fi
    if [ "${LAST_HINDSIGHT_VERSION}" != "${HINDSIGHT_VERSION}" ]; then
      changes="${changes:+${changes}; }hindsight ${LAST_HINDSIGHT_VERSION:-none} -> ${HINDSIGHT_VERSION}"
    fi
    if [ "${LAST_CURSOR_AGENT_VERSION}" != "${CURSOR_AGENT_VERSION}" ]; then
      changes="${changes:+${changes}; }cursor-agent ${LAST_CURSOR_AGENT_VERSION:-none} -> ${CURSOR_AGENT_VERSION}"
    fi
  fi
  SKIP_REASON="${changes}"
fi

echo "Resolved ${UPSTREAM} (${HINDSIGHT_VERSION}) + cursor-agent ${CURSOR_AGENT_VERSION}"
if [ -n "${LAST_HINDSIGHT_VERSION}" ] || [ -n "${LAST_CURSOR_AGENT_VERSION}" ]; then
  echo "Last built: hindsight ${LAST_HINDSIGHT_VERSION:-none}, cursor-agent ${LAST_CURSOR_AGENT_VERSION:-none}, upstream ${LAST_UPSTREAM:-none}"
else
  echo "Last built: (none)"
fi

if [ "${BUILD_NEEDED}" = "true" ]; then
  echo "Build needed: ${SKIP_REASON}"
else
  echo "Build skipped: ${SKIP_REASON}"
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    printf 'build_needed=%s\n' "${BUILD_NEEDED}"
    printf 'hindsight_version=%s\n' "${HINDSIGHT_VERSION}"
    printf 'hindsight_registry_image=%s\n' "${HINDSIGHT_REGISTRY_IMAGE}"
    printf 'hindsight_tag=%s\n' "${HINDSIGHT_TAG}"
    printf 'cursor_agent_version=%s\n' "${CURSOR_AGENT_VERSION}"
    printf 'image_tag=%s\n' "${IMAGE_TAG}"
    printf 'last_hindsight_version=%s\n' "${LAST_HINDSIGHT_VERSION}"
    printf 'last_cursor_agent_version=%s\n' "${LAST_CURSOR_AGENT_VERSION}"
    printf 'skip_reason=%s\n' "${SKIP_REASON}"
    printf 'build_arg_file=%s\n' "${BUILD_ARG_FILE}"
  } >>"${GITHUB_OUTPUT}"
fi
