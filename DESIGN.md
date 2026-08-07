# Claude Code Docker Sandbox — Design

## Problem

Claude Code currently runs directly on the host, with full filesystem and
network access, using either a subscription login (`claude` alias) or a
corporate LLM proxy (`claude-proxy` alias, backed by
`~/.claude/proxy-settings.json`). This gives an injected prompt or an
over-permissive (YOLO-mode) session an unbounded blast radius: it can read
any file on disk (including `.env` files and other projects' secrets), reach
any network host, and directly mutate git state (branches, remotes, pushes)
shared with the rest of the repo.

## Threat model

This design defends against:

1. **Prompt-injection-driven exfiltration or destruction** — a compromised
   tool result, fetched web page, or malicious instruction gets Claude to
   read/exfiltrate secrets or run destructive commands.
2. **Accidental damage from permissive/auto-approve mode** — Claude runs a
   destructive command (`rm -rf`, `git reset --hard`, force-push, etc.)
   against shared state (the main checkout, other worktrees, remote
   branches) without a human catching it first.

It explicitly does **not** optimize for malicious third-party MCP
servers/skills (not a current concern), nor is it primarily a compliance
control — though it happens to satisfy "secrets never enter the sandbox by
default" as a side effect.

## Scope

Originally built and validated against one repo (service-router), on the
principle that parametrizing for a second repo before it existed would be
guessing at requirements. It since became clear the tool itself carries no
repo-specific logic — the personal decisions in it (auth modes, egress
allowlist, mount strategy) are about how its owner wants to run Claude Code
sandboxed, not about any one project — so it now lives as its own repo and
takes the target repo as an argument (resolved from the caller's current
directory; see decision #7 below). Any local git repo can be sandboxed by
`cd`-ing into it and running `claude-sandbox`/`claude-sandbox-proxy`.

## Architecture overview

```
host                                    docker (internal network only)
────────────────────────────────────    ─────────────────────────────────
git worktree add  ──────────────────►   /workspace  (bind mount, RW)
  <repo>/.claude/worktrees/<name>         = the worktree's tracked files
                                           (untracked .env files absent
                                            by construction)

<repo>/.git  (common dir) ──────────►   /workspace/../.git-common
  - objects/, refs/, worktrees/<n>/       mounted RW (needed for commit)
  - config                                mounted RO (no remote/identity
                                           tampering from inside)

~/.claude/proxy-settings.json           (never mounted — host reads it,
                                          forwards ANTHROPIC_AUTH_TOKEN /
                                          ANTHROPIC_BASE_URL as -e vars)

named volume "claude-sandbox-home"  ──► ~/.claude  (subscription mode only;
  (persists across ephemeral runs)        holds its own /login session,
                                           isolated from host ~/.claude)

~/.claude/CLAUDE.md (host, RO)      ──► /opt/host-claude-md/CLAUDE.md
  merged into the container's global CLAUDE.md by entrypoint.sh

~/.claude/projects/<key>/memory  ───►   ~/.claude/projects/<key>/memory
  (host, RW; <key> = repo root path      (nests inside claude-sandbox-home
   with "/" and "." → "-", matching       for subscription mode; mounted
   Claude Code's own project-key rule)    directly otherwise)

                                         claude-sandbox-<worktree> container
                                           - no NET_ADMIN, no push token
                                           - egress only via sidecar proxy
                                                   │
                                         internal-only docker network
                                                   │
                                         forward-proxy sidecar (tinyproxy)
                                           - domain allowlist, only member
                                             of both networks
                                                   │
                                          ── internet (allowlisted hosts) ──
```

## Decisions

### 1. Container lifecycle: ephemeral, one per worktree/task

A wrapper script creates (or reuses) a worktree, starts a fresh container
scoped to it, runs Claude, and the container is disposable when the task
ends. The worktree itself persists on disk (for IDEA / host git) after the
container is gone.

Gradle/dependency caches are mounted from a separate persistent host
directory so ephemerality doesn't cost rebuild time on every task.

### 2. Filesystem: worktree bind mount + minimal shared `.git` access

- Host runs `git worktree add <repo>/.claude/worktrees/<name> <branch>`
  before starting the container (this project already uses this
  convention — see existing worktrees under `.claude/worktrees/`).
- Only that worktree directory is bind-mounted into the container (a real
  host path, so IDEA can open it directly with zero sync step — not a
  Docker-internal named volume, which would be invisible to the host).
- `.env` files and other credential files (`pm/.env`, `pm/gitlab/.env`,
  `mcp/prometheus/.env_mcp_prometheus`, `services/lib/.../*Credentials.json`)
  are gitignored/untracked, so a freshly created worktree simply does not
  contain them. No filtering logic is needed for the default case.
- Because a worktree's `.git` is a pointer into the main repo's common git
  dir, git commands need access to that shared state too:
  - `objects/`, `refs/`, `worktrees/<name>/` → mounted **read-write** (only
    way `git commit` can update the branch ref / add objects).
  - `config` → mounted **read-only** (prevents the container from
    repointing remotes or rewriting committer identity).

### 3. Git and push model

- Claude commits freely inside the container. This is low-risk: git
  worktree commands are scoped to the worktree's own checked-out branch by
  design (git refuses to check out a branch already checked out elsewhere).
- **No GitLab push token ever enters the container.** Pushing a worktree's
  branch to the remote is a host-side action, triggered by the user after
  reviewing the commits — not something the sandboxed Claude can do
  regardless of prompt or approval-mode state. This removes an entire class
  of "injected instruction talks Claude into pushing something" risk rather
  than relying on catching a permission prompt or a token's branch-protection
  scope.

### 4. Two auth modes, two wrapper aliases

Mirrors the existing `claude` / `claude-proxy` split, but neither reuses the
host credential files directly:

- **`claude-sandbox`** (subscription): a persistent named Docker volume
  (`claude-sandbox-home`) holds that sandbox identity's own `~/.claude`,
  populated by one interactive `claude /login` inside the container the
  first time, then reused across future ephemeral containers. This volume
  is a separate identity store from the host's `~/.claude` — session
  transcripts, credentials, and everything else stay isolated — so a
  sandbox compromise can't exfiltrate the host identity.
- **`claude-sandbox-proxy`**: stateless. The host-side wrapper reads
  `~/.claude/proxy-settings.json` and forwards only
  `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_BASE_URL` / model env vars as
  `docker run -e ...` flags. The settings file itself is never mounted into
  the container.
- **Exception, deliberately narrow**: the host's global `CLAUDE.md`
  (personal preferences) and per-project auto-memory
  (`~/.claude/projects/<key>/memory/`) *are* shared with both modes — see
  `build_common_docker_args` in `bin/lib.sh`. These are just markdown notes
  (conventions, feedback, project facts), not credentials or transcripts,
  and the whole point of auto-memory is to avoid relearning the same
  lessons; keeping it host-only inside an isolated identity defeated that.
  The memory mount is read-write so sandbox sessions contribute back too.
  `<key>` is derived by mirroring Claude Code's own slugification (`/` and
  `.` → `-`) on the repo root path — an internal convention, not a
  documented API, so it could drift if a future CLI version changes it.
- Same exception, extended to skills and plugins: `~/.claude/skills/`,
  `~/.agents/skills/` (some skill entries are relative symlinks into it),
  and `~/.claude/plugins/` (installed plugins like `glab`) are mounted in,
  plus `enabledPlugins`/`extraKnownMarketplaces` synced from the host's
  `settings.json` on every start. `installed_plugins.json`/
  `known_marketplaces.json` record each plugin's install path as an
  *absolute host path* (e.g. `/Users/you/.claude/plugins/cache/litellm/
  glab/1.0.0`) — same issue as git worktree linkage files — so the plugins
  mount lands at that identical host path rather than a container-relative
  one, and `entrypoint.sh` symlinks the two state files into the
  container's own `~/.claude/plugins` so Claude Code finds them where it
  actually looks. Mounted read-write, unlike skills/CLAUDE.md, since Claude
  Code writes to this directory during normal use (sweep timestamps,
  catalog cache).
- Local/user-scoped MCP servers (`claude mcp add --scope local`) live in
  `~/.claude.json`'s `projects[repo_root].mcpServers`, not the repo's
  tracked `.mcp.json` — same blind spot as skills/plugins, same fix:
  mirrored into the container's own `.claude.json` every start, keyed by
  the same `repo_root` string. Unlike the others, this one can carry a
  live credential (e.g. a YouTrack bearer token), so
  `~/.claude/sandbox-mcp-overrides.json` lets a specific server name use a
  separate, independently-revocable sandbox-only token instead of reusing
  the host's — checked first, falls back to the mirrored host config per
  server name if no override exists for it. For YouTrack specifically,
  token scoping has no read-only option (unlike GitLab's `api`/
  `read_repository` split — see the `glab` section above), so mutating
  tools (`create_issue`, `update_issue`, `add_comment`, etc., enumerated by
  querying the live server's `tools/list`) are gated behind a `settings.json`
  `permissions.ask` rule instead, applied every start as a sandbox-only
  policy layered on top of `--permission-mode auto` — not synced from the
  host, since this friction is deliberately sandbox-specific.
- **Sharing `claude-sandbox-home` across concurrent tasks has a sharp
  edge**: Claude Code's own daemon/session-coordination state
  (`~/.claude/daemon/`, `daemon.lock`, `session-env/`, `jobs/`, `sessions/`,
  `shell-snapshots/`, `file-history/`) assumes single-host semantics —
  worker PIDs and unix-socket paths recorded there are only meaningful
  within the process/container that wrote them. Two containers on the same
  volume writing to these paths concurrently produces a last-writer-wins
  race. Confirmed directly: two simultaneously-running task containers
  showed byte-identical `daemon/roster.json`, one task's own worker
  registration silently overwritten by the other's — plausibly the cause
  of one session appearing to hang until the other's finished. Fixed with
  per-container `--tmpfs` mounts (with explicit `uid`/`gid`, since
  `--tmpfs` defaults to root ownership and the container runs as
  `sandbox`) over just those paths, layered on top of the shared volume —
  identity/config (credentials, settings, memory, plugins) stays shared
  and persistent; live coordination state stays private and ephemeral per
  container.

### 5. Network egress: internal Docker network + forward-proxy sidecar

Enforced at the **network level**, not inside the sandboxed container:

- The Claude container sits on an internal-only Docker network with no
  route to the internet.
- A small forward-proxy sidecar (e.g. tinyproxy) is the only container that
  is a member of both the internal network and the internet-facing one. It
  filters egress to an explicit domain allowlist.
- This keeps the Claude container itself capability-free (no `NET_ADMIN`),
  unlike an iptables-inside-the-container approach — there is no in-container
  privilege that a compromised process could use to widen its own network
  access.

Starting allowlist (default-deny otherwise):

- `llm-proxy-ai.kube1-tt2.lskube.eu` (corporate LLM proxy, `claude-sandbox-proxy` mode)
- `api.anthropic.com`, `console.anthropic.com` (subscription OAuth + the
  minimal telemetry `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` still needs)
- GitLab host (`git fetch`/`git pull`/`glab` reads only — no push credential
  present regardless of network reachability)
- Maven Central, Gradle Plugin Portal, npm registry, OpenTofu registry
  (build/dependency resolution)

This list should be verified/extended against what a clean `./gradlew build`
actually reaches for service-router before relying on it.

`tofu` (OpenTofu) is installed for validating this repo's Terraform config
(`init -backend=false`, `validate`, `fmt`) — deliberately with no path to
GCP or the `gcs` backend. Confirmed directly: with a stale local backend
pointer present, `init` tried to reach `oauth2.googleapis.com` and got
`Filtered`; with a clean directory, `init -backend=false` needs only the
provider registry and completes without ever touching Google's APIs. Real
infrastructure and state stay genuinely out of reach, not just
undocumented — `plan`/`apply` against the real backend will fail to
connect.

### 6. Need-to-know secret access

Nothing is mounted by default (see #2). When a task genuinely needs one:

- User runs a host-side helper, `grant-secret.sh <task-name> <path>` (e.g.
  `grant-secret.sh my-task pm/.env`), which does a one-shot `docker cp` of
  that single file into the **already-running** named container
  (`claude-sandbox-<task-name>`) at the corresponding path inside the
  mounted worktree.
- No restart is needed (which would otherwise drop the running session/
  context), and no lingering mount is left behind to forget about — the
  copy evaporates when the ephemeral container is torn down.
- The sandbox's `CLAUDE.md` instructs Claude: if a command fails because a
  gitignored credential/`.env` file is missing, don't attempt to work
  around it — read `$GRANT_SECRET_HINT` (injected per-container) to get the
  exact host command for that session, and tell the user to run it followed
  by the missing file's path.

### 7. Target repo resolution: caller's cwd, not this tool's location

Since this tool lives in its own repo separate from whatever it's
sandboxing, `claude-sandbox`/`claude-sandbox-proxy` resolve the target repo
via `git rev-parse --show-toplevel` from the directory they're invoked
from — you `cd` into the repo you want to sandbox first. That resolution
is saved (keyed by task name, under `~/.cache/claude-sandbox/state/`) so
that `grant-secret.sh`, which you might run later from a different shell
or directory, can still find the right repo without requiring you to `cd`
back into it.

### 8. `/ide` integration: narrow port relay, not general host reachability

Every other allowlist entry in this document is about reaching *out* to an
external service. `/ide` is the first hole that reaches *back* into the
host — a live, authenticated WebSocket control channel (open files, apply
edits) into a real IDE window, not just the one worktree. That's a
different class of exposure than "it queried an API it shouldn't have," so
it's deliberately scoped as narrowly as the mechanism allows:

- IntelliJ's Claude Code plugin publishes one `~/.claude/ide/<port>.lock`
  file per open window, each recording `workspaceFolders` and an
  `authToken` for a WebSocket server at `localhost:<port>` on the host.
  Claude Code's own `/ide` matches against `cwd` to pick the right one.
- `discover_ide_ports` (`bin/lib.sh`) does the same match against the
  worktree path and the plain repo root, and only mounts the *matching*
  lock file(s) into the container — not every open IDE window.
- The port itself is relayed, not exposed generally: `ensure_proxy_ide_relay`
  starts a `socat` listener *inside the shared proxy container* (already a
  member of the `external` network, which is where `host.docker.internal`
  is reachable on Docker Desktop — confirmed directly, no extra
  `--add-host` needed) forwarding `claude-sandbox-proxy:<port>` to
  `host.docker.internal:<port>`. The sandboxed container never talks to
  `host.docker.internal` itself; `entrypoint.sh` relays its own
  `127.0.0.1:<port>` to `claude-sandbox-proxy:<port>` over the existing
  internal network, so from Claude Code's perspective inside the container
  it's just `localhost:<port>`, same as it would expect on a normal
  install, unaware it's actually two hops away.
- Idempotent by design: `ensure_proxy_ide_relay` checks for an existing
  `socat` process for that port before starting one, so relaunching a task
  (or starting a second one matching the same IDE window) doesn't spawn
  duplicates. Stale relays for closed IDE windows are harmless (the
  forward target just refuses the connection) but do accumulate for the
  proxy container's lifetime — acceptable for a PoC, not cleaned up
  automatically.
- Verified end to end: raw TCP reachability proxy→host, then the full
  container→proxy→host path via `bash /dev/tcp`, against a real running
  IntelliJ window.

## Implementation notes (resolved during build)

- **Mount paths must mirror the host, not `/workspace`.** A git worktree's
  `.git` file, and the corresponding admin dir under the main repo's
  `.git/worktrees/<name>/`, embed each other's **absolute host paths**.
  Mounting the worktree at a different path inside the container (e.g.
  `/workspace`) would leave those pointers unresolvable. The wrapper scripts
  bind-mount the worktree and the main repo's `.git` common dir at their
  real host paths inside the container, and set that same path as `WORKDIR`.
- **No git remote credentials enter the container at all**, not just no
  push token. service-router's origin (the repo this was first validated
  against) is SSH (`git@gitlab.com:...`), so even read-only `fetch`/`pull`
  would need an SSH key inside the container —
  a credential class the original spec hadn't assigned a home for.
  Extending the "no push token" rationale symmetrically: all fetch/pull
  happens host-side before a task starts; the container's sandbox
  `CLAUDE.md` tells Claude not to attempt any git remote operation.
  `gitlab.com` is therefore **not** on the default egress allowlist.
  (`glab` reads could be added later via the same `grant-secret.sh`
  need-to-know mechanism, using a scoped read-only PAT, if ever needed.)
- **Artifactory/build-cache credentials are optional, not baked in.** The
  Gradle build's internal-registry config (`ARTIFACTORY_URL` /
  `ARTIFACTORY_USERNAME` / a token) is guarded by
  `if (!System.getenv("ARTIFACTORY_URL").isNullOrBlank())` — a build
  without those env vars set falls back to public Maven Central / Gradle
  Plugin Portal. So the default sandbox needs no internal-registry secret;
  if a task ever needs the real build cache, that's a `grant-secret.sh`-style
  addition, not a default-allowlist one.
- Base image: standalone Debian bookworm + Temurin 21 JDK + Node (for the
  Claude Code CLI itself), closer to `pm/Dockerfile`'s approach than the
  org's Alpine JRE-only runtime images (`dockerfiles/openjdk-21-jdk`,
  `dockerfiles/service-base-image`), which aren't dev/build images.
- Container runs as a non-root user (`sandbox`, UID/GID matched to the host
  user at build time so bind-mounted files keep sane host-side ownership),
  with `--cap-drop ALL --security-opt no-new-privileges` at `docker run`
  time.
- Network egress: `docker-compose.yml` defines an `internal: true` Docker
  network (no route to the internet) plus a `proxy` sidecar
  (custom Alpine + tinyproxy image) that's the only member of both the
  internal and external networks. tinyproxy filters by CONNECT-target
  hostname regex (`proxy/filter.allow`) — no TLS interception/CA needed,
  since only the hostname (not the encrypted payload) is inspected.

## Layout

```
Dockerfile              claude-sandbox image (Debian + JDK 21 + Node + claude CLI)
entrypoint.sh           builds ~/.claude/CLAUDE.md (sandbox notes + host CLAUDE.md if
                          mounted), symlinks .claude.json, seeds statusLine, then execs
CLAUDE.md               sandbox-specific guidance merged into the container's global CLAUDE.md
statusline-command.sh   same status line as the host, seeded into settings.json on first run
docker-compose.yml      internal/external networks + proxy sidecar
proxy/
  Dockerfile            Alpine + tinyproxy
  tinyproxy.conf
  filter.allow          egress domain allowlist (regex, default-deny)
bin/
  lib.sh                shared helpers (repo resolution, worktree creation, docker run args)
  claude-sandbox         subscription-mode wrapper (persistent home volume)
  claude-sandbox-proxy    proxy-mode wrapper (stateless env var forwarding)
  grant-secret.sh        docker cp a named secret into a running container
```

Host aliases (`~/.zshrc`): `claude-sandbox <task-name>` and
`claude-sandbox-proxy <task-name>` (run from inside the repo to sandbox),
plus `grant-secret <task-name> <path>` (runs from anywhere).

## Remaining open items

- The egress allowlist (`proxy/filter.allow`) was validated against
  service-router's build (Maven Central, Gradle Plugin Portal, npm
  registry, the LLM proxy host, Anthropic API) — a different repo's build
  may need additional hosts added.
- First real end-to-end run (image build, `/login` inside the container for
  subscription mode, a trial task) hasn't been done yet — treat this as
  unverified until exercised once.