FROM ubuntu:24.04

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    jq \
    ca-certificates \
    unzip \
    python3-pip \
    python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip" \
    && unzip awscliv2.zip \
    && ./aws/install \
    && rm -rf awscliv2.zip aws

# Install Node.js
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y nodejs

# Install GitHub CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
    && apt-get update \
    && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# Install kubectl
RUN ARCH=$(dpkg --print-architecture) \
    && curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/${ARCH}/kubectl" \
    && chmod +x kubectl \
    && mv kubectl /usr/local/bin/

# Install Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code

# Set working directory
WORKDIR /app

# Copy repository
COPY . .

# Setup entrypoint script
RUN mv entrypoint.sh / && chmod +x /entrypoint.sh

# Environment variables
ENV CLAUDE_CONFIG_DIR="/root/.claude"
# Note: CLAUDE_CODE_OAUTH_TOKEN should be passed at runtime via docker run -e

# Default command - can be overridden
ENTRYPOINT ["/entrypoint.sh", "claude"]
CMD ["--help"]
