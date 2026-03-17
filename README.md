# Bazel + Nx Hybrid Workspace

A demo of calling Nx from Bazel and configuring Nx to invalidate its cache when files outside the Nx workspace change. The Java backend is intentionally minimal — the focus is the integration layer between the two build systems.

## Project structure

```
.
├── BUILD                   # Java targets + genrule targets that call Nx
├── MODULE.bazel            # Bazel module config
├── .bazelignore            # Excludes ui/ from Bazel's package discovery
├── mise.toml               # Toolchain (Java 21, Bazelisk)
├── tools/
│   ├── BUILD
│   └── nx.sh              # Wrapper script Bazel uses to invoke Nx
├── src/main/java/…         # Minimal Java app (Bazel-managed)
└── ui/                     # Nx Angular workspace
    ├── nx.json            # Runtime inputs for cross-boundary cache invalidation
    ├── src/               # Angular app
    └── e2e/               # Playwright e2e tests
```

## Getting started

```bash
mise install                # Install Java 21 + Bazelisk
cd ui && npm install && cd ..

# Build Java + Angular in one command
mise x -- bazel build //:ProjectRunner //:ui_build
```

> `mise x --` ensures mise-managed tools are on PATH. If mise is activated in your shell, you can call `bazel` directly.

---

## Calling Nx from Bazel

The core challenge: Bazel runs actions in an isolated *execroot* with a stripped-down environment. It doesn't know about `node_modules`, `npx`, or anything in the Nx workspace. Three things are needed to bridge this gap.

### 1. Exclude ui/ from Bazel

**File:** `.bazelignore`

```
ui
```

Bazel must not try to traverse `ui/`. Without this, it would scan `node_modules/` (tens of thousands of files), find conflicting BUILD files from npm packages, and fail.

### 2. genrule targets with `local = True`

**File:** `BUILD`

```python
genrule(
    name = "ui_build",
    outs = ["ui_build.stamp"],
    cmd = "$(location //tools:nx.sh) build ui && touch $@",
    local = True,
    tags = ["no-sandbox"],
    tools = ["//tools:nx.sh"],
)
```

Four genrule targets delegate to Nx: `ui_build`, `ui_test`, `ui_lint`, `ui_e2e`.

**`local = True`** is critical. Bazel normally sandboxes actions, making only declared inputs available. Nx needs the full `ui/` directory (source files, `node_modules/`, config), none of which Bazel tracks. `local = True` runs the action directly on the host filesystem. The `no-sandbox` tag reinforces this.

**Stamp files** exist because genrules must declare at least one output. The stamp is a zero-byte marker — the real build output lives in `ui/dist/`. Since Bazel always re-runs local genrules, caching is handled entirely by Nx.

```bash
mise x -- bazel build //:ui_build   # nx build ui
mise x -- bazel build //:ui_test    # nx test ui
mise x -- bazel build //:ui_lint    # nx lint ui
mise x -- bazel build //:ui_e2e     # nx e2e e2e
```

### 3. The wrapper script

**File:** `tools/nx.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

NX_TARGET="${1:?Usage: nx.sh <target> <project>}"
NX_PROJECT="${2:?Usage: nx.sh <target> <project>}"
shift 2

# Resolve workspace root: BUILD_WORKSPACE_DIRECTORY is set by `bazel run`,
# but not by `bazel build` (genrule). Fall back to resolving symlinks.
if [ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]; then
  WORKSPACE_ROOT="${BUILD_WORKSPACE_DIRECTORY}"
else
  SCRIPT_REAL="$(realpath "$0")"
  WORKSPACE_ROOT="$(cd "$(dirname "${SCRIPT_REAL}")/.." && pwd)"
fi

UI_DIR="${WORKSPACE_ROOT}/ui"
cd "${UI_DIR}"

# Bazel strips PATH for hermeticity — restore mise-managed tools.
MISE_BIN="/opt/homebrew/bin/mise"
if [ -x "${MISE_BIN}" ]; then
  eval "$("${MISE_BIN}" env -C "${WORKSPACE_ROOT}" 2>/dev/null)" || true
fi

exec npx nx "${NX_TARGET}" "${NX_PROJECT}" "$@"
```

This script solves two problems that arise because Bazel's execution environment is intentionally hostile to non-hermetic tools:

**Workspace root resolution.** Genrules run from the execroot, not your source tree. The script follows symlinks from its own real path back to the actual workspace. `bazel run` sets `BUILD_WORKSPACE_DIRECTORY` directly, but `bazel build` (which is what genrules use) does not — hence the fallback.

**PATH bootstrapping.** Bazel strips environment variables, so `node`/`npx` aren't available. The script calls mise directly by absolute path to reconstruct the correct PATH before invoking Nx.

---

## Nx runtime inputs: tracking files outside the workspace

This is the most interesting part of the integration. Nx only watches files inside its own workspace root (`ui/`). But when Java source files change, the Angular build and e2e tests may need to re-run (e.g., if the frontend consumes an API whose contract changed). Without explicit configuration, Nx would serve stale cached results.

### The mechanism: `runtime` inputs in `namedInputs`

**File:** `ui/nx.json`

```json
{
  "useDaemonProcess": false,
  "namedInputs": {
    "javaSource": [
      {
        "runtime": "find ../src -name '*.java' -exec shasum {} + | sort | shasum"
      }
    ]
  },
  "targetDefaults": {
    "@angular/build:application": {
      "inputs": ["production", "^production", "javaSource"]
    },
    "@angular/build:unit-test": {
      "inputs": ["default", "^production", "javaSource"]
    },
    "e2e": {
      "inputs": ["default", "^production", "javaSource"]
    }
  }
}
```

Nx `runtime` inputs run a shell command and include its stdout in the task hash. The `javaSource` named input works like this:

1. `find ../src -name '*.java'` — discovers all Java source files (outside `ui/`)
2. `-exec shasum {} +` — hashes each file's contents
3. `sort` — deterministic ordering (find doesn't guarantee order)
4. `shasum` — collapses everything into a single hash

When any `.java` file is added, removed, or modified, the combined hash changes and Nx treats `build`, `test`, and `e2e` as cache misses.

The `javaSource` input is added to `targetDefaults` for each executor that should be sensitive to Java changes. You can add it to as many or as few targets as needed.

### Why `runtime` instead of file globs?

Nx's file-based inputs like `{workspaceRoot}/../src/**/*.java` do not work — Nx only resolves globs within its own workspace root. The `runtime` input is the only built-in mechanism that can reach files outside the workspace boundary.

### Why `useDaemonProcess: false`?

The Nx daemon caches runtime input results aggressively for performance. When the daemon is running, it may not re-evaluate the `find`/`shasum` command between invocations, causing stale cache hits even after Java files change.

Setting `useDaemonProcess: false` forces Nx to re-run all runtime commands on every invocation. The trade-off is ~200ms slower startup, but cache correctness matters more in a cross-system integration.

### Adapting this pattern

The runtime input approach is not specific to Java. You can track any external files:

```json
"namedInputs": {
  "protoFiles": [
    { "runtime": "find ../proto -name '*.proto' -exec shasum {} + | sort | shasum" }
  ],
  "goModules": [
    { "runtime": "shasum ../go.sum" }
  ],
  "dockerConfig": [
    { "runtime": "shasum ../Dockerfile ../docker-compose.yml" }
  ]
}
```

Any change to the tracked files produces a different hash, invalidating whichever Nx targets include that named input.

---

## Caching model

| Layer | Tool | What it caches | Invalidation |
|-------|------|----------------|-------------|
| Outer | Bazel | Java compilation | Content-addressed (automatic) |
| Inner | Nx | Angular build, test, lint, e2e | Hash-based with runtime inputs |

Bazel always re-runs the local genrules (they're non-hermetic by design). Nx decides whether to rebuild or serve from cache. This means caching for the Angular side is entirely controlled by Nx's `inputs` configuration — the runtime `javaSource` input is what makes the cross-boundary invalidation work.

---

## Troubleshooting

**`bazel: command not found`** — Activate mise in your shell (`eval "$(mise activate zsh)"`) or prefix commands with `mise x --`.

**`ui/node_modules not found`** — Run `cd ui && npm install`.

**Nx cache not invalidating after Java changes** — Verify `"useDaemonProcess": false` is set in `ui/nx.json`. Force a clean slate with `npx nx reset` from `ui/`.

**Bazel tries to process ui/node_modules** — Ensure `ui` is listed in `.bazelignore`.
