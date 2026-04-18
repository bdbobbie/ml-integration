#!/bin/bash

echo "Setting up ML Integration test environment..."

TEST_DATE=$(date +"%Y%m%d-%H%M%S")
TEST_ROOT="/Users/tbdoadmin/ML Integration/test-environment"
TEST_ENV_DIR="$TEST_ROOT/test-run-$TEST_DATE"

mkdir -p "$TEST_ENV_DIR/ml-integration-data"
mkdir -p "$TEST_ENV_DIR/vm-images"
mkdir -p "$TEST_ENV_DIR/logs"
mkdir -p "$TEST_ENV_DIR/reports"

export ML_INTEGRATION_TEST_ROOT="$TEST_ENV_DIR/ml-integration-data"

echo "Test environment ready: $TEST_ENV_DIR"
echo "ML_INTEGRATION_TEST_ROOT=$ML_INTEGRATION_TEST_ROOT"

echo "Starting ML Integration tests..."

cd "/Users/tbdoadmin/ML Integration"
export ML_INTEGRATION_TEST_ROOT
xcodebuild test -scheme "ML Integration" -destination "platform=macOS"
