FROM ubuntu:24.04

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    jq \
    ca-certificates \
    unzip \
    && rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2
RUN curl "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o "awscliv2.zip" \
    && unzip awscliv2.zip \
    && ./aws/install \
    && rm -rf awscliv2.zip aws

# Install Claude Code CLI
RUN curl -fsSL https://claude.ai/install.sh | bash

# Add claude to PATH
ENV PATH="/root/.local/bin:${PATH}"

# Set working directory
WORKDIR /app

# Copy repository
COPY . .

# Environment variables
ENV CLAUDE_CONFIG_DIR="/root/.claude"
# Note: CLAUDE_CODE_OAUTH_TOKEN should be passed at runtime via docker run -e

# Default command - can be overridden
ENTRYPOINT ["claude"]
CMD ["--help"]
