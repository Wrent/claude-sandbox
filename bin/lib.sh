#!/bin/bash
# Shared helpers for claude-sandbox / claude-sandbox-proxy / grant-secret.sh.
set -euo pipefail

SANDBOX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE_NAME="claude-sandbox:latest"
NETWORK_NAME="claude-sandbox-internal"
PROXY_HOST="claude-sandbox-proxy"
GRADLE_CACHE_DIR="$HOME/.cache/claude-sandbox/gradle"
STATE_DIR="$HOME/.cache/claude-sandbox/state"
GITLAB_TOKEN_FILE="$HOME/.claude/gitlab-token"
HOST_CLAUDE_MD="$HOME/.claude/CLAUDE.md"
HOST_SETTINGS_JSON="$HOME/.claude/settings.json"
HOST_SKILLS_DIR="$HOME/.claude/skills"
HOST_AGENTS_SKILLS_DIR="$HOME/.agents/skills"
HOST_PLUGINS_DIR="$HOME/.claude/plugins"

require_task_name() {
    if [ -z "${1:-}" ]; then
        echo "usage: $(basename "$0") <task-name>" >&2
        exit 1
    fi
}

container_name() {
    echo "claude-sandbox-$1"
}

# claude-sandbox / claude-sandbox-proxy are run from inside the repo you
# want to sandbox; this is how the tool learns which repo that is.
resolve_repo_root() {
    if ! git rev-parse --show-toplevel 2>/dev/null; then
        echo "error: run this from inside the git repo you want to sandbox" >&2
        exit 1
    fi
}

# grant-secret.sh can be run from anywhere, so it looks up the repo a given
# task name was started against instead of relying on the caller's cwd.
save_repo_root() {
    mkdir -p "$STATE_DIR"
    echo "$2" > "$STATE_DIR/$1"
}

load_repo_root() {
    local f="$STATE_DIR/$1"
    if [ ! -f "$f" ]; then
        echo "error: no known repo for task '$1' — was claude-sandbox ever started for it?" >&2
        exit 1
    fi
    cat "$f"
}

worktree_path() {
    echo "$2/.claude/worktrees/$1"
}

ensure_proxy_stack() {
    docker compose -f "$SANDBOX_DIR/docker-compose.yml" up -d --build proxy >/dev/null
}

ensure_image() {
    docker build \
        --build-arg USER_UID="$(id -u)" \
        --build-arg DAILY_CACHE_BUST="$(date +%Y%m%d)" \
        -t "$IMAGE_NAME" \
        "$SANDBOX_DIR" >/dev/null
}

# Creates the worktree on a new branch named after the task if it doesn't
# already exist. Reuses it (and whatever branch it's on) otherwise.
ensure_worktree() {
    local name="$1" repo_root="$2" wt_path
    wt_path="$(worktree_path "$name" "$repo_root")"
    if [ ! -d "$wt_path" ]; then
        git -C "$repo_root" worktree add "$wt_path" -b "$name" >&2
    fi
    echo "$wt_path"
}

git_common_dir() {
    (cd "$1" && cd "$(git rev-parse --git-common-dir)" && pwd)
}

# Mirrors Claude Code's own project-key slugification (absolute path, "/"
# and "." each replaced with "-") so the memory mount below lands on the
# exact same key Claude Code would derive on the host for this repo.
project_memory_key() {
    printf '%s' "$1" | sed 's#[/.]#-#g'
}

# Populates the DOCKER_ARGS array with everything shared between the
# subscription and proxy wrappers: network/hardening flags, the worktree +
# shared .git mounts (kept at identical absolute paths inside the container,
# since git worktree linkage files embed absolute host paths), the Gradle
# cache mount, and the auto-memory/CLAUDE.md sharing below.
#
# home_volume (optional, 4th arg): the persistent ~/.claude identity volume
# used by the subscription flow. When given, it's mounted FIRST so the more
# specific memory bind mount below can nest inside it — mounting a broader
# path after a narrower one would hide the narrower one instead of nesting.
build_common_docker_args() {
    local name="$1" wt_path="$2" repo_root="$3" home_volume="${4:-}" git_common project_key memory_host_dir git_user_name git_user_email
    git_common="$(git_common_dir "$repo_root")"
    project_key="$(project_memory_key "$repo_root")"
    memory_host_dir="$HOME/.claude/projects/${project_key}/memory"
    mkdir -p "$GRADLE_CACHE_DIR" "$memory_host_dir"

    # ${git_common}/config is mounted read-only (by design — the container
    # shouldn't be able to repoint remotes or rewrite committer identity),
    # but that also means it can't pick up user.name/user.email from a
    # config file that isn't there. Resolve the identity a commit would
    # actually use on the host (repo config falling back to global) and
    # hand it over as env vars instead — git reads these directly, no
    # config file needed.
    git_user_name="$(git -C "$repo_root" config user.name || true)"
    git_user_email="$(git -C "$repo_root" config user.email || true)"

    DOCKER_ARGS=()
    if [ -n "$home_volume" ]; then
        DOCKER_ARGS+=(-v "${home_volume}:/home/sandbox/.claude")
    fi

    DOCKER_ARGS+=(
        --rm -it
        --name "$(container_name "$name")"
        --network "$NETWORK_NAME"
        --cap-drop ALL
        --security-opt no-new-privileges
        -e "http_proxy=http://${PROXY_HOST}:8888"
        -e "https_proxy=http://${PROXY_HOST}:8888"
        -e "HTTP_PROXY=http://${PROXY_HOST}:8888"
        -e "HTTPS_PROXY=http://${PROXY_HOST}:8888"
        -e "no_proxy=localhost,127.0.0.1"
        # JVM tools (gradlew's bootstrap included) don't read http_proxy/
        # https_proxy — those are a shell/curl convention. JAVA_TOOL_OPTIONS
        # is read directly by the JVM itself, so this covers gradlew and any
        # other java invocation, not just ones that go through a wrapper
        # script that happens to forward GRADLE_OPTS.
        -e "JAVA_TOOL_OPTIONS=-Dhttp.proxyHost=${PROXY_HOST} -Dhttp.proxyPort=8888 -Dhttps.proxyHost=${PROXY_HOST} -Dhttps.proxyPort=8888 -Dhttp.nonProxyHosts=localhost|127.0.0.1"
        -e "GRANT_SECRET_HINT=${SANDBOX_DIR}/bin/grant-secret.sh ${name}"
        -v "${wt_path}:${wt_path}"
        -v "${git_common}:${git_common}"
        -v "${git_common}/config:${git_common}/config:ro"
        -v "${GRADLE_CACHE_DIR}:/home/sandbox/.gradle"
        -v "${memory_host_dir}:/home/sandbox/.claude/projects/${project_key}/memory"
        -w "${wt_path}"
    )

    if [ -n "$git_user_name" ] && [ -n "$git_user_email" ]; then
        DOCKER_ARGS+=(
            -e "GIT_AUTHOR_NAME=${git_user_name}"
            -e "GIT_AUTHOR_EMAIL=${git_user_email}"
            -e "GIT_COMMITTER_NAME=${git_user_name}"
            -e "GIT_COMMITTER_EMAIL=${git_user_email}"
        )
    fi

    # Your real global CLAUDE.md (personal preferences) — merged with the
    # sandbox-notes CLAUDE.md by entrypoint.sh, not used to replace it.
    if [ -f "$HOST_CLAUDE_MD" ]; then
        DOCKER_ARGS+=(-v "${HOST_CLAUDE_MD}:/opt/host-claude-md/CLAUDE.md:ro")
    fi

    # settings.json's enabledPlugins/extraKnownMarketplaces — merged into the
    # container's own settings.json by entrypoint.sh (like statusLine above).
    if [ -f "$HOST_SETTINGS_JSON" ]; then
        DOCKER_ARGS+=(-v "${HOST_SETTINGS_JSON}:/opt/host-settings/settings.json:ro")
    fi

    # Personal skills. Some entries under ~/.claude/skills are relative
    # symlinks into ~/.agents/skills (e.g. brainstorming -> ../../.agents/
    # skills/brainstorming) — mounting both at the container's own
    # conventional paths keeps those symlinks resolvable, no path
    # translation needed since relative symlinks don't care where the
    # containing tree is rooted.
    if [ -d "$HOST_SKILLS_DIR" ]; then
        DOCKER_ARGS+=(-v "${HOST_SKILLS_DIR}:/home/sandbox/.claude/skills:ro")
    fi
    if [ -d "$HOST_AGENTS_SKILLS_DIR" ]; then
        DOCKER_ARGS+=(-v "${HOST_AGENTS_SKILLS_DIR}:/home/sandbox/.agents/skills:ro")
    fi

    # Installed plugins (e.g. the glab skill). installed_plugins.json /
    # known_marketplaces.json record each plugin's installPath as an
    # ABSOLUTE HOST PATH (e.g. /Users/you/.claude/plugins/cache/litellm/
    # glab/1.0.0) — same problem as the git worktree linkage files, so this
    # mounts at that identical host path rather than a container-relative
    # one. entrypoint.sh symlinks the two state files into the container's
    # own ~/.claude/plugins so Claude Code finds them at the location it
    # actually looks, while the paths inside them still resolve correctly.
    # Read-write: unlike CLAUDE.md/skills, Claude Code actively writes to
    # this directory (sweep timestamps, catalog cache) during normal use.
    if [ -d "$HOST_PLUGINS_DIR" ]; then
        DOCKER_ARGS+=(
            -v "${HOST_PLUGINS_DIR}:${HOME}/.claude/plugins"
            -e "HOST_HOME_PATH=${HOME}"
        )
    fi

    # ~/.claude/gitlab-token: a GitLab access token scoped to `api` only (no
    # write_repository/read_repository) — read/comment via glab, but the
    # token itself is structurally incapable of git push. Read fresh from
    # the host on every run, same as the corporate proxy env vars below;
    # never baked into the image or a volume.
    if [ -f "$GITLAB_TOKEN_FILE" ]; then
        DOCKER_ARGS+=(-e "GITLAB_TOKEN=$(cat "$GITLAB_TOKEN_FILE")")
    fi
}
