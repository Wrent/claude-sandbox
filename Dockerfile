# syntax=docker/dockerfile:1.10
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg git bash procps ripgrep \
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

RUN npm install -g @anthropic-ai/claude-code

ARG USER_UID=1000
RUN useradd -m -u "${USER_UID}" -s /bin/bash sandbox

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY CLAUDE.md /opt/sandbox/CLAUDE.md
RUN chmod +x /usr/local/bin/entrypoint.sh

ENV CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
ENV HOME=/home/sandbox
USER sandbox

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
