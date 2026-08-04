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
