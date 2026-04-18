#!/bin/bash

# ML Integration Test Environment Cleanup Script

set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Cleaning ML Integration Test Environment${NC}"

if [ -z "${ML_INTEGRATION_TEST_ROOT:-}" ]; then
    echo -e "${YELLOW}Warning: ML_INTEGRATION_TEST_ROOT not set${NC}"
    echo "Cleaning default test directories..."
    BASE_DIR="/Users/tbdoadmin/ML Integration/test-environment"
else
    BASE_DIR="$(dirname "$ML_INTEGRATION_TEST_ROOT")"
fi

# Function to cleanup directory
cleanup_dir() {
    local dir="$1"
    local description="$2"
    
    if [ -d "$dir" ]; then
        echo -e "${YELLOW}Cleaning $description...${NC}"
        rm -rf "$dir"
        echo -e "${GREEN}✓ Cleaned $description${NC}"
    else
        echo -e "${GREEN}✓ $description already clean${NC}"
    fi
}

# Cleanup test directories
cleanup_dir "$BASE_DIR/test-run-"* "Old test runs"
cleanup_dir "$BASE_DIR/ml-integration-data" "ML Integration data"
cleanup_dir "$BASE_DIR/vm-images" "VM images"
cleanup_dir "$BASE_DIR/logs" "Test logs"
cleanup_dir "$BASE_DIR/reports" "Test reports"

# Clear environment variable
unset ML_INTEGRATION_TEST_ROOT

echo -e "${GREEN}Test environment cleanup complete!${NC}"
