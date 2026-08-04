#!/bin/bash
set -euo pipefail

# Global CLAUDE.md: sandbox-notes (baked into the image) plus, if mounted,
# your real personal CLAUDE.md from the host — regenerated every start since
# neither source is something the running session itself edits.
mkdir -p "$HOME/.claude"
if [ -f /opt/host-claude-md/CLAUDE.md ]; then
    cat /opt/sandbox/CLAUDE.md /opt/host-claude-md/CLAUDE.md > "$HOME/.claude/CLAUDE.md"
else
    cp /opt/sandbox/CLAUDE.md "$HOME/.claude/CLAUDE.md"
fi

# ~/.claude.json (oauth account, onboarding-completion flags) lives outside
# the persisted .claude/ volume, so a fresh container never sees it and
# reruns the full onboarding wizard + login every time. Symlink it into the
# persisted tree so it survives across runs like everything else under .claude/.
ln -sf "$HOME/.claude/.claude.json" "$HOME/.claude.json"

# Seed the status line on first run of a fresh volume, same as CLAUDE.md
# above; leaves it alone (and any other settings) once already set.
node -e "
    const fs = require('fs');
    const path = '$HOME/.claude/settings.json';
    let settings = {};
    if (fs.existsSync(path)) settings = JSON.parse(fs.readFileSync(path, 'utf8'));
    if (!settings.statusLine) {
        settings.statusLine = { type: 'command', command: 'bash /opt/sandbox/statusline-command.sh' };
        fs.writeFileSync(path, JSON.stringify(settings, null, 2));
    }
"

exec "$@"
