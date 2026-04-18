# ML Integration Test Environment

## Overview
This directory contains a comprehensive testing environment for the ML Integration app, providing isolated test roots, mock data, and automated testing infrastructure.

## Directory Structure

```
test-environment/
├── scripts/
│   ├── setup-test-env.sh      # Main environment setup script
│   ├── run-tests.sh           # Automated test runner
│   └── monitor-performance.sh  # Performance monitoring
├── fixtures/
│   └── test-scenarios.json    # Test case definitions
├── vm-images/                 # Mock ISO files for testing
├── logs/                      # Test execution logs
└── reports/                   # Test results and reports
```

## Quick Start

### 1. Set Up Test Environment
```bash
cd "/Users/tbdoadmin/ML Integration/test-environment"
./scripts/setup-test-env.sh
```

### 2. Run Tests
```bash
# Method 1: Use test runner
./scripts/run-tests.sh

# Method 2: Manual testing
export ML_INTEGRATION_TEST_ROOT="/path/to/test-environment/test-run-[timestamp]/ml-integration-data"
cd "/Users/tbdoadmin/ML Integration"
xcodebuild test -scheme "ML Integration" -destination "platform=macOS"
```

## Test Scenarios

The environment supports testing across these areas:

- **VM Provisioning**: Scaffold, install, start/stop lifecycle
- **Integration Services**: Shared resources, launchers, rootless apps
- **Health & Repair**: Diagnostics and automatic recovery
- **Security**: Keychain management and signature verification
- **Cleanup**: Uninstall with artifact removal
- **Performance**: Download speed and catalog refresh optimization

## Performance Monitoring

Performance is automatically monitored during test runs:
- CPU and memory usage tracking
- I/O operation timing
- Network request optimization verification
- Memory allocation patterns

## Isolation

The test environment uses `ML_INTEGRATION_TEST_ROOT` to ensure complete isolation from production data:
- Separate VM registry
- Isolated integration packages
- Independent observability logs
- Clean test artifacts

## Cleanup

Test data is automatically organized by timestamp:
```
test-run-20260417-171500/
├── ml-integration-data/     # App data
├── vm-images/               # Mock ISOs
├── logs/                    # Test logs
└── reports/                 # Test results
```

## Troubleshooting

### Common Issues
1. **Permission Denied**: Ensure scripts have execute permissions
2. **Missing Mock ISOs**: Run setup script to generate test data
3. **Test Root Conflicts**: Each run creates unique timestamped directories

### Environment Variables
- `ML_INTEGRATION_TEST_ROOT`: Points to isolated test data directory
- `TEST_RUN_ID`: Unique identifier for current test session

## Integration with CI/CD

The test environment is designed for CI/CD integration:
- Supports automated setup and teardown
- Generates machine-readable reports
- Provides performance metrics
- Isolates test runs completely
