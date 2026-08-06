#!/bin/bash
set -euo pipefail

# Daemon coordination files that live directly under ~/.claude (not in
# their own directory, so a tmpfs mount can't target just them) — redirect
# to the private tmpfs at ~/.claude-runtime so concurrent containers on the
# shared claude-sandbox-home volume can't clobber each other's daemon
# state. See the --tmpfs comment in bin/lib.sh for the full story.
mkdir -p "$HOME/.claude-runtime"
for f in daemon.lock daemon.log daemon.status.json history.jsonl; do
    ln -sf "$HOME/.claude-runtime/$f" "$HOME/.claude/$f"
done

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

# Local/user-scoped MCP servers (claude mcp add --scope local) registered
# against this repo on the host — see the HOST_CLAUDE_JSON comment in
# bin/lib.sh for why these aren't visible by default. Synced every start,
# keyed by the same repo-root path string on both sides. Sandbox-only
# overrides (separate, independently revocable tokens) replace individual
# server entries by name — see the SANDBOX_MCP_OVERRIDES comment in bin/lib.sh.
if [ -f /opt/host-settings/claude.json ]; then
    node -e "
        const fs = require('fs');
        const path = '$HOME/.claude.json';
        const repoRoot = process.env.HOST_REPO_ROOT;
        const hostConfig = JSON.parse(fs.readFileSync('/opt/host-settings/claude.json', 'utf8'));
        const config = JSON.parse(fs.readFileSync(path, 'utf8'));
        let changed = false;

        if (repoRoot) {
            const hostProject = hostConfig.projects && hostConfig.projects[repoRoot];
            const mcpServers = Object.assign({}, hostProject && hostProject.mcpServers);
            const overridesPath = '/opt/host-settings/sandbox-mcp-overrides.json';
            if (fs.existsSync(overridesPath)) {
                const overrides = JSON.parse(fs.readFileSync(overridesPath, 'utf8'));
                Object.assign(mcpServers, overrides[repoRoot]);
            }
            if (Object.keys(mcpServers).length > 0) {
                config.projects = config.projects || {};
                config.projects[repoRoot] = config.projects[repoRoot] || {};
                config.projects[repoRoot].mcpServers = mcpServers;
                changed = true;
            }
        }

        // deepLinkTerminal: set once Claude Code detects the terminal
        // (TERM_PROGRAM) during onboarding — the sandbox's own .claude.json
        // was seeded from a backup taken before that detection ran (see
        // bin/lib.sh's TERM_PROGRAM comment), so it never got set here even
        // though the container now sees the same TERM_PROGRAM as the host.
        // Mirroring it directly is what actually enables the Shift+Enter-
        // for-newline keybinding instead of submitting.
        if (hostConfig.deepLinkTerminal && config.deepLinkTerminal !== hostConfig.deepLinkTerminal) {
            config.deepLinkTerminal = hostConfig.deepLinkTerminal;
            changed = true;
        }

        if (changed) fs.writeFileSync(path, JSON.stringify(config, null, 2));
    "
fi

# Seed the status line on first run of a fresh volume (left alone once
# already set), always sync enabledPlugins/extraKnownMarketplaces from the
# host's settings.json (if mounted) so installed plugins/skills — e.g. glab
# — match the host on every start, not just the first one, and always
# ensure the mutating-YouTrack-tool permission gate below is present. This
# is a sandbox-only safety policy, not synced from the host — you don't
# want this friction on your normal host sessions, only here, since
# --permission-mode auto (see Dockerfile) skips the normal approval prompt
# for everything else. Union with any ask rules already there (e.g.
# user-added ones) rather than overwriting, so nothing gets silently lost.
node -e "
    const fs = require('fs');
    const path = '$HOME/.claude/settings.json';
    const hostSettingsPath = '/opt/host-settings/settings.json';
    let settings = {};
    if (fs.existsSync(path)) settings = JSON.parse(fs.readFileSync(path, 'utf8'));
    if (!settings.statusLine) {
        settings.statusLine = { type: 'command', command: 'bash /opt/sandbox/statusline-command.sh' };
    }
    if (fs.existsSync(hostSettingsPath)) {
        const hostSettings = JSON.parse(fs.readFileSync(hostSettingsPath, 'utf8'));
        if (hostSettings.enabledPlugins) settings.enabledPlugins = hostSettings.enabledPlugins;
        if (hostSettings.extraKnownMarketplaces) settings.extraKnownMarketplaces = hostSettings.extraKnownMarketplaces;
    }
    const mutatingYoutrackTools = [
        'create_issue', 'update_issue', 'add_comment', 'apply_command', 'log_work',
        'create_project', 'update_project', 'add_project_member',
        'create_user', 'update_user', 'delete_user', 'add_user_to_group', 'remove_user_from_group',
    ];
    settings.permissions = settings.permissions || {};
    const ask = new Set(settings.permissions.ask || []);
    mutatingYoutrackTools.forEach(t => ask.add('mcp__youtrack-mcp__' + t));
    settings.permissions.ask = Array.from(ask);
    fs.writeFileSync(path, JSON.stringify(settings, null, 2));
"

# Installed plugins (glab, etc.) record their install path as an absolute
# HOST path in installed_plugins.json/known_marketplaces.json — see the
# HOST_PLUGINS_DIR comment in bin/lib.sh for why. That content is mounted
# at the host's own path, not the container's; symlink the two state files
# into this container's own ~/.claude/plugins so Claude Code finds them
# where it actually looks, while the absolute paths inside them still
# resolve since the underlying content is reachable at that same path.
if [ -n "${HOST_HOME_PATH:-}" ] && [ -f "${HOST_HOME_PATH}/.claude/plugins/installed_plugins.json" ]; then
    mkdir -p "$HOME/.claude/plugins"
    ln -sf "${HOST_HOME_PATH}/.claude/plugins/installed_plugins.json" "$HOME/.claude/plugins/installed_plugins.json"
    ln -sf "${HOST_HOME_PATH}/.claude/plugins/known_marketplaces.json" "$HOME/.claude/plugins/known_marketplaces.json"
fi

exec "$@"
