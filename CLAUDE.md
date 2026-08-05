# Sandbox environment notes

You are running inside an isolated Docker sandbox with a deliberately
narrow view of the host:

- You only see one git worktree, not the rest of the developer's projects.
- `.env` files and other gitignored credential files are absent by design
  — they are not copied into git worktrees.
- There is no git remote credential in this container. Do not attempt
  `git push`, `git fetch`, or `git pull` — they will fail with an auth
  error. Pushing and fetching are done by the user on their host; just
  commit locally and tell them what's ready to push.
- Network access is restricted to an explicit allowlist (LLM proxy,
  Anthropic API, public package registries). Anything else will time out
  or fail to connect — that's expected, not a bug to work around.

## Report permission/access problems immediately — don't work around them

This sandbox is in an early PoC phase. If anything is blocked — a host
not on the network allowlist, a denied filesystem/tool permission, a
missing credential, a command that fails because of the sandbox's
restrictions rather than a real bug in the code — **stop and report it to
the user immediately**, with the exact command/error. The user can
usually fix the actual restriction (add a host to the allowlist, grant a
credential, adjust a mount) in a minute or two, and would rather do that
than have you route around it.

Do not: retry with reduced scope, switch to a different tool/mirror/host
to dodge the restriction, silently skip the step, or fabricate a
workaround. Even a "successful" workaround defeats the point of a PoC
whose whole purpose is to surface exactly which restrictions need
adjusting.

One exception: mutating YouTrack MCP tools (`create_issue`, `update_issue`,
`add_comment`, etc.) are deliberately gated behind a permission prompt even
in auto mode — that one's intentional, not a sandbox restriction to report.
Just wait for the approval like normal.

Another: `tofu` (OpenTofu) is installed for validating Terraform config
(`tofu init -backend=false`, `validate`, `fmt`) but deliberately cannot
reach GCP or the `gcs` backend at all — real infrastructure and state stay
out of reach on purpose. `plan`/`apply` against real infra, or any command
that touches the configured backend, will fail to connect; that's the
intended boundary, not something to fix by finding a way around it.

## Missing credential files

If a command fails because a gitignored `.env`/credential file is missing,
do not try to work around it (don't fabricate one, don't skip the step
silently). Instead, run `echo $GRANT_SECRET_HINT` to get the exact host
command for this session, and tell the user to run it followed by the
path of the missing file, relative to the repo root — e.g. if the hint is
`/Users/you/claude-code-sandbox/bin/grant-secret.sh my-task`, tell them to
run:

    /Users/you/claude-code-sandbox/bin/grant-secret.sh my-task pm/.env

This copies that one file into your container without restarting your
session. Once they confirm they've run it, retry the command.
