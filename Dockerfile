FROM ubuntu:24.04

# Install dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

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
