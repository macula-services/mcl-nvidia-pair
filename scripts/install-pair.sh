#!/usr/bin/env bash
# Install NVIDIA PAIR on a headless Linux box, beside an Ollama that is already
# running there.
#
# WHY A SCRIPT AND NOT A PACKAGE: PAIR publishes a .deb, and the lab box is
# Arch, so the supported route on it is the services-only source build. This
# pins the release and the Go toolchain, installs Go without root, and builds
# the twelve Go binaries into services/build/bin/.
#
# WHAT IT DOES NOT DO: pair nodes, start the broker, or touch the Ollama that
# is already running. Those are separate steps (see docs/GETTING_STARTED.md),
# and the engine question — PAIR's Ollama facade wants 127.0.0.1:11434, which
# the existing Ollama already holds — is decided when the broker is started,
# not here.
#
#   PAIR_TAG=v1.0.0 ./scripts/install-pair.sh
#
# Idempotent: a second run reuses the Go toolchain and the checkout.
set -euo pipefail

PAIR_TAG=${PAIR_TAG:-v1.0.0}
GO_VERSION=${GO_VERSION:-go1.27.3}
GO_SHA256=${GO_SHA256:-65efbc80fdc1fa2cd2631cad5b481777a68e8725f34e89f50fc6ac714e379b40}
PAIR_HOME=${PAIR_HOME:-$HOME/pair}
GO_HOME=${GO_HOME:-$HOME/.local}
PAIR_REPO=${PAIR_REPO:-https://github.com/NVIDIA/Personal-AI-Router.git}

say() { printf '\n== %s\n' "$*"; }

# --- Go ---------------------------------------------------------------------
# PAIR needs Go 1.25 or newer. A distribution that has none (Arch without
# extra packages, a minimal image) gets the official tarball in the user's
# home, checksum-verified, and nothing outside it changes.
go_is_new_enough() {
    command -v go >/dev/null 2>&1 || return 1
    local have major minor
    have=$(go env GOVERSION 2>/dev/null | sed 's/^go//')
    major=${have%%.*}
    minor=${have#*.}
    minor=${minor%%.*}
    [ "${major:-0}" -gt 1 ] && return 0
    [ "${major:-0}" -eq 1 ] && [ "${minor:-0}" -ge 25 ]
}

install_go() {
    local dir="$GO_HOME/$GO_VERSION" tarball
    if [ -x "$dir/go/bin/go" ]; then
        echo "go $GO_VERSION already at $dir"
    else
        tarball=$(mktemp)
        echo "downloading $GO_VERSION"
        curl -fsSL "https://go.dev/dl/$GO_VERSION.linux-amd64.tar.gz" -o "$tarball"
        echo "$GO_SHA256  $tarball" | sha256sum -c - >/dev/null
        mkdir -p "$dir"
        tar -C "$dir" -xzf "$tarball"
        rm -f "$tarball"
    fi
    export PATH="$dir/go/bin:$PATH"
    go version
}

say "toolchain"
if go_is_new_enough; then
    go version
else
    install_go
fi

# --- PAIR -------------------------------------------------------------------
say "checkout $PAIR_TAG"
if [ -d "$PAIR_HOME/Personal-AI-Router/.git" ]; then
    git -C "$PAIR_HOME/Personal-AI-Router" fetch --tags --quiet
else
    mkdir -p "$PAIR_HOME"
    git clone --quiet "$PAIR_REPO" "$PAIR_HOME/Personal-AI-Router"
fi
git -C "$PAIR_HOME/Personal-AI-Router" checkout --quiet "$PAIR_TAG"
git -C "$PAIR_HOME/Personal-AI-Router" log -1 --format='%H %s'

# --- build ------------------------------------------------------------------
# The staged bundle must be rebuilt whole: running a component built from one
# revision beside the rest from another is what the upstream guide warns about.
say "build the services"
( cd "$PAIR_HOME/Personal-AI-Router/services" && ./build.sh )
ls -1 "$PAIR_HOME/Personal-AI-Router/services/build/bin"

say "done"
cat <<EOF
Binaries: $PAIR_HOME/Personal-AI-Router/services/build/bin
Next: start the broker (or nvpair-tui under tmux), then point this bridge's
chat_to_pair at the Ollama facade port PAIR actually serves.
EOF
