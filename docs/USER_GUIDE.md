# ML Integration User Guide

## 🚀 Getting Started

Welcome to ML Integration - your comprehensive solution for running Linux virtual machines on macOS with seamless integration and management.

### Quick Start
1. **Install**: Download `ML Integration.app` from the latest [GitHub release](https://github.com/bdbobbie/ml-integration/releases)
2. **Launch**: Open the app from your Applications folder
3. **Setup**: Follow the initial configuration wizard
4. **Create VM**: Choose your Linux distribution and create your first VM

## 🖥️ Main Interface

### Dashboard Overview
- **Host Profile**: System information and virtualization capabilities
- **VM Management**: Active VMs, runtime states, and resource usage
- **Catalog Browser**: Available Linux distributions and versions
- **Integration Settings**: Shared resources and launcher configuration
- **Health Monitor**: VM health status and auto-repair options
- **Observability**: Operation logs and performance metrics

### Key Components

#### 1. VM Provisioning
- **Distro Selection**: Ubuntu, Fedora, Debian, openSUSE, Pop!_OS
- **Architecture Support**: Apple Silicon and Intel Macs
- **Runtime Options**: Apple Virtualization.framework or QEMU fallback
- **Resource Configuration**: CPU cores, memory, disk allocation

#### 2. Integration Services
- **Shared Resources**: File sharing, clipboard integration
- **Launchers**: Quick access to Linux applications from macOS
- **Rootless Apps**: Linux app windows without full desktop environment
- **Package Management**: Automatic generation of integration packages

#### 3. Health & Auto-Heal
- **Health Checks**: Automated VM diagnostics
- **Auto-Repair**: Common issue detection and resolution
- **Package Regeneration**: Health-based integration package updates
- **Rollback**: Automatic rollback points for failed operations

#### 4. Security & Credentials
- **Keychain Storage**: Secure GitHub token management
- **Signature Verification**: GPG signature validation for distro images
- **Diagnostics**: Secure logging without exposing sensitive data
- **Escalation**: Built-in GitHub issue creation and email support

#### 5. Cleanup Operations
- **Uninstall**: Complete VM removal with artifact cleanup
- **Registry Management**: Persistent VM state management
- **Receipt Verification**: Post-cleanup validation and reporting
- **Trace Removal**: Ensuring no leftover artifacts

## 📋 Workflows

### Creating a New VM
1. **Select Distribution**: Choose from catalog or provide custom ISO
2. **Configure Resources**: Set CPU, memory, and disk allocation
3. **Choose Runtime**: Select Apple Virtualization or QEMU
4. **Start Provisioning**: Begin VM scaffold creation
5. **Monitor Progress**: Track installation through lifecycle states
6. **Launch VM**: Start using runtime controls
7. **Configure Integration**: Set up shared resources and launchers

### Managing VMs
- **Start/Stop**: Control VM runtime state from dashboard
- **Restart**: Quick VM restart with state preservation
- **Health Checks**: Run diagnostics and view health reports
- **Auto-Heal**: Apply automatic repairs when issues detected
- **Resource Monitoring**: Track CPU, memory, and disk usage

### Integration Workflow
1. **Configure Sharing**: Set up shared folders and clipboard
2. **Generate Launchers**: Create macOS shortcuts to Linux apps
3. **Enable Rootless**: Configure Linux app window integration
4. **Test Integration**: Verify seamless app launching
5. **Update Packages**: Regenerate integration packages as needed

### Maintenance Tasks
- **Catalog Refresh**: Update distro catalog automatically
- **Health Monitoring**: Schedule regular VM health checks
- **Cleanup**: Remove unused VMs and temporary files
- **Backup**: Export VM configurations for backup
- **Update**: Keep app and VM definitions current

## 🔧 Advanced Configuration

### Performance Optimization
- **Buffer Settings**: Adjust download and I/O buffer sizes
- **Caching**: Configure catalog and artifact caching
- **Resource Limits**: Set appropriate CPU and memory limits
- **Network Settings**: Configure proxies and download mirrors

### Security Settings
- **Keychain Access**: Configure secure credential storage
- **Signature Verification**: Enable/disable signature checking
- **Network Security**: Configure secure download options
- **VM Isolation**: Set up network and file system isolation

### Troubleshooting
- **Logs**: Access comprehensive operation logs
- **Diagnostics**: Run built-in diagnostic tools
- **Reset**: Reset configurations to defaults
- **Safe Mode**: Boot with minimal features for troubleshooting
- **Escalation**: Contact support directly from app

## 📊 Monitoring & Analytics

### Performance Metrics
- **VM Creation Time**: Track time to create new VMs
- **Resource Usage**: Monitor CPU, memory, disk utilization
- **Network Performance**: Track download speeds and latency
- **Error Rates**: Monitor success/failure rates

### Health Monitoring
- **VM Status**: Real-time health indicators
- **Auto-Repair Success**: Track automatic repair effectiveness
- **Package Health**: Monitor integration package integrity
- **System Resources**: Track overall system resource usage

## 🛠️ Development & Testing

### Test Environment
For testing and development:
```bash
# Set up isolated test environment
cd "/path/to/ml-integration/test-environment"
./scripts/setup-test-env.sh

# Run tests with monitoring
./scripts/run-tests.sh
```

### Debug Mode
- **Verbose Logging**: Enable detailed operation logging
- **Test Data**: Use mock ISOs and test fixtures
- **Isolation**: Separate test data from production
- **Performance**: Benchmark operations during testing

## 📚 Additional Resources

### Documentation
- [**Deployment Guide**](DEPLOYMENT.md) - Production deployment instructions
- [**API Reference**](API_REFERENCE.md) - Technical documentation
- [**Troubleshooting**](TROUBLESHOOTING.md) - Common issues and solutions
- [**Security Guide**](SECURITY.md) - Security best practices

### Community
- **GitHub Issues**: Report bugs and request features
- **GitHub Discussions**: Ask questions and share experiences
- **Contributing**: See [CONTRIBUTING.md](CONTRIBUTING.md) for development guidelines
- **Releases**: Check [GitHub Releases](https://github.com/bdbobbie/ml-integration/releases) for updates

### Support
- **Built-in Escalation**: Use Help > Report Issue in app
- **Documentation**: Comprehensive guides available in app and online
- **Community**: Join discussions and share knowledge
- **Issues**: Structured bug reports with issue templates

## 🎯 Best Practices

### VM Management
- **Resource Planning**: Allocate appropriate resources based on workload
- **Regular Health**: Schedule periodic VM health checks
- **Backup Strategy**: Regular VM configuration backups
- **Clean Shutdown**: Properly shutdown VMs before closing app

### Security
- **Regular Updates**: Keep app and VM definitions updated
- **Credential Rotation**: Periodically update GitHub tokens
- **Network Security**: Use secure connections for downloads
- **Access Control**: Limit VM access to authorized users

### Performance
- **Monitor Resources**: Keep track of system resource usage
- **Optimize Settings**: Tune configuration for your hardware
- **Regular Maintenance**: Clean up unused VMs and files
- **Network Optimization**: Use appropriate mirrors and caching

---

## 🚀 Ready to Go!

ML Integration is now production-ready with comprehensive VM lifecycle management, optimized performance, robust security, and complete observability. Start your Linux virtualization journey today!

**Need Help?** Use the built-in escalation system or check our comprehensive documentation and community resources.
