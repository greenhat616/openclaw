#!/usr/bin/env zsh
# OpenClaw Container Entrypoint
# Runs as the "openclaw" user.
# 1. Initialize home volume with skeleton files on first run
# 2. Install / update OpenClaw into $HOME (user-managed)
# 3. Source zsh startup chain
# 4. Start openclaw gateway (or user-provided command)

set -euo pipefail

HOME_DIR="${HOME:-/home/openclaw}"

# ── Fix volume ownership (named volumes mount as root) ─────────────────────
sudo chown -R openclaw:openclaw "${HOME_DIR}" 2>/dev/null || true

# ── Bootstrap minimal gateway config if missing ───────────────────────────
OPENCLAW_CONF="${HOME_DIR}/.openclaw/openclaw.json"
if [[ ! -f "$OPENCLAW_CONF" ]]; then
    cat > "$OPENCLAW_CONF" <<'CONF'
{
  // Minimal gateway config — edit as needed
  "gateway": {
    "mode": "local",
    "controlUi": {
      "dangerouslyAllowHostHeaderOriginFallback": true
    }
  }
}
CONF
fi

# ── Initialize home volume on first run ─────────────────────────────────────
INIT_MARKER="${HOME_DIR}/.openclaw-init-done"
if [[ ! -f "$INIT_MARKER" ]]; then
    echo "[entrypoint] first run — initializing home volume"
    cp -n /etc/skel.openclaw/.zshrc  "${HOME_DIR}/.zshrc"  2>/dev/null || true
    cp -n /etc/skel.openclaw/.zshenv "${HOME_DIR}/.zshenv" 2>/dev/null || true
    mkdir -p \
        "${HOME_DIR}/.openclaw/workspace" \
        "${HOME_DIR}/.openclaw/credentials" \
        "${HOME_DIR}/.local/bin" \
        "${HOME_DIR}/.cargo/bin" \
        "${HOME_DIR}/go/bin" \
        "${HOME_DIR}/.npm-global/bin" \
        "${HOME_DIR}/.npm-global/lib" \
        "${HOME_DIR}/.local/share/pnpm" \
        "${HOME_DIR}/.bun/bin" \
        "${HOME_DIR}/.deno/bin"
    touch "$INIT_MARKER"
fi

# ── Source zsh startup files (sets PATH, env vars) ─────────────────────────
for rcfile in \
    "${ZDOTDIR:-$HOME_DIR}/.zshenv" \
    "${ZDOTDIR:-$HOME_DIR}/.zprofile" \
    "${ZDOTDIR:-$HOME_DIR}/.zshrc" \
    "${ZDOTDIR:-$HOME_DIR}/.zlogin"; do
    if [[ -f "$rcfile" ]]; then
        echo "[entrypoint] sourcing $rcfile"
        source "$rcfile" 2>/dev/null || true
    fi
done

# ── Install / update OpenClaw (user-level, lives in $HOME) ────────────────
# NPM_CONFIG_PREFIX is set by .zshenv → ~/.npm-global
# openclaw binary lands in ~/.npm-global/bin/openclaw
if ! command -v openclaw &>/dev/null; then
    echo "[entrypoint] openclaw not found — installing into \$HOME (~/.npm-global) ..."
    npm install -g openclaw@latest
    echo "[entrypoint] openclaw installed: $(openclaw --version 2>/dev/null || echo 'unknown')"
else
    echo "[entrypoint] openclaw already installed: $(openclaw --version 2>/dev/null || echo 'unknown')"
    # Auto-update check (non-blocking, optional)
    if [[ "${OPENCLAW_AUTO_UPDATE:-false}" == "true" ]]; then
        echo "[entrypoint] checking for openclaw updates ..."
        npm update -g openclaw 2>/dev/null || true
    fi
fi

# ── Source .env if present ──────────────────────────────────────────────────
if [[ -f "${HOME_DIR}/.openclaw/.env" ]]; then
    echo "[entrypoint] loading ${HOME_DIR}/.openclaw/.env"
    set -a
    source "${HOME_DIR}/.openclaw/.env"
    set +a
fi

# ── Print environment summary ───────────────────────────────────────────────
echo "========================================"
echo " OpenClaw Container Environment"
echo " User: $(whoami) ($(id -u):$(id -g))"
echo "========================================"
echo " Node:     $(node --version 2>/dev/null || echo 'N/A')"
echo " npm:      $(npm --version 2>/dev/null || echo 'N/A')"
echo " pnpm:     $(pnpm --version 2>/dev/null || echo 'N/A')"
echo " Bun:      $(bun --version 2>/dev/null || echo 'N/A')"
echo " Deno:     $(deno --version 2>/dev/null | head -1 || echo 'N/A')"
echo " Python:   $(python3 --version 2>/dev/null || echo 'N/A')"
echo " uv:       $(uv --version 2>/dev/null || echo 'N/A')"
echo " Go:       $(go version 2>/dev/null || echo 'N/A')"
echo " Rust:     $(rustc --version 2>/dev/null || echo 'N/A')"
echo " gh:       $(gh --version 2>/dev/null | head -1 || echo 'N/A')"
echo " Clang:    $(clang --version 2>/dev/null | head -1 || echo 'N/A')"
echo " OpenClaw: $(openclaw --version 2>/dev/null || echo 'N/A')"
echo " Shell:    $(zsh --version 2>/dev/null || echo 'N/A')"
echo "----------------------------------------"
echo " q:        $(q --version 2>/dev/null || echo 'N/A')"
echo " tcping:   $(tcping --version 2>/dev/null | head -1 || echo 'N/A')"
echo " dig:      $(dig -v 2>&1 | head -1 || echo 'N/A')"
echo " nmap:     $(nmap --version 2>/dev/null | head -1 || echo 'N/A')"
echo " mtr:      $(mtr --version 2>/dev/null | head -1 || echo 'N/A')"
echo "========================================"

# ── Execute command with restart tolerance ─────────────────────────────────
# The gateway may restart itself (e.g., after `openclaw plugin install`).
# We allow up to MAX_RESTARTS rapid exits before giving up.  The counter
# resets after the process stays alive for STABLE_SECS, so only crash-loops
# trigger the limit — not intentional restarts after long uptime.
MAX_RESTARTS="${OPENCLAW_MAX_RESTARTS:-5}"
STABLE_SECS="${OPENCLAW_STABLE_SECS:-30}"
RESTART_DELAY="${OPENCLAW_RESTART_DELAY:-2}"
restart_count=0

echo "[entrypoint] executing: $@ (max rapid restarts: $MAX_RESTARTS)"

while true; do
    start_ts=$(date +%s)
    "$@"
    exit_code=$?
    elapsed=$(( $(date +%s) - start_ts ))

    # Process stayed up long enough → reset counter (healthy restart)
    if (( elapsed >= STABLE_SECS )); then
        restart_count=0
    fi

    restart_count=$(( restart_count + 1 ))

    if (( restart_count > MAX_RESTARTS )); then
        echo "[entrypoint] process crashed $restart_count times within ${STABLE_SECS}s — giving up (exit code: $exit_code)"
        exit $exit_code
    fi

    echo "[entrypoint] process exited (code=$exit_code, uptime=${elapsed}s) — restart $restart_count/$MAX_RESTARTS in ${RESTART_DELAY}s ..."
    sleep "$RESTART_DELAY"
done
