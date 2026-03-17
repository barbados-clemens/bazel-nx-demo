#!/usr/bin/env bash
# Wrapper script for Bazel to invoke Nx CLI targets.
# Usage: nx.sh <nx-target> <nx-project> [extra-args...]
set -euo pipefail

NX_TARGET="${1:?Usage: nx.sh <target> <project>}"
NX_PROJECT="${2:?Usage: nx.sh <target> <project>}"
shift 2

# When run from Bazel genrule, we're in the execroot.
# Resolve the real workspace root by following the bazel-out symlink
# or using BUILD_WORKSPACE_DIRECTORY if available (bazel run).
if [ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]; then
  WORKSPACE_ROOT="${BUILD_WORKSPACE_DIRECTORY}"
else
  # In a genrule, pwd is the execroot. The workspace source is
  # reachable by resolving the symlinked source tree.
  SCRIPT_REAL="$(realpath "$0")"
  WORKSPACE_ROOT="$(cd "$(dirname "${SCRIPT_REAL}")/.." && pwd)"
fi

UI_DIR="${WORKSPACE_ROOT}/ui"

if [ ! -d "${UI_DIR}/node_modules" ]; then
  echo "ERROR: ui/node_modules not found. Run 'npm install' in ui/ first." >&2
  exit 1
fi

cd "${UI_DIR}"

# Ensure mise-managed tools are on PATH (Bazel strips the environment).
MISE_BIN="/opt/homebrew/bin/mise"
if [ -x "${MISE_BIN}" ]; then
  eval "$("${MISE_BIN}" env -C "${WORKSPACE_ROOT}" 2>/dev/null)" || true
fi

exec npx nx "${NX_TARGET}" "${NX_PROJECT}" "$@"
