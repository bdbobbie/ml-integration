#!/bin/bash

# ML Integration Test Environment Setup Script
# This script creates an isolated test environment for ML Integration testing

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Setting up ML Integration Test Environment${NC}"

# Get the directory of this script
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
TEST_ROOT="$(dirname "$SCRIPT_DIR")"

# Create test root directory
TEST_DATE=$(date +"%Y%m%d-%H%M%S")
TEST_ENV_DIR="$TEST_ROOT/test-run-$TEST_DATE"
echo -e "${YELLOW}Creating test environment at: $TEST_ENV_DIR${NC}"

mkdir -p "$TEST_ENV_DIR"/{ml-integration-data,vm-images,logs,reports}

# Set environment variable for test isolation
export ML_INTEGRATION_TEST_ROOT="$TEST_ENV_DIR/ml-integration-data"
echo -e "${GREEN}✓ Set ML_INTEGRATION_TEST_ROOT=$ML_INTEGRATION_TEST_ROOT${NC}"

# Create mock ISO directory structure
mkdir -p "$TEST_ENV_DIR/vm-images"/{ubuntu,fedora,debian,opensuse,pop-os}

# Create test configuration
cat > "$TEST_ENV_DIR/test-config.json" << EOF
{
  "testEnvironment": {
    "root": "$TEST_ENV_DIR",
    "mlIntegrationData": "$ML_INTEGRATION_TEST_ROOT",
    "vmImagesPath": "$TEST_ENV_DIR/vm-images",
    "logsPath": "$TEST_ENV_DIR/logs",
    "reportsPath": "$TEST_ENV_DIR/reports"
  },
  "testScenarios": [
    "vm-provisioning",
    "integration-services",
    "health-checks",
    "cleanup-operations",
    "security-credentials"
  ]
}
EOF

echo -e "${GREEN}✓ Created test configuration${NC}"

# Create performance monitoring setup
cat > "$TEST_ENV_DIR/scripts/monitor-performance.sh" << 'EOF'
#!/bin/bash
# Performance monitoring script for ML Integration tests

TEST_DIR="$1"
if [ -z "$TEST_DIR" ]; then
    echo "Usage: $0 <test_directory>"
    exit 1
fi

echo "Starting performance monitoring for tests in: $TEST_DIR"

# Monitor CPU and memory usage
top -l 1 -n 0 > "$TEST_DIR/performance-before.log" 2>/dev/null &
TOP_PID=$!

# Function to cleanup monitoring
cleanup_monitoring() {
    kill $TOP_PID 2>/dev/null || true
    top -l 1 -n 0 > "$TEST_DIR/performance-after.log" 2>/dev/null
    echo "Performance monitoring completed"
}

trap cleanup_monitoring EXIT

echo "Monitoring started. Run your tests now."
EOF

chmod +x "$TEST_ENV_DIR/scripts/monitor-performance.sh"

# Create test runner script
cat > "$TEST_ENV_DIR/scripts/run-tests.sh" << 'EOF'
#!/bin/bash
# Comprehensive test runner for ML Integration

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
TEST_ROOT="$(dirname "$SCRIPT_DIR")"

# Load test configuration
if [ -f "$TEST_ROOT/test-config.json" ]; then
    TEST_CONFIG="$TEST_ROOT/test-config.json"
else
    echo "Test configuration not found!"
    exit 1
fi

echo "Loading test configuration from: $TEST_CONFIG"

# Set test environment
export ML_INTEGRATION_TEST_ROOT=$(jq -r '.testEnvironment.mlIntegrationData' "$TEST_CONFIG")

echo "Test environment configured:"
echo "  Root: $(jq -r '.testEnvironment.root' "$TEST_CONFIG")"
echo "  ML Integration Data: $ML_INTEGRATION_TEST_ROOT"
echo "  VM Images: $(jq -r '.testEnvironment.vmImagesPath' "$TEST_CONFIG")"
echo "  Logs: $(jq -r '.testEnvironment.logsPath' "$TEST_CONFIG")"
echo "  Reports: $(jq -r '.testEnvironment.reportsPath' "$TEST_CONFIG")"

# Run performance monitoring
"$SCRIPT_DIR/monitor-performance.sh" "$TEST_ROOT" &
MONITOR_PID=$!

# Function to cleanup
cleanup() {
    kill $MONITOR_PID 2>/dev/null || true
    echo "Test run completed. Check reports directory for results."
}
trap cleanup EXIT

echo "Test environment ready. You can now run ML Integration tests."
echo "Example: cd /Users/tbdoadmin/ML\ Integration && xcodebuild test -scheme \"ML Integration\" -destination \"platform=macOS\""

# Keep script alive to maintain monitoring
wait
EOF

chmod +x "$TEST_ENV_DIR/scripts/run-tests.sh"

echo -e "${GREEN}✓ Created test runner scripts${NC}"

# Create mock ISO files for testing
create_mock_iso() {
    local distro="$1"
    local size="$2"
    local iso_path="$TEST_ENV_DIR/vm-images/$distro/mock-$distro.iso"
    
    echo "Creating mock ISO for $distro ($size)..."
    dd if=/dev/zero of="$iso_path" bs=1M count="$size" 2>/dev/null
    echo -e "${GREEN}✓ Created mock ISO: $iso_path${NC}"
}

# Create mock ISOs of different sizes
create_mock_iso "ubuntu" 50
create_mock_iso "fedora" 60
create_mock_iso "debian" 45
create_mock_iso "opensuse" 55
create_mock_iso "pop-os" 48

echo -e "${BLUE}Test Environment Setup Complete!${NC}"
echo -e "${YELLOW}To start testing:${NC}"
echo "  cd $TEST_ENV_DIR && ./scripts/run-tests.sh"
echo ""
echo -e "${YELLOW}Test environment location:${NC}"
echo "  $TEST_ENV_DIR"
echo ""
echo -e "${YELLOW}Environment variable set:${NC}"
echo "  ML_INTEGRATION_TEST_ROOT=$ML_INTEGRATION_TEST_ROOT"
