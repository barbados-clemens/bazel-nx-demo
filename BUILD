load("@rules_java//java:defs.bzl", "java_binary", "java_library")

package(default_visibility = ["//visibility:public"])

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

# --- Nx / Angular UI targets ---
# These genrules delegate to Nx for the Angular app in ui/.
# They run as local actions since ui/ is in .bazelignore and
# Nx manages its own caching.

genrule(
    name = "ui_build",
    outs = ["ui_build.stamp"],
    cmd = "$(location //tools:nx.sh) build ui && touch $@",
    local = True,
    tags = ["no-sandbox"],
    tools = ["//tools:nx.sh"],
)

genrule(
    name = "ui_test",
    outs = ["ui_test.stamp"],
    cmd = "$(location //tools:nx.sh) test ui && touch $@",
    local = True,
    tags = ["no-sandbox"],
    tools = ["//tools:nx.sh"],
)

genrule(
    name = "ui_lint",
    outs = ["ui_lint.stamp"],
    cmd = "$(location //tools:nx.sh) lint ui && touch $@",
    local = True,
    tags = ["no-sandbox"],
    tools = ["//tools:nx.sh"],
)

genrule(
    name = "ui_e2e",
    outs = ["ui_e2e.stamp"],
    cmd = "$(location //tools:nx.sh) e2e e2e && touch $@",
    local = True,
    tags = ["no-sandbox"],
    tools = ["//tools:nx.sh"],
)
