# Bazel + Nx Hybrid Workspace

Quick POC showing how to call Nx from Bazel and how to get Nx to bust its cache when files outside the Nx workspace change (in this case, Java source files managed by Bazel).

The Java stuff here is just a hello-world from the [Bazel Java tutorial](https://bazel.build/start/java) — don't read too much into it. The interesting bits are the genrule bridge and the Nx runtime inputs config.

## Setup

```bash
mise install                # grabs Java 21 + Bazelisk
cd ui && npm install && cd ..

# build everything
mise x -- bazel build //:ProjectRunner //:ui_build
```

If you've got `mise activate` in your shell you can drop the `mise x --` prefix.

## Repo layout

```
.
├── BUILD                   # java targets + genrules that shell out to nx
├── MODULE.bazel
├── .bazelignore            # keeps bazel away from ui/node_modules
├── mise.toml               # java 21, bazelisk
├── tools/
│   └── nx.sh               # wrapper script that bazel calls
├── src/main/java/…         # boring hello-world java app
└── ui/                     # nx angular workspace
    ├── nx.json             # this is where the runtime inputs magic lives
    ├── src/
    └── e2e/
```

---

## How Bazel calls Nx

Bazel doesn't know anything about node, npm, or Nx. And it runs everything in a sandboxed execroot with a mostly-empty PATH. So we need a few workarounds.

### .bazelignore

First, tell Bazel to completely ignore `ui/`. If you don't, it'll crawl into `node_modules` and choke on BUILD files that npm packages sometimes ship.

```
ui
```

### genrules with `local = True`

In the root `BUILD` file there are genrule targets that shell out to Nx:

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

`local = True` is the key bit. Without it, Bazel sandboxes the action and Nx can't see `node_modules` or any of the UI source files. With it, the genrule runs directly on your machine with full filesystem access.

The `.stamp` file is just a dummy output — Bazel requires genrules to produce something. The actual build output ends up in `ui/dist/`. Since local genrules always re-run, all caching happens on the Nx side.

There are four of these:

```bash
bazel build //:ui_build   # nx build ui
bazel build //:ui_test    # nx test ui
bazel build //:ui_lint    # nx lint ui
bazel build //:ui_e2e     # nx e2e e2e
```

### tools/nx.sh

The wrapper script deals with two annoying things about running inside a Bazel genrule:

1. **Finding the workspace.** Genrules run from the execroot, not your repo. The script resolves its own real path via symlinks to figure out where the actual source tree is. (`bazel run` sets `BUILD_WORKSPACE_DIRECTORY` but `bazel build` doesn't, so we need the fallback.)

2. **Restoring PATH.** Bazel strips env vars for hermeticity, so `npx` isn't available. The script calls mise by absolute path to put node back on PATH.

---

## Getting Nx to watch files outside its workspace

This is the part I actually wanted to demo. Nx only hashes files inside its own workspace root (`ui/`). If you change a Java file in the parent directory, Nx has no idea and happily serves a stale cached build.

### Runtime inputs

Nx has this `runtime` input type that lets you run an arbitrary shell command and include its output in the task hash. In `ui/nx.json`:

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

The `javaSource` input finds all `.java` files in `../src`, hashes their contents, sorts for determinism, and collapses it into one hash. If any java file changes, the hash changes, and Nx treats the build/test/e2e as a cache miss.

You wire it up by adding `"javaSource"` to the `inputs` array on whatever targets should care about Java changes.

### Why not just use file globs?

I tried `{workspaceRoot}/../src/**/*.java` first. Doesn't work — Nx won't resolve globs outside the workspace root. `runtime` is the only way to reach external files.

### Why disable the daemon?

The Nx daemon caches runtime input results between runs for performance. Problem is, it's too aggressive about it — it won't re-run the `find`/`shasum` command even when the Java files have changed. Turning off the daemon (`"useDaemonProcess": false`) forces Nx to re-evaluate runtime inputs every time.

You pay ~200ms in startup time. Worth it for correct cache behavior.

### This works for anything, not just Java

Same pattern works for any files outside the workspace:

```json
"namedInputs": {
  "protoFiles": [
    { "runtime": "find ../proto -name '*.proto' -exec shasum {} + | sort | shasum" }
  ],
  "goModules": [
    { "runtime": "shasum ../go.sum" }
  ]
}
```

---

## How caching works end-to-end

| Layer | Tool | Caches | Invalidation |
|-------|------|--------|-------------|
| Outer | Bazel | Java compilation | automatic (content-addressed) |
| Inner | Nx | Angular build/test/lint/e2e | hash-based, with runtime inputs for java files |

Bazel always re-runs the local genrules. Nx decides whether to actually rebuild or serve from cache. The runtime input on `javaSource` is what connects the two — without it, Nx would never know the Java side changed.

---

## Troubleshooting

- **`bazel: command not found`** — run `mise activate` or prefix with `mise x --`
- **`ui/node_modules not found`** — `cd ui && npm install`
- **Nx not busting cache after java changes** — check that `"useDaemonProcess": false` is in `ui/nx.json`, or run `npx nx reset` in `ui/` to clear everything
- **Bazel errors about stuff in node_modules** — make sure `ui` is in `.bazelignore`
