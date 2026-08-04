#!/bin/bash
# One-shot copy of a single gitignored secret file into an already-running
# sandbox container. No restart, no lingering mount: the copy lives only in
# that container's ephemeral filesystem and is gone when it's torn down.
#
# Usage: grant-secret.sh <task-name> <path-relative-to-repo-root>
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

if [ $# -ne 2 ]; then
    echo "usage: $(basename "$0") <task-name> <path-relative-to-repo-root>" >&2
    exit 1
fi

NAME="$1"
REL_PATH="$2"
REPO_ROOT="$(load_repo_root "$NAME")"
SRC="$REPO_ROOT/$REL_PATH"
WT_PATH="$(worktree_path "$NAME" "$REPO_ROOT")"
CONTAINER="$(container_name "$NAME")"

if [ ! -f "$SRC" ]; then
    echo "error: $SRC does not exist" >&2
    exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    echo "error: container $CONTAINER is not running" >&2
    exit 1
fi

docker cp "$SRC" "$CONTAINER:${WT_PATH}/${REL_PATH}"
echo "copied $REL_PATH into $CONTAINER"
