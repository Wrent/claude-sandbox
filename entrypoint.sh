#!/bin/bash
set -euo pipefail

# Seed the sandbox identity's global CLAUDE.md on first run of a fresh
# persistent volume; a populated volume from a prior run is left untouched.
mkdir -p "$HOME/.claude"
if [ ! -f "$HOME/.claude/CLAUDE.md" ]; then
    cp /opt/sandbox/CLAUDE.md "$HOME/.claude/CLAUDE.md"
fi

exec "$@"
