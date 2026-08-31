# syntax=docker/dockerfile:1.10
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git bash procps ripgrep jq nano unzip socat \
        python3 python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Node.js: runtime for the Claude Code CLI itself. Installed early (ahead of
# Temurin and the cache-busted installers below) purely so the Chromium deps
# step right after it — which needs npx — sits as early in the layer stack
# as its own prerequisites allow, insulated from edits to those installers.
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# Headless Chromium (Playwright) system deps, for skills/scripts that drive a
# browser (e.g. the `run` skill's browser-driven app verification). No
# DAILY_CACHE_BUST here on purpose: this install is slow, and re-running it
# daily (or whenever an unrelated installer below changes) buys nothing —
# the pinned Playwright/Chromium version is fine to keep until something
# actually forces a rebuild of this layer. Needs root to apt-get the system
# libraries headless Chrome needs (nss, atk, at-spi, etc.), which the sandbox
# user never has — that part has to happen here, before the user switch. The
# browser binary itself is installed later, after switching to the sandbox
# user, so its cache lands under that user's own $HOME.
RUN npx -y playwright install-deps chromium

# Temurin 21 JDK: glibc-based, matches this repo's Kotlin/Gradle toolchain
# (Debian bookworm doesn't package Java 21 itself, not even in backports)
RUN curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb bookworm main" > /etc/apt/sources.list.d/adoptium.list \
    && apt-get update && apt-get install -y --no-install-recommends temurin-21-jdk \
    && rm -rf /var/lib/apt/lists/*

ARG USER_UID=1000
RUN useradd -m -u "${USER_UID}" -s /bin/bash sandbox
RUN mkdir -p /home/sandbox/.claude && chown -R sandbox:sandbox /home/sandbox/.claude

# Browser binary itself, as the sandbox user so its cache lands at
# /home/sandbox/.cache/ms-playwright with correct ownership already —
# fully pre-baked, no runtime network access needed for this at all.
# Headless Chrome needs --no-sandbox in this container regardless of the
# browser being present: `--cap-drop ALL` (see bin/lib.sh) means Chrome's
# own internal sandbox can't initialize — confirmed directly, it launches
# and renders correctly with --no-sandbox --disable-gpu. No DAILY_CACHE_BUST
# here either, matching install-deps chromium above — see that comment.
# Placed ahead of the cache-busted installers below (root switches back
# right after) on purpose: Docker's layer cache is sequential, so sitting
# downstream of a layer that changes daily forces this slow layer to
# reinstall daily too, regardless of its own content being unchanged —
# the same problem install-deps chromium above was already moved to avoid.
# HOME is set inline rather than via a global ENV so the root-run
# installers below don't inherit the sandbox user's home directory.
USER sandbox
RUN HOME=/home/sandbox npx -y playwright install chromium
USER root

# DAILY_CACHE_BUST forces the layers below to re-run periodically (see
# ensure_image in bin/lib.sh) — otherwise Docker's layer cache pins these
# tools to whatever version was installed the first time this image was
# built. The ARG must be referenced inside each RUN command itself, or
# Docker's cache key for that layer never changes and the bust is a no-op.
ARG DAILY_CACHE_BUST
RUN : "cache-bust ${DAILY_CACHE_BUST}" && npm install -g @anthropic-ai/claude-code@latest

# glab: GitLab CLI, used to read/comment on MRs and issues (see
# ~/.claude/gitlab-token handling in bin/lib.sh — never used for git push,
# only for glab's own API calls)
RUN : "cache-bust ${DAILY_CACHE_BUST}" \
    && GLAB_VERSION=$(curl -fsSL -o /dev/null -w '%{url_effective}' https://gitlab.com/gitlab-org/cli/-/releases/permalink/latest | sed 's#.*/v##') \
    && ARCH=$(dpkg --print-architecture) \
    && curl -fsSL -o /tmp/glab.deb "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${ARCH}.deb" \
    && dpkg -i /tmp/glab.deb \
    && rm /tmp/glab.deb

# OpenTofu (tofu): for validating Terraform config syntax (init/validate/fmt).
# Deliberately NOT given network access to GCP or the gcs backend — see
# proxy/filter.allow, only the provider registry is allowlisted. Good for
# `tofu init -backend=false` + `tofu validate`/`fmt`, not for plan/apply
# against real infrastructure.
RUN : "cache-bust ${DAILY_CACHE_BUST}" \
    && curl -fsSL https://get.opentofu.org/install-opentofu.sh -o /tmp/install-opentofu.sh \
    && chmod +x /tmp/install-opentofu.sh \
    && /tmp/install-opentofu.sh --install-method standalone \
    && rm /tmp/install-opentofu.sh

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY CLAUDE.md /opt/sandbox/CLAUDE.md
COPY statusline-command.sh /opt/sandbox/statusline-command.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /opt/sandbox/statusline-command.sh

# CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC is deliberately NOT set here.
# It reads as a harmless privacy tightening, but it also flips Claude Code's
# traffic mode to "essential-traffic", which switches off feature-flag
# (GrowthBook) evaluation wholesale. Remote Control is gated behind the
# `tengu_ccr_bridge` feature flag, so with the variable set that gate can
# never evaluate true and /remote-control refuses with "Remote Control
# requires feature-flag evaluation, which is disabled because
# CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC is set." Leaving it unset is what
# makes /remote-control usable in a sandbox session; the trade-off is that
# non-essential telemetry is on, the same as an ordinary host session.
# The flag set itself is fetched over api.anthropic.com (already allowed),
# so no extra host is needed to become *eligible*; connecting afterwards
# needs bridge.claudeusercontent.com — see proxy/filter.allow. Unsetting
# this also re-enables Claude Code's own auto-updater and its Datadog log
# shipping; the updater can't write the root-owned npm global dir (a
# harmless `claude doctor` warning — the image reinstalls the CLI on every
# DAILY_CACHE_BUST rebuild anyway), and the Datadog host is simply refused
# by the proxy's default-deny. Note this only ever applies to
# bin/claude-sandbox: bin/claude-sandbox-proxy sets ANTHROPIC_BASE_URL to
# the corporate LLM proxy, and Remote Control requires a direct
# api.anthropic.com connection, so it stays unavailable there regardless.
ENV HOME=/home/sandbox
ENV EDITOR=nano
ENV VISUAL=nano
USER sandbox

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude", "--permission-mode", "auto"]
