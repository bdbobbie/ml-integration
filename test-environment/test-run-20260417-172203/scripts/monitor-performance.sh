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
