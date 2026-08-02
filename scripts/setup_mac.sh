#!/bin/bash
set -euo pipefail

if ! command -v brew >/dev/null 2>&1; then
  echo "Homebrew missing: install from https://brew.sh"
  exit 1
fi

brew install cmake ninja pkg-config sdl2 curl
