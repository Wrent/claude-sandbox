# Claude Code sandbox

Runs Claude Code in a Docker container scoped to a single git worktree of
whichever repo you point it at, with restricted filesystem and network
access. Design rationale and decisions: [`DESIGN.md`](DESIGN.md).

## Prerequisites

- Docker Desktop running.
- Node.js on the host (not just inside the container) — the launcher
  scripts shell out to `node` to read JSON: `claude-sandbox-proxy` parses
  `~/.claude/proxy-settings.json`, and `/ide` port discovery parses
  `~/.claude/ide/*.lock`. Any recent version works; if you have Claude
  Code installed natively you already have it.
- `~/.zshrc` has the `claude-sandbox` / `claude-sandbox-proxy` /
  `grant-secret` aliases (pointing at `bin/` in this repo).

## Quick start

`cd` into the repo you want to sandbox — `claude-sandbox`/`claude-sandbox-proxy`
figure out which repo to use from your current directory, so run them
from inside it, not from inside this tool's own directory. Then pick a
short task name; it becomes both the worktree name
(`<repo>/.claude/worktrees/<task-name>`) and the container name
(`claude-sandbox-<task-name>`).

```sh
cd ~/projects/some-repo

# Subscription auth (persists login across runs in a Docker volume)
claude-sandbox my-task

# Corporate LLM proxy auth (reads ~/.claude/proxy-settings.json, stateless)
claude-sandbox-proxy my-task
```

Either command will, on first use for that task name:

1. Build the sandbox image if it's not already built.
2. Start the shared network + egress-filtering proxy sidecar if not already
   running (`docker compose up -d proxy`, from this repo).
3. Create `<repo>/.claude/worktrees/my-task` on a new branch `my-task` (or
   reuse it if it already exists).
4. Start the container with that worktree mounted, and launch `claude`.

Subscription mode will prompt an interactive `/login` the first time — the
resulting session is saved in the `claude-sandbox-home` Docker volume and
reused on later runs, so you only log in once, regardless of which repo
you're sandboxing.

The worktree is a normal folder on disk — open it directly in IDEA like any
other folder. Edits made by the sandboxed Claude show up there immediately,
no sync step needed.

Your global `~/.claude/CLAUDE.md`, the target repo's accumulated auto-memory
(`~/.claude/projects/<repo>/memory/`, read-write), your personal skills
(`~/.claude/skills/`, `~/.agents/skills/`), and installed plugins/skills
like `glab` (`~/.claude/plugins/`, plus the matching `enabledPlugins`/
`extraKnownMarketplaces` from `settings.json`) are all shared in, so the
sandbox isn't relearning things you've already taught your host sessions
or missing tooling you already have. Everything else about the identity —
login session, transcripts, credentials — stays isolated per `DESIGN.md`.

## Reviewing and shipping the work

Claude commits inside the container, but **the container can never push,
fetch, or pull** — no git remote credential of any kind is available to it
(see `DESIGN.md` for why fetch/pull are host-only too, not just push).
Push yourself, from the host, after reviewing the commits:

```sh
git -C <repo>/.claude/worktrees/my-task log
git -C <repo>/.claude/worktrees/my-task push -u origin my-task
```

When you're done with a single task:

```sh
git -C <repo> worktree remove .claude/worktrees/my-task
git -C <repo> branch -D my-task   # once merged/no longer needed
```

To clean up in bulk instead, run `claude-sandbox-prune` from inside the
repo. It removes any `.claude/worktrees/<task>` whose branch is already
merged into the upstream default branch and whose working tree is clean.
It never touches a worktree that's locked (in use by another session,
including the one you're standing in) or that has uncommitted changes —
those are reported, not force-removed.

```sh
cd ~/projects/some-repo
claude-sandbox-prune           # dry run — lists what would be removed
claude-sandbox-prune --apply   # actually removes the eligible worktrees
```

To remove one specific worktree regardless of lock state or uncommitted
changes, name it explicitly:

```sh
claude-sandbox-prune --force my-task
```

A lock usually just means a worktree-feature session registered it and
never cleanly unregistered it (e.g. after a crash), not that it's
necessarily in active use — but this doesn't check for a still-running
container, so confirm nothing's actually using it first.

## Giving it access to a secret it needs

Nothing under a `.gitignore`d path (`.env` files, credential JSON, etc.) is
visible by default — worktrees only contain tracked files. If Claude hits a
missing credential mid-task, it will tell you which file and the exact
command to run (it reads its own `$GRANT_SECRET_HINT`, so it always gives
you the right one, regardless of which repo/task it's running as). It
looks like:

```sh
grant-secret my-task pm/.env
```

This works from any directory — the tool remembers which repo `my-task`
belongs to. It copies just that one file into the running container; no
restart, and the copy disappears when the container is torn down. Nothing
is retained between tasks; run it again for a new task if needed.

## GitLab access (`glab`)

The image includes `glab`. To let it read MRs/issues and post comments,
create a GitLab personal access token scoped to **`api` only** — leave
`read_repository` and `write_repository` unchecked. `api` covers everything
`glab` needs (reading, commenting, approving); those two repository scopes
are what GitLab checks for git-over-HTTP push/pull, so leaving them off
means the token is structurally incapable of `git push`, no matter what
else it can do. (Git operations in this sandbox go over SSH by default
anyway, which the container has no credentials for at all — see
`DESIGN.md`.)

Save the token, and nothing else, to `~/.claude/gitlab-token` (chmod it
600). `claude-sandbox`/`claude-sandbox-proxy` read it fresh from the host
on every run and pass it in as `GITLAB_TOKEN`; it's never baked into the
image or a volume. Delete the file to revoke access.

## Local MCP servers registered on the host

Local/user-scoped MCP servers (`claude mcp add --scope local`) registered
against a repo live in your host's `~/.claude.json`, not the repo's own
tracked `.mcp.json` — invisible to the sandbox by default even though
you're clearly already trusting that tool for this exact repo. These get
mirrored in automatically, same token and all, keyed by the repo's path.
The corresponding host has to be reachable too — check `proxy/filter.allow`.

If you'd rather the sandbox use a **separate, independently revocable
token** for a given server instead of reusing your host one (recommended
for anything with real write access), add an override at
`~/.claude/sandbox-mcp-overrides.json`:

```json
{
  "/Users/you/projects/some-repo": {
    "server-name": {
      "type": "http",
      "url": "https://...",
      "headers": { "Authorization": "Bearer <sandbox-only-token>" }
    }
  }
}
```

An entry here replaces the mirrored config for that one server name;
anything not listed still just mirrors the host as before.

## `/ide` (IntelliJ integration)

If IntelliJ has the repo (or the worktree itself) open, `/ide` works from
inside the sandbox too — it picks up the matching `~/.claude/ide/*.lock`
file automatically. Unlike everything else here, this reaches back into
your host rather than out to an external service, so it's scoped as
narrowly as possible: only the one specific WebSocket port for the
matching IDE window is relayed (through the proxy sidecar, which is the
only thing that ever talks to `host.docker.internal`), not general access
to your host's localhost. See `DESIGN.md` for exactly how the relay works
if you're curious, or want to extend it (e.g. for another editor).

## `brainstorming` skill's visual companion

If you use the `brainstorming` skill (personal skills are shared in, see
above) and accept its visual companion, its browser mockup server works
from inside the sandbox: relayed through the proxy on a fixed port, so no
port-forwarding setup needed on your end. Nothing to configure — the
sandbox's own `CLAUDE.md` tells the agent to start the server with the
right flags for this environment. The reverse of `/ide`: there, the
container reaches back to your host; here, your host's browser reaches
*into* the container. One shared port across every concurrent task, so if
two sandbox sessions use it at the same moment, the second one wins — not
something you're likely to hit in practice, but worth knowing if a link
stops responding right after starting it elsewhere.

## Troubleshooting

- **"run this from inside the git repo you want to sandbox"** — you ran
  `claude-sandbox`/`claude-sandbox-proxy` from outside any git repo (or
  from inside this tool's own directory). `cd` into the target repo first.
- **"no known repo for task '...'"** from `grant-secret` — that task name
  was never started with `claude-sandbox`/`claude-sandbox-proxy`, or its
  state file under `~/.cache/claude-sandbox/state/` got removed.
- **"container ... is not running"** from `grant-secret` — the sandbox
  session for that task name has already exited; start a new one.
- **A build/tool needs a host that isn't reachable** — check
  `proxy/filter.allow` in this repo. It's a default-deny allowlist; add a
  line and re-run `docker compose up -d --build proxy` (from this repo) to
  pick it up. Consider whether the new host actually needs to be reachable
  from inside the sandbox at all before adding it.
- **Rebuilding the image** after changing `Dockerfile` happens
  automatically on the next `claude-sandbox`/`claude-sandbox-proxy` run.
- **Wiping subscription login** — `docker volume rm claude-sandbox-home`
  (you'll need to `/login` again on the next run).
