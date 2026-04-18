#!/bin/bash

# Quick setup for ML Integration testing
set -euo pipefail

GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}Setting up ML Integration Test Environment${NC}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
TEST_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_DATE=$(date +"%Y%m%d-%H%M%S")
TEST_ENV_DIR="$TEST_ROOT/test-run-$TEST_DATE"

echo -e "${GREEN}Creating test environment at: $TEST_ENV_DIR${NC}"

mkdir -p "$TEST_ENV_DIR"/{ml-integration-data,vm-images,logs,reports,scripts})

export ML_INTEGRATION_TEST_ROOT="$TEST_ENV_DIR/ml-integration-data"
echo -e "${GREEN}✓ Set ML_INTEGRATION_TEST_ROOT=$ML_INTEGRATION_TEST_ROOT${NC}"

# Create simple test runner
cat > "$TEST_ENV_DIR/scripts/run-tests.sh" << 'EOF'
#!/bin/bash
echo "Test environment ready!"
echo "ML_INTEGRATION_TEST_ROOT=$ML_INTEGRATION_TEST_ROOT"
echo "Starting ML Integration tests..."

cd "/Users/tbdoadmin/ML Integration"
export ML_INTEGRATION_TEST_ROOT
xcodebuild test -scheme "ML Integration" -destination "platform=macOS"
EOF

chmod +x "$TEST_ENV_DIR/scripts/run-tests.sh"

echo -e "${GREEN}✓ Test environment ready!${NC}"
echo -e "${BLUE}To run tests:${NC}"
echo "  cd $TEST_ENV_DIR && ./scripts/run-tests.sh"
