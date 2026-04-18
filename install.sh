#!/bin/bash

# ML Integration Auto-Installer
# This script automatically extracts and installs ML Integration

set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${BLUE}ML Integration Auto-Installer${NC}"
echo -e "${GREEN}© 2026 TBDO Inc. All rights reserved.${NC}"
echo ""

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
APP_NAME="ML Integration.app"
TEMP_DIR="/tmp/ml-integration-install-$$"

# Create temporary directory
mkdir -p "$TEMP_DIR"

# Extract app from archive (this script is bundled with the app)
if [[ -f "$SCRIPT_DIR/$APP_NAME/Contents/MacOS/ML Integration" ]]; then
    echo -e "${GREEN}✓ Found ML Integration.app in archive${NC}"
    cp -R "$SCRIPT_DIR/$APP_NAME" "$TEMP_DIR/"
elif [[ -f "$SCRIPT_DIR/ML Integration.app/Contents/MacOS/ML Integration" ]]; then
    echo -e "${GREEN}✓ Found ML Integration.app in archive${NC}"
    cp -R "$SCRIPT_DIR/ML Integration.app" "$TEMP_DIR/"
else
    echo -e "${YELLOW}⚠ ML Integration.app not found in archive${NC}"
    exit 1
fi

# Check if app already exists
if [[ -d "/Applications/$APP_NAME" ]]; then
    echo -e "${YELLOW}⚠ ML Integration already exists in /Applications${NC}"
    read -p "Do you want to replace it? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Installation cancelled.${NC}"
        rm -rf "$TEMP_DIR"
        exit 0
    fi
    echo -e "${YELLOW}Removing existing installation...${NC}"
    rm -rf "/Applications/$APP_NAME"
fi

# Install to Applications
echo -e "${GREEN}Installing ML Integration to /Applications...${NC}"
mv "$TEMP_DIR/$APP_NAME" "/Applications/"

# Clean up
rm -rf "$TEMP_DIR"

# Set proper permissions
echo -e "${GREEN}Setting permissions...${NC}"
chmod -R 755 "/Applications/$APP_NAME"

# Security handling
echo -e "${YELLOW}Handling macOS security...${NC}"

# Remove quarantine attribute
xattr -d com.apple.quarantine "/Applications/$APP_NAME" 2>/dev/null || true

# Try to register with Launch Services
/System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister -f -R -trusted "/Applications/$APP_NAME" 2>/dev/null || true

echo -e "${GREEN}✓ Installation complete!${NC}"
echo ""
echo -e "${BLUE}To launch ML Integration:${NC}"
echo -e "  ${YELLOW}1. Double-click ML Integration.app in /Applications${NC}"
echo -e "  ${YELLOW}2. Or run: open '/Applications/ML Integration.app'${NC}"
echo ""
echo -e "${GREEN}© 2026 TBDO Inc. All rights reserved.${NC}"
