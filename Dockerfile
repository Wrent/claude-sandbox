# syntax=docker/dockerfile:1.10
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git bash procps ripgrep jq nano unzip socat \
    && rm -rf /var/lib/apt/lists/*

# Temurin 21 JDK: glibc-based, matches this repo's Kotlin/Gradle toolchain
# (Debian bookworm doesn't package Java 21 itself, not even in backports)
RUN curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb bookworm main" > /etc/apt/sources.list.d/adoptium.list \
    && apt-get update && apt-get install -y --no-install-recommends temurin-21-jdk \
    && rm -rf /var/lib/apt/lists/*

# Node.js: runtime for the Claude Code CLI itself
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

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

ARG USER_UID=1000
RUN useradd -m -u "${USER_UID}" -s /bin/bash sandbox
RUN mkdir -p /home/sandbox/.claude && chown -R sandbox:sandbox /home/sandbox/.claude

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY CLAUDE.md /opt/sandbox/CLAUDE.md
COPY statusline-command.sh /opt/sandbox/statusline-command.sh
RUN chmod +x /usr/local/bin/entrypoint.sh /opt/sandbox/statusline-command.sh

ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
ENV HOME=/home/sandbox
ENV EDITOR=nano
ENV VISUAL=nano
USER sandbox

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude", "--permission-mode", "auto"]
