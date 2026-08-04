# Claude Code sandbox

Runs Claude Code in a Docker container scoped to a single git worktree of
whichever repo you point it at, with restricted filesystem and network
access. Design rationale and decisions: [`DESIGN.md`](DESIGN.md).

## Prerequisites

- Docker Desktop running.
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
