#!/usr/bin/env bash
# Fetches the local-only dependencies the integration suite needs:
#   - toxiproxy-server            (network fault injection)         -> .bin/
#   - a Python venv with asyncua  (reference OPC UA server/client)  -> .venv/
#   - node-opcua                  (reference OPC UA server/client)  -> servers/node_modules/
#
# Everything lands under test/integration/ and is gitignored. Re-runnable (idempotent).
# Usage:  bash test/integration/setup_local.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HERE/.bin"
VENV="$HERE/.venv"
TOXIPROXY_VERSION="v2.12.0"

mkdir -p "$BIN"

# ---- OS/arch detection ------------------------------------------------------
os="$(uname -s)"; arch="$(uname -m)"
case "$os" in
  Linux)  tp_os="linux" ;;
  Darwin) tp_os="darwin" ;;
  *) echo "Unsupported OS: $os" >&2; exit 1 ;;
esac
case "$arch" in
  x86_64|amd64) tp_arch="amd64" ;;
  arm64|aarch64) tp_arch="arm64" ;;
  *) echo "Unsupported arch: $arch" >&2; exit 1 ;;
esac

# ---- toxiproxy --------------------------------------------------------------
if [ ! -x "$BIN/toxiproxy-server" ]; then
  url="https://github.com/Shopify/toxiproxy/releases/download/${TOXIPROXY_VERSION}/toxiproxy-server-${tp_os}-${tp_arch}"
  echo "Downloading toxiproxy-server ($tp_os/$tp_arch) ..."
  curl -fsSL "$url" -o "$BIN/toxiproxy-server"
  chmod +x "$BIN/toxiproxy-server"
fi
echo "toxiproxy: $("$BIN/toxiproxy-server" --version 2>&1 | head -1)"

# ---- asyncua (Python) -------------------------------------------------------
if [ ! -d "$VENV" ]; then
  echo "Creating Python venv + installing asyncua ..."
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet asyncua
fi
echo "asyncua: $("$VENV/bin/python" -c 'import asyncua; print(asyncua.__version__)')"

# ---- node-opcua (JS) --------------------------------------------------------
if command -v npm >/dev/null 2>&1; then
  if [ ! -d "$HERE/servers/node_modules/node-opcua" ]; then
    echo "Installing node-opcua ..."
    ( cd "$HERE/servers" && npm install --silent --no-audit --no-fund node-opcua@2 )
  fi
  echo "node-opcua: installed"
else
  echo "npm not found; skipping node-opcua (node-opcua tests will be skipped)"
fi

echo "Local integration dependencies ready."
