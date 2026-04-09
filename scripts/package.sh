#!/usr/bin/env bash
# ==============================================================================
# Package the Function App code into a ZIP for WEBSITE_RUN_FROM_PACKAGE deployment.
#
# Output: dist/function-app-v<VERSION>.zip
# Usage:  ./scripts/package.sh [version]
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SRC_DIR="$PROJECT_ROOT/src"
DIST_DIR="$PROJECT_ROOT/dist"

VERSION="${1:-$(date +%Y%m%d-%H%M%S)}"
ZIP_NAME="function-app-v${VERSION}.zip"

echo "=== Packaging Function App ==="
echo "Source:  $SRC_DIR"
echo "Version: $VERSION"
echo "Output:  $DIST_DIR/$ZIP_NAME"
echo ""

# Create dist directory
mkdir -p "$DIST_DIR"

# Create a clean temp directory for packaging
TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

# Copy Function App code
cp -r "$SRC_DIR"/* "$TEMP_DIR/"

# Remove local dev files
rm -f "$TEMP_DIR/local.settings.json"
rm -f "$TEMP_DIR/local.settings.json.template"
rm -rf "$TEMP_DIR/__pycache__"
find "$TEMP_DIR" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
find "$TEMP_DIR" -name "*.pyc" -delete 2>/dev/null || true

# Create the ZIP
cd "$TEMP_DIR"
zip -r "$DIST_DIR/$ZIP_NAME" . -x "*.pyc" "__pycache__/*"

echo ""
echo "=== Package created: $DIST_DIR/$ZIP_NAME ==="
echo "Size: $(du -h "$DIST_DIR/$ZIP_NAME" | cut -f1)"
echo ""
echo "To deploy this package:"
echo "  1. Upload to a publicly accessible URL (Azure Blob Storage, GitHub Release)"
echo "  2. Set the packageUrl parameter in your Bicep deployment to the URL"
echo "  3. Or use: az functionapp deployment source config-zip \\"
echo "       --resource-group <rg> --name <func-name> --src $DIST_DIR/$ZIP_NAME"
