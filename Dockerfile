FROM elixir:1.19-alpine AS builder

# Install build dependencies
RUN apk add --no-cache build-base git curl python3

# Install hex + rebar
RUN mix local.hex --force && \
    mix local.rebar --force

ENV MIX_ENV=prod

WORKDIR /app

# Install dependencies first (for caching)
COPY elixir/mix.exs elixir/mix.lock ./elixir/
RUN cd elixir && mix deps.get --only prod

# Copy the rest of the elixir codebase
COPY elixir/ ./elixir/

# Build the escript
RUN cd elixir && \
    mix deps.compile && \
    mix escript.build

# Release image
FROM elixir:1.19-alpine

# Install runtime dependencies including nodejs, bash, and git (useful for codex tasks)
RUN apk add --no-cache \
    bash \
    git \
    curl \
    python3 \
    nodejs \
    npm

# Install the real Codex CLI with app-server support.
ARG CODEX_VERSION=0.111.0
RUN npm install -g "@openai/codex@${CODEX_VERSION}" && \
    codex --version

WORKDIR /app

# Copy the built escript from builder
COPY --from=builder /app/elixir/bin/symphony /usr/local/bin/symphony
RUN chmod +x /usr/local/bin/symphony

# Provide a default execution command for the orchestrator
CMD ["symphony", "--i-understand-that-this-will-be-running-without-the-usual-guardrails"]
