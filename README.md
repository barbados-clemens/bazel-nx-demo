# Bazel + Nx Hybrid Workspace

This project demonstrates a hybrid build system where Bazel manages Java targets and orchestrates an Angular frontend built by Nx. The two build systems are connected so that Bazel can invoke Nx commands, and Nx automatically invalidates its cache when Java source files change.

## Project structure

```
.
├── .bazelignore            # Tells Bazel to ignore ui/
├── .bazelversion           # Pins Bazel version (via Bazelisk)
├── BUILD                   # Java targets + Nx genrule targets
├── MODULE.bazel            # Bazel module dependencies
├── mise.toml               # Toolchain definitions (Java, Bazelisk)
├── tools/
│   ├── BUILD               # Exports nx.sh to Bazel
│   └── nx.sh               # Shell wrapper Bazel uses to call Nx
├── src/main/java/com/example/
│   ├── Greeting.java       # Shared library
│   ├── ProjectRunner.java  # CLI entry point
│   └── cmdline/
│       ├── BUILD
│       └── Runner.java     # Alternative entry point
└── ui/                     # Nx Angular workspace (standalone)
    ├── nx.json             # Nx config with Java source tracking
    ├── src/                # Angular app
    └── e2e/                # Playwright e2e tests
```

## Prerequisites

The only manual requirement is [mise](https://mise.jdx.dev/) (installed via Homebrew: `brew install mise`). Everything else is managed by mise.

## Getting started

```bash
# Install toolchains (Java 21, Bazelisk)
mise install

# Install UI dependencies
cd ui && npm install && cd ..

# Build everything
mise x -- bazel build //:ProjectRunner //:ui_build

# Run the Java app
mise x -- bazel run //:ProjectRunner
```

> **Why `mise x --`?** Bazel and Java are installed via mise and may not be on your shell PATH unless mise is activated. `mise x --` runs a command with the correct tool versions on PATH. If you have `mise activate` in your shell profile, you can call `bazel` directly.

---

## Part 1: Toolchain management with mise

**File:** `mise.toml`

```toml
[tools]
bazelisk = "latest"
java = "21"
```

### What it does

Declares the exact tool versions needed to work in this repository. When you run `mise install`, mise downloads Java 21 and Bazelisk (a version-aware Bazel launcher) and makes them available in this directory.

### Why mise

- Reproducible toolchains per-project without polluting the system
- Bazelisk is preferred over installing Bazel directly because it reads `.bazelversion` and automatically downloads the correct Bazel release
- Java 21 is an LTS release with broad `rules_java` support

### Why Bazelisk instead of Bazel

Bazelisk is a thin launcher that reads `.bazelversion` and fetches the matching Bazel binary. This means every developer and CI job uses the exact same Bazel version without manual coordination. mise installs the `bazelisk` binary; a symlink maps `bazel` to `bazelisk` so all standard `bazel` commands work transparently.

---

## Part 2: Bazel Java workspace

**Files:** `MODULE.bazel`, `.bazelversion`, `BUILD`, `src/main/java/com/example/cmdline/BUILD`

### MODULE.bazel

```python
bazel_dep(name = "rules_java", version = "9.0.3")
```

This declares the workspace as a Bazel module (Bzlmod) and pulls in `rules_java` for `java_binary` and `java_library` rules. Bzlmod is Bazel's modern dependency system, replacing the legacy `WORKSPACE` file.

### Root BUILD

The root BUILD file defines two Java targets and four Nx integration targets (covered in Part 4):

```python
java_binary(
    name = "ProjectRunner",
    srcs = ["src/main/java/com/example/ProjectRunner.java"],
    main_class = "com.example.ProjectRunner",
    deps = [":greeter"],
)

java_library(
    name = "greeter",
    srcs = ["src/main/java/com/example/Greeting.java"],
)
```

- `greeter` is a `java_library` — a reusable compilation unit with `public` visibility so other packages can depend on it
- `ProjectRunner` is a `java_binary` that depends on `greeter` and produces an executable JAR

### Sub-package: cmdline

```python
# src/main/java/com/example/cmdline/BUILD
java_binary(
    name = "runner",
    srcs = ["Runner.java"],
    main_class = "com.example.cmdline.Runner",
    deps = ["//:greeter"],
)
```

This demonstrates Bazel's package system. The `cmdline/` directory has its own BUILD file and references the root `greeter` library with the label `//:greeter`. Bazel enforces visibility between packages — `greeter` has `default_visibility = ["//visibility:public"]` in the root package so any package can use it.

### Building and running

```bash
# Build both targets
mise x -- bazel build //:ProjectRunner //src/main/java/com/example/cmdline:runner

# Run
mise x -- bazel run //:ProjectRunner
mise x -- bazel run //src/main/java/com/example/cmdline:runner
```

---

## Part 3: Angular UI via Nx

**Directory:** `ui/`

The `ui/` directory is a standalone Nx Angular workspace created with:

```bash
npx create-nx-workspace ui --preset=angular-standalone --appName=demo --style=css --ssr=false --nxCloud=skip
```

It contains a standard Angular application with Playwright e2e tests, ESLint, and Vitest for unit tests. Nx manages building, testing, and caching for the frontend.

### Why a separate workspace

Bazel and Nx have fundamentally different models:

- **Bazel** uses hermetic, sandboxed builds with content-addressed caching. It needs to know every input file.
- **Nx** uses workspace-level task orchestration with hash-based caching. It understands `node_modules`, Angular CLI, and the JavaScript ecosystem natively.

Trying to make Bazel build Angular directly (via `rules_nodejs` or similar) is complex, fragile, and loses the benefits of Nx's Angular-specific optimizations. Keeping them as separate workspaces and bridging them is more practical.

### .bazelignore

```
ui
```

The `ui/` directory must be excluded from Bazel's package discovery. Without this, Bazel would try to traverse `node_modules/` (tens of thousands of files), find conflicting BUILD files from npm packages, and fail. `.bazelignore` tells Bazel to pretend the directory doesn't exist.

---

## Part 4: Bazel orchestrates Nx

**Files:** `BUILD` (genrule targets), `tools/nx.sh`, `tools/BUILD`

### The bridge: genrule targets

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

Four genrule targets exist: `ui_build`, `ui_test`, `ui_lint`, and `ui_e2e`. Each one:

1. Calls `tools/nx.sh` with the appropriate Nx target and project name
2. Touches a `.stamp` file on success (genrules must produce output files)

**Why `local = True`?** Bazel normally runs actions in a sandbox with only declared inputs available. But Nx needs access to the full `ui/` directory (including `node_modules/`), which isn't tracked by Bazel. `local = True` runs the action directly on the host machine with full filesystem access.

**Why `tags = ["no-sandbox"]`?** Belt-and-suspenders with `local = True` to ensure no sandboxing is attempted.

**Why stamp files?** Bazel genrules require at least one declared output. The stamp file is a zero-byte marker that signals "this action ran successfully." The real build output lives in `ui/dist/`.

### Available targets

```bash
mise x -- bazel build //:ui_build   # nx build ui (Angular production build)
mise x -- bazel build //:ui_test    # nx test ui (Vitest unit tests)
mise x -- bazel build //:ui_lint    # nx lint ui (ESLint)
mise x -- bazel build //:ui_e2e     # nx e2e e2e (Playwright)
```

### The wrapper script: tools/nx.sh

```bash
#!/usr/bin/env bash
set -euo pipefail

NX_TARGET="${1:?Usage: nx.sh <target> <project>}"
NX_PROJECT="${2:?Usage: nx.sh <target> <project>}"
shift 2

if [ -n "${BUILD_WORKSPACE_DIRECTORY:-}" ]; then
  WORKSPACE_ROOT="${BUILD_WORKSPACE_DIRECTORY}"
else
  SCRIPT_REAL="$(realpath "$0")"
  WORKSPACE_ROOT="$(cd "$(dirname "${SCRIPT_REAL}")/.." && pwd)"
fi

UI_DIR="${WORKSPACE_ROOT}/ui"
cd "${UI_DIR}"

MISE_BIN="/opt/homebrew/bin/mise"
if [ -x "${MISE_BIN}" ]; then
  eval "$("${MISE_BIN}" env -C "${WORKSPACE_ROOT}" 2>/dev/null)" || true
fi

exec npx nx "${NX_TARGET}" "${NX_PROJECT}" "$@"
```

This script solves three problems:

1. **Workspace root resolution.** When Bazel runs a genrule, the working directory is the *execroot* — a synthetic directory Bazel creates, not your source tree. The script resolves the real workspace root by following symlinks back from the script's actual location on disk. For `bazel run` (as opposed to `bazel build`), Bazel sets `BUILD_WORKSPACE_DIRECTORY` which is used directly.

2. **PATH bootstrapping.** Bazel strips most environment variables for hermeticity, so tools installed by mise (like `node`/`npx`) aren't on PATH. The script explicitly invokes mise to reconstruct the correct PATH before calling `npx`.

3. **Single entry point.** All four genrule targets use the same script with different arguments, keeping the BUILD file DRY.

---

## Part 5: Nx cache invalidation on Java changes

**File:** `ui/nx.json` (the `javaSource` named input)

### The problem

Nx only watches files inside its own workspace (`ui/`). If the Java backend changes in a way that affects the frontend (e.g., API contract changes, shared resources), Nx has no way to know and will serve stale cached results for `build`, `test`, and `e2e` targets.

### The solution: runtime inputs

```json
{
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

Nx supports `runtime` inputs — shell commands whose stdout is included in the task hash. The `javaSource` input runs `find` + `shasum` over all `.java` files in the parent directory. The pipeline is:

1. `find ../src -name '*.java'` — discovers all Java source files
2. `-exec shasum {} +` — computes a SHA-1 hash of each file's contents
3. `sort` — deterministic ordering (find output order isn't guaranteed)
4. `shasum` — combines into a single hash

When any `.java` file is added, removed, or modified, this hash changes, and Nx treats the affected targets as cache misses.

### Why `useDaemonProcess: false`

```json
{
  "useDaemonProcess": false
}
```

The Nx daemon caches runtime input results aggressively for performance. This means it may not re-evaluate the `find`/`shasum` command between runs, causing stale cache hits even after Java files change. Disabling the daemon forces Nx to re-run the runtime command on every invocation.

The trade-off is slightly slower Nx startup (~200ms), but cache correctness is more important for a cross-build-system integration like this.

### Why not file globs?

Nx's file-based inputs (`{workspaceRoot}/**/*.java`) only work for files inside the Nx workspace root. The Java sources live in the parent directory, outside of `ui/`. The `runtime` input is the only mechanism that can reach files outside the workspace boundary.

---

## Caching model

This setup creates a two-layer caching architecture:

| Layer | Tool | Scope | Invalidation |
|-------|------|-------|-------------|
| Outer | Bazel | Java compilation, orchestration | Content-addressed (automatic) |
| Inner | Nx | Angular build, test, lint, e2e | Hash-based with runtime inputs |

- **Bazel caching** handles Java targets natively. The genrule targets for Nx are `local = True`, so Bazel doesn't cache them — it always re-runs the genrule, which then hits or misses the Nx cache.
- **Nx caching** handles Angular targets. The `javaSource` runtime input bridges the boundary so Nx knows when Java changes affect frontend tasks.

This means `bazel build //:ui_build` always delegates to Nx, and Nx decides whether to rebuild or serve from cache. The stamp file is always touched, so Bazel considers the action successful either way.

---

## Troubleshooting

### `bazel: command not found`

Ensure mise is activated in your shell (`eval "$(mise activate zsh)"` in `.zshrc`) or prefix commands with `mise x --`.

### `ui/node_modules not found`

Run `cd ui && npm install`.

### Nx cache not invalidating after Java changes

Verify the daemon is disabled (`"useDaemonProcess": false` in `ui/nx.json`). You can also force a clean slate with `npx nx reset` from the `ui/` directory.

### Bazel tries to process ui/node_modules

Ensure `ui` is listed in `.bazelignore` at the workspace root.
