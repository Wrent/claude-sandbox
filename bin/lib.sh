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
HOST_CLAUDE_JSON="$HOME/.claude.json"
SANDBOX_MCP_OVERRIDES="$HOME/.claude/sandbox-mcp-overrides.json"
HOST_IDE_LOCK_DIR="$HOME/.claude/ide"
PLANNOTATOR_PORT=19432
BRAINSTORM_PORT=19433

require_task_name() {
    if [ -z "${1:-}" ]; then
        echo "usage: $(basename "$0") <task-name>" >&2
        exit 1
    fi
}

# Docker container names only allow [a-zA-Z0-9_.-] — task names don't
# have that restriction (e.g. "feature/FSDS-4280-x", the branch-naming
# convention a pre-commit hook might require), so sanitize just for this
# one use. The worktree path and the actual git branch name keep the real
# task name untouched; only the container's --name is affected.
container_name() {
    local sanitized
    sanitized="$(printf '%s' "$1" | tr -c 'a-zA-Z0-9_.-' '-')"
    echo "claude-sandbox-${sanitized}"
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
# A task name containing "/" (see container_name's comment) makes this a
# nested path, so the parent dir needs creating too, not just STATE_DIR
# itself.
save_repo_root() {
    mkdir -p "$(dirname "$STATE_DIR/$1")"
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

# Pushes the repo's current proxy config into the already-running proxy
# container and restarts it (docker restart, not a full compose recreate —
# no image rebuild needed, the running container's writable layer already
# has the new files once docker cp lands them).
#
# IMPORTANT: this DOES disrupt every live connection through the proxy —
# every concurrent task's in-progress API stream gets cut, same as the
# recreate this was originally meant to avoid. tinyproxy's SIGHUP handler
# looks like it should cover this (its own strings mention "Reloading
# config file", and it's genuinely true that signaling it doesn't kill
# in-flight connections) but confirmed directly, twice, with a real test
# entry: it does NOT actually reprocess the Filter list — a brand new
# allowlist entry stayed blocked after cp + SIGHUP, and only started
# working after a real restart. There does not appear to be a way to
# apply a filter.allow change to a running tinyproxy without restarting
# the process. Call this deliberately, and warn about the disruption
# first — never as a side effect of routine task launches (see
# ensure_proxy_stack, which does NOT call this).
apply_proxy_config() {
    docker cp "$SANDBOX_DIR/proxy/tinyproxy.conf" "${PROXY_HOST}:/etc/tinyproxy/tinyproxy.conf"
    docker cp "$SANDBOX_DIR/proxy/filter.allow" "${PROXY_HOST}:/etc/tinyproxy/filter.allow"
    docker restart "$PROXY_HOST" >/dev/null
}

# Starts the proxy stack if it isn't running yet. Does NOT touch it if it's
# already running — a routine task launch should never risk disrupting a
# different, already-running task's connections through the shared proxy.
# If the proxy's config or image needs updating, that's a deliberate
# action: apply_proxy_config for a filter.allow-only change (still
# disruptive — see its comment for why), or `docker compose up -d --build
# proxy` directly when the image itself needs to change.
ensure_proxy_stack() {
    if docker ps --format '{{.Names}}' | grep -qx "$PROXY_HOST"; then
        return 0
    else
        docker compose -f "$SANDBOX_DIR/docker-compose.yml" up -d --build proxy >/dev/null
    fi
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
        # `worktree add` doesn't fetch submodules, and the sandbox container
        # gets no git credentials of its own (see sandbox CLAUDE.md) — has to
        # happen here, on the host, with the user's real SSH key, before this
        # worktree ever gets bind-mounted into a container. No-op for repos
        # without submodules.
        git -C "$wt_path" submodule update --init --recursive >&2
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

# Finds ~/.claude/ide/*.lock files whose workspaceFolders include either
# the worktree path or the plain repo root, and prints their port numbers
# (one per line, taken from the filename). Mirrors the matching Claude
# Code itself does when picking an IDE window for the current cwd.
discover_ide_ports() {
    local wt_path="$1" repo_root="$2"
    [ -d "$HOST_IDE_LOCK_DIR" ] || return 0
    node -e "
        const fs = require('fs');
        const dir = '$HOST_IDE_LOCK_DIR';
        const targets = new Set(['$wt_path', '$repo_root']);
        for (const f of fs.readdirSync(dir)) {
            if (!f.endsWith('.lock')) continue;
            try {
                const data = JSON.parse(fs.readFileSync(dir + '/' + f, 'utf8'));
                const folders = data.workspaceFolders || [];
                if (folders.some(fld => targets.has(fld))) {
                    console.log(f.replace(/\.lock\$/, ''));
                }
            } catch (e) {}
        }
    "
}

# Ensures a relay for the given IDE WebSocket port is running inside the
# shared proxy container, forwarding claude-sandbox-proxy:<port> to
# host.docker.internal:<port> (the real IDE server) — the ONLY hole this
# opens is that one specific port, not general host-loopback reachability;
# the sandboxed container only ever talks to claude-sandbox-proxy, never
# host.docker.internal directly. Idempotent: skips if a relay for that
# port is already running (e.g. left over from an earlier task).
ensure_proxy_ide_relay() {
    local port="$1"
    if docker exec "$PROXY_HOST" pgrep -f "TCP-LISTEN:${port}," >/dev/null 2>&1; then
        return 0
    fi
    docker exec -d "$PROXY_HOST" socat "TCP-LISTEN:${port},fork,reuseaddr" "TCP:host.docker.internal:${port}"
}

# Mirror image of ensure_proxy_ide_relay: that one relays a container's
# outbound reach to a host service; this one relays the host's inbound
# reach to a service running INSIDE a sandbox container (plannotator's
# server). docker-compose.yml publishes 19432 on the proxy itself (the one
# dual-homed container — sandbox containers are internal-only, and Docker
# won't publish ports from an internal network at all, confirmed
# directly). This just points the proxy's existing relay at whichever
# container is current — if one's already running for a DIFFERENT
# container (a previous task), it's replaced; last task to request the
# port wins, since it's one shared host port across every concurrent task.
ensure_proxy_plannotator_relay() {
    local target_container="$1"
    if docker exec "$PROXY_HOST" pgrep -f "TCP-LISTEN:${PLANNOTATOR_PORT},fork,reuseaddr TCP:${target_container}:" >/dev/null 2>&1; then
        return 0
    fi
    docker exec "$PROXY_HOST" pkill -f "TCP-LISTEN:${PLANNOTATOR_PORT}," >/dev/null 2>&1 || true
    docker exec -d "$PROXY_HOST" socat "TCP-LISTEN:${PLANNOTATOR_PORT},fork,reuseaddr" "TCP:${target_container}:${PLANNOTATOR_PORT}"
}

# Same pattern as ensure_proxy_plannotator_relay, for the brainstorming
# skill's "visual companion" server (~/.agents/skills/brainstorming). That
# server binds 127.0.0.1 on a random high port by default — reachable by
# nothing outside its own container even with a relay pointed at it, since
# the relay lives in a *different* container (the proxy) and can only reach
# a listener bound to all interfaces via the internal network's container-
# name DNS. Fixing the bind address is a per-invocation flag
# (`--host 0.0.0.0`), not something this script can set — see the
# CLAUDE.md note that tells the agent to pass it inside the sandbox. This
# function only handles the other half: pinning the port so the relay
# below can be pre-wired to it, same one-shared-port/last-task-wins
# tradeoff as plannotator.
ensure_proxy_brainstorm_relay() {
    local target_container="$1"
    if docker exec "$PROXY_HOST" pgrep -f "TCP-LISTEN:${BRAINSTORM_PORT},fork,reuseaddr TCP:${target_container}:" >/dev/null 2>&1; then
        return 0
    fi
    docker exec "$PROXY_HOST" pkill -f "TCP-LISTEN:${BRAINSTORM_PORT}," >/dev/null 2>&1 || true
    docker exec -d "$PROXY_HOST" socat "TCP-LISTEN:${BRAINSTORM_PORT},fork,reuseaddr" "TCP:${target_container}:${BRAINSTORM_PORT}"
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
    local name="$1" wt_path="$2" repo_root="$3" home_volume="${4:-}" git_common project_key memory_host_dir git_user_name git_user_email tmpfs_owner
    git_common="$(git_common_dir "$repo_root")"
    # Matches the sandbox user's UID/GID (set at image build time from the
    # host user, see ensure_image) — --tmpfs defaults to root ownership
    # otherwise, and the container runs as non-root.
    tmpfs_owner="uid=$(id -u),gid=$(id -g)"
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
        # Claude Code's own live daemon/session-coordination state (worker
        # PIDs, unix-socket paths under /tmp, background-agent job state)
        # assumes single-host semantics. claude-sandbox-home is shared
        # across every concurrently-running task, so two containers writing
        # to these same paths at once produces a last-writer-wins race —
        # confirmed directly: two live containers showed byte-identical
        # daemon/roster.json, one task's worker registration silently
        # clobbered by the other's. tmpfs gives each container its own
        # private, empty view of just these paths; everything else under
        # ~/.claude (credentials, settings, memory, plugins) stays on the
        # shared volume as before, nested inside it same as any other
        # narrower mount.
        --tmpfs "/home/sandbox/.claude/daemon:${tmpfs_owner}"
        --tmpfs "/home/sandbox/.claude/session-env:${tmpfs_owner}"
        --tmpfs "/home/sandbox/.claude/sessions:${tmpfs_owner}"
        --tmpfs "/home/sandbox/.claude/jobs:${tmpfs_owner}"
        --tmpfs "/home/sandbox/.claude/shell-snapshots:${tmpfs_owner}"
        --tmpfs "/home/sandbox/.claude/file-history:${tmpfs_owner}"
        --tmpfs "/home/sandbox/.claude-runtime:${tmpfs_owner}"
        # docker run -it allocates a PTY but doesn't forward the calling
        # shell's terminal-identifying env vars — the container saw
        # TERM=dumb and no TERM_PROGRAM by default. Claude Code uses
        # TERM_PROGRAM (e.g. "iTerm.app") to detect the terminal and set
        # up terminal-specific behavior like the Shift+Enter-for-newline
        # keybinding (recorded as deepLinkTerminal in .claude.json once
        # detected) — without it, the sandbox's separate identity never
        # gets to run that detection at all.
        -e "TERM=${TERM:-xterm-256color}"
        -e "COLORTERM=${COLORTERM:-truecolor}"
        -e "TERM_PROGRAM=${TERM_PROGRAM:-}"
        -e "TERM_PROGRAM_VERSION=${TERM_PROGRAM_VERSION:-}"
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

    # plannotator: only set this up if the plugin is actually enabled for
    # this user — pointing the shared relay here on every task launch,
    # including ones that never touch plannotator, would silently steal
    # the port from a task that actually wants it if two run concurrently.
    # PLANNOTATOR_REMOTE=1 + a fixed port is a documented, intentional mode
    # from plannotator's own authors, not something we're forcing on it —
    # see the Dockerfile comment. Host reachability is via the proxy's
    # relay (ensure_proxy_plannotator_relay above), not a direct publish
    # from this container — Docker doesn't allow that on an internal network.
    if [ -f "$HOST_SETTINGS_JSON" ] && grep -q '"plannotator@plannotator"[[:space:]]*:[[:space:]]*true' "$HOST_SETTINGS_JSON" 2>/dev/null; then
        ensure_proxy_plannotator_relay "$(container_name "$name")"
        DOCKER_ARGS+=(
            -e "PLANNOTATOR_REMOTE=1"
            -e "PLANNOTATOR_PORT=${PLANNOTATOR_PORT}"
        )
    fi

    # brainstorming skill's "visual companion" (start-server.sh /
    # server.cjs): same reverse-relay need as plannotator (host browser ->
    # container), but the server's own default is a RANDOM port, which
    # can't be pre-wired into a relay. server.cjs does honor a
    # BRAINSTORM_PORT env var for a fixed port, same idea as
    # PLANNOTATOR_PORT above — this pins it so ensure_proxy_brainstorm_relay
    # can point at a known port. The other half (the server's default
    # 127.0.0.1-only bind) is a CLI flag the skill invokes itself
    # (--host 0.0.0.0), not something set here — see the sandbox CLAUDE.md.
    # Gated on the skill actually being present, same reasoning as the
    # plannotator gate above.
    if [ -d "$HOST_AGENTS_SKILLS_DIR/brainstorming" ]; then
        ensure_proxy_brainstorm_relay "$(container_name "$name")"
        DOCKER_ARGS+=(-e "BRAINSTORM_PORT=${BRAINSTORM_PORT}")
    fi

    # Local/user-scoped MCP servers registered against this repo (e.g. via
    # `claude mcp add --scope local`) live in ~/.claude.json's
    # projects[repo_root].mcpServers, not the repo's own tracked .mcp.json
    # — so they're invisible to the sandbox by default even though the
    # user clearly already trusts and uses them for this exact repo.
    # entrypoint.sh merges just that one key into the container's own
    # .claude.json, every start, keyed by the same repo_root string (the
    # plain repo root, not the worktree path — matches how memory's
    # project-key mapping already resolves worktrees back to the main repo).
    if [ -f "$HOST_CLAUDE_JSON" ]; then
        DOCKER_ARGS+=(
            -v "${HOST_CLAUDE_JSON}:/opt/host-settings/claude.json:ro"
            -e "HOST_REPO_ROOT=${repo_root}"
        )
    fi

    # ~/.claude/sandbox-mcp-overrides.json: sandbox-only MCP server configs
    # that take priority over the mirrored ones above, keyed the same way
    # ({"<repo_root>": {"<server-name>": {...}}}). For servers holding a
    # credential (e.g. youtrack-mcp) where you want a separate, independently
    # revocable token instead of reusing your host one — put an entry with
    # the same server name here and it replaces the mirrored version; any
    # other server not listed here still just mirrors the host as before.
    if [ -f "$SANDBOX_MCP_OVERRIDES" ]; then
        DOCKER_ARGS+=(-v "${SANDBOX_MCP_OVERRIDES}:/opt/host-settings/sandbox-mcp-overrides.json:ro")
    fi

    # /ide: relay just the specific IDE WebSocket port(s) whose workspace
    # matches this worktree/repo — see discover_ide_ports/ensure_proxy_ide_relay
    # above. Mounting the lock file gives Claude Code the authToken it
    # needs; entrypoint.sh starts the container-local half of the relay
    # (127.0.0.1:<port> -> claude-sandbox-proxy:<port>) for each port listed.
    local ide_port ide_relay_ports=""
    while IFS= read -r ide_port; do
        [ -n "$ide_port" ] || continue
        ensure_proxy_ide_relay "$ide_port"
        DOCKER_ARGS+=(-v "${HOST_IDE_LOCK_DIR}/${ide_port}.lock:/home/sandbox/.claude/ide/${ide_port}.lock:ro")
        ide_relay_ports="${ide_relay_ports}${ide_relay_ports:+ }${ide_port}"
    done <<< "$(discover_ide_ports "$wt_path" "$repo_root")"
    if [ -n "$ide_relay_ports" ]; then
        DOCKER_ARGS+=(-e "IDE_RELAY_PORTS=${ide_relay_ports}")
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
