---
name: Bug Report
about: Create a report to help us improve
title: "[BUG] "
labels: ["bug"]
assignees: ""

---

## 🐛 Bug Description
A clear and concise description of what the bug is.

## 🔄 Reproduction Steps
Please provide detailed steps to reproduce the behavior:

1. Go to '...'
2. Click on '....'
3. Scroll down to '....'
4. See error

## ✅ Expected Behavior
A clear and concise description of what you expected to happen.

## ❌ Actual Behavior
A clear and concise description of what actually happened.

## 🖥️ Environment Information
- **macOS Version**: 
- **Host Architecture**: Apple Silicon / Intel
- **ML Integration Version**: 
- **Linux Distribution**: (if applicable)
- **Runtime Engine**: Apple Virtualization / QEMU

## 📋 System Information
- **CPU Cores**: 
- **Memory**: 
- **Disk Space**: 

## 📝 Additional Context
Add any other context about the problem here.

## 📎 Attachments
Please include:
- Screenshots if applicable
- Logs from `~/Library/Containers/com.tbdo.ML-Integration/Data/Library/Application Support/MLIntegration/observability/`
- VM configuration files (if relevant)

## 🔧 Diagnostics
Run the following commands and include the output:
```bash
# Check virtualization support
sysctl -n hw.optional.arm64  # for Apple Silicon
sysctl -n hw.optional.x86_64  # for Intel

# Check VM status
# (Include any relevant VM status information)
```
