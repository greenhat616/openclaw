# OpenClaw All-in-One Build & Deploy Image
# Includes: Node 22+, Bun, Deno, Python3, uv, pnpm, Go, Rust, LLVM, gh CLI, zsh
# OpenClaw itself is installed at runtime into $HOME (user-managed updates).

FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG NODE_MAJOR=22
ARG GO_VERSION=1.23.4
ARG LLVM_VERSION=18
ARG OPENCLAW_UID=1000
ARG OPENCLAW_GID=1000

# ── 1. System packages + build essentials + zsh + LLVM ──────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Build essentials
    build-essential cmake ninja-build pkg-config autoconf automake libtool \
    gcc g++ make gdb valgrind \
    # LLVM / Clang
    llvm-${LLVM_VERSION} clang-${LLVM_VERSION} lld-${LLVM_VERSION} \
    lldb-${LLVM_VERSION} clang-format-${LLVM_VERSION} clang-tidy-${LLVM_VERSION} \
    # Shell & utilities
    zsh curl wget git unzip zip tar xz-utils jq sudo \
    ca-certificates gnupg lsb-release software-properties-common \
    openssh-client rsync htop tmux vim nano \
    # Python 3
    python3 python3-pip python3-venv python3-dev \
    # ── Network / DNS / diagnostic tools ──
    dnsutils bind9-host \
    iputils-ping iputils-tracepath \
    iproute2 net-tools \
    traceroute mtr-tiny \
    nmap netcat-openbsd \
    tcpdump \
    whois \
    socat \
    # Misc libs
    libssl-dev libffi-dev zlib1g-dev libreadline-dev libbz2-dev \
    libsqlite3-dev libncurses-dev liblzma-dev libxml2-dev libxslt-dev \
    && rm -rf /var/lib/apt/lists/*

# Symlink LLVM tools to unversioned names
RUN for tool in clang clang++ clang-format clang-tidy llvm-config lld lldb; do \
      if [ -f /usr/bin/${tool}-${LLVM_VERSION} ]; then \
        update-alternatives --install /usr/bin/${tool} ${tool} /usr/bin/${tool}-${LLVM_VERSION} 100; \
      fi; \
    done

# ── 2. Node.js (via NodeSource) ─────────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && corepack enable

# ── 3. Bun → /opt/bun (system-level binary) ────────────────────────────────
ENV BUN_INSTALL="/opt/bun"
RUN curl -fsSL https://bun.sh/install | bash \
    && chmod -R a+rx /opt/bun
ENV PATH="${BUN_INSTALL}/bin:${PATH}"

# ── 4. Deno → /opt/deno (system-level binary) ──────────────────────────────
ENV DENO_INSTALL="/opt/deno"
RUN curl -fsSL https://deno.land/install.sh | sh \
    && chmod -R a+rx /opt/deno
ENV PATH="${DENO_INSTALL}/bin:${PATH}"

# ── 5. Go SDK → /usr/local/go ──────────────────────────────────────────────
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:${PATH}"

# ── 6. Rust toolchain → /opt/rust (shared, read-only at runtime) ───────────
ENV RUSTUP_HOME="/opt/rust/rustup"
ENV CARGO_HOME="/opt/rust/cargo"
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
    && chmod -R a+rx /opt/rust
ENV PATH="${CARGO_HOME}/bin:${PATH}"

# ── 7. GitHub CLI (gh) ─────────────────────────────────────────────────────
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y gh \
    && rm -rf /var/lib/apt/lists/*

# ── 8. uv (Python package manager) ─────────────────────────────────────────
RUN curl -LsSf https://astral.sh/uv/install.sh | env CARGO_HOME=/tmp/uv-install UV_INSTALL_DIR=/usr/local/bin sh \
    && rm -rf /tmp/uv-install

# ── 9. pnpm (global, system-level binary) ──────────────────────────────────
RUN npm install -g pnpm

# ── 10. q (modern DNS client) + tcping → /usr/local/bin ────────────────────
RUN GOPATH=/tmp/go-build \
    && go install github.com/natesales/q@latest \
    && go install github.com/cloverstd/tcping@latest \
    && cp /tmp/go-build/bin/q /usr/local/bin/q \
    && cp /tmp/go-build/bin/tcping /usr/local/bin/tcping \
    && rm -rf /tmp/go-build

# ── 11. Create openclaw user ──────────────────────────────────────────────
RUN groupadd -g ${OPENCLAW_GID} openclaw \
    && useradd -m -u ${OPENCLAW_UID} -g ${OPENCLAW_GID} -s /usr/bin/zsh openclaw \
    && echo "openclaw ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/openclaw

# ── 12. Skeleton zsh config (copied into home volume on first run) ─────────
RUN mkdir -p /etc/skel.openclaw
COPY zshrc.default  /etc/skel.openclaw/.zshrc
COPY zshenv.default /etc/skel.openclaw/.zshenv

# ── 13. Entrypoint ─────────────────────────────────────────────────────────
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# ── Switch to openclaw user ────────────────────────────────────────────────
USER openclaw
WORKDIR /home/openclaw

EXPOSE 18789

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["openclaw", "gateway", "run", "--port", "18789", "--bind", "lan", "--verbose"]
