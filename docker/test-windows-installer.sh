#!/usr/bin/env bash
set -euo pipefail

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker is required to run this script." >&2
  exit 1
fi

if [ $# -lt 1 ]; then
  echo "Usage: $0 release/<installer.exe>" >&2
  exit 1
fi

INSTALLER_REL="$1"
if [ ! -f "$INSTALLER_REL" ]; then
  echo "Installer not found: $INSTALLER_REL" >&2
  exit 1
fi

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INSTALLER_IN_CONTAINER="/project/${INSTALLER_REL#./}"

# Extract NSIS installer contents using 7z and verify structure (avoids Wine ARM issues).
echo "Extracting and verifying NSIS installer contents..."
docker run --rm \
  -v "$PROJECT_ROOT":/project \
  --name l7s-windows-installer-test \
  alpine:latest \
  sh -c "
    apk add --no-cache p7zip && \
    cd /project && \
    7z x -o/tmp/installer-test '$INSTALLER_IN_CONTAINER' -y > /dev/null && \
    echo '=== Extracted installer contents ===' && \
    ls -lh /tmp/installer-test/ && \
    echo '' && \
    echo '=== Verifying key files ===' && \
    test -f /tmp/installer-test/\\\$PLUGINSDIR/app-64.7z && echo '✓ Found app-64.7z (main application archive)' && \
    7z l /tmp/installer-test/\\\$PLUGINSDIR/app-64.7z | grep -E '(L7S Workflow Capture.exe|resources/app.asar)' && \
    echo '✓ Installer structure verified successfully'
  "
