# imgctl - Configuration Guide

> **Version:** 2.2.0  
> **Author:** Anubhav Patrick <anubhav.patrick@giindia.com>  
> **Organization:** Global Info Ventures Pvt Ltd

---

## Table of Contents

1. [Configuration Files](#configuration-files)
2. [Configuration Parameters](#configuration-parameters)
3. [SSH Configuration](#ssh-configuration)
4. [Harbor Configuration](#harbor-configuration)
5. [Image Filtering](#image-filtering)
6. [Performance Tuning](#performance-tuning)
7. [Logging Configuration](#logging-configuration)
8. [Web GUI Configuration](#web-gui-configuration)
9. [Example Configurations](#example-configurations)

---

## Configuration Files

### Primary Configuration

imgctl uses a primary configuration file located at:

```
/etc/imgctl/imgctl.conf
```

**Fallback location** (if primary not found):
```
/root/imgctl/conf/imgctl.conf
```

### File Permissions

```bash
# Recommended permissions for security
chmod 640 /etc/imgctl/imgctl.conf
chown root:root /etc/imgctl/imgctl.conf
```

### Configuration Loading

Configuration is loaded in the following order:
1. Default values (hardcoded)
2. System configuration file
3. Command-line options (override config file)

---

## Configuration Parameters

### Complete Parameter Reference

```bash
# ============================================================================
# imgctl Configuration File
# ============================================================================

# ----------------------------------------------------------------------------
# CLUSTER CONFIGURATION
# ----------------------------------------------------------------------------

# Cluster name for identification
CLUSTER_NAME="dgx-cluster"

# Worker nodes - space-separated list of hostnames
WORKER_NODES="k8s-worker1 k8s-worker2 k8s-worker3"

# ----------------------------------------------------------------------------
# SSH SETTINGS
# ----------------------------------------------------------------------------

# SSH user for connecting to worker nodes
SSH_USER="root"

# SSH options for all connections
SSH_OPTIONS="-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10"

# SSH private key path (optional)
SSH_KEY=""

# ----------------------------------------------------------------------------
# HARBOR REGISTRY CONFIGURATION
# ----------------------------------------------------------------------------

# Harbor URL (include port if non-standard)
HARBOR_URL="https://harbor.example.com:9443"

# Harbor credentials
HARBOR_USER="admin"
HARBOR_PASSWORD="Harbor12345"

# SSL verification (set to "false" for self-signed certs)
HARBOR_VERIFY_SSL="false"

# Page size for paginated API requests
HARBOR_PAGE_SIZE="100"

# ----------------------------------------------------------------------------
# IMAGE FILTERING
# ----------------------------------------------------------------------------

# Path to CSV file containing images to ignore
IGNORE_FILE="/etc/imgctl/images_to_ignore.txt"

# ----------------------------------------------------------------------------
# PARALLEL PROCESSING
# ----------------------------------------------------------------------------

# Maximum concurrent jobs for Harbor API calls
MAX_PARALLEL_JOBS="10"

# ----------------------------------------------------------------------------
# CRICTL CONFIGURATION
# ----------------------------------------------------------------------------

# Path to crictl binary on worker nodes
CRICTL_PATH="/usr/bin/crictl"

# Timeout for crictl commands (seconds)
CRICTL_TIMEOUT="30"

# ----------------------------------------------------------------------------
# LOGGING CONFIGURATION
# ----------------------------------------------------------------------------

# Log directory
LOG_DIR="/var/log/giindia/imgctl"

# Log level: DEBUG, INFO, WARNING, ERROR
LOG_LEVEL="INFO"

# Log retention in days
LOG_RETENTION_DAYS="30"

# Maximum log file size in bytes (100MB default)
MAX_LOG_SIZE="104857600"

# ----------------------------------------------------------------------------
# OUTPUT CONFIGURATION
# ----------------------------------------------------------------------------

# Default output format: table, json, csv
DEFAULT_OUTPUT_FORMAT="table"

# ----------------------------------------------------------------------------
# CACHE CONFIGURATION
# ----------------------------------------------------------------------------

# Enable/disable caching
ENABLE_CACHE="true"

# Cache directory
CACHE_DIR="/var/cache/imgctl"

# Cache time-to-live in seconds (5 minutes default)
CACHE_TTL="300"

# ----------------------------------------------------------------------------
# WEB GUI ("Cluster Image Portal") -- optional; used by the imgcatalog units
# ----------------------------------------------------------------------------

WEB_PORT="8088"                                  # portal TCP port (open in firewall manually)
WEB_BIND_ADDRESS="0.0.0.0"                        # 0.0.0.0 = reachable remotely via the head IP
WEB_SNAPSHOT_PATH="/var/lib/imgcatalog/all.json"  # producer writes / server reads
WEB_STALE_AFTER="900"                             # seconds before UI flags data stale
WEB_HARBOR_REGISTRY_HOST=""                        # blank => derived from HARBOR_URL
WEB_SITE_TITLE="Cluster Image Portal"             # header title
WEB_SITE_SUBTITLE=""                              # blank => falls back to CLUSTER_NAME
WEB_LABEL_HARBOR="Harbor"                          # badge/label for registry images
WEB_LABEL_NODE="Node"                              # badge/label for worker-cached images
```

---

## SSH Configuration

### Prerequisites

1. **SSH Key-Based Authentication**:
   ```bash
   # Generate SSH key on head node (if not exists)
   ssh-keygen -t ed25519 -f ~/.ssh/imgctl_key -N ""
   
   # Copy key to all worker nodes
   for node in k8s-worker1 k8s-worker2 k8s-worker3; do
       ssh-copy-id -i ~/.ssh/imgctl_key.pub root@$node
   done
   ```

2. **Test Connectivity**:
   ```bash
   # Test SSH to each node
   for node in k8s-worker1 k8s-worker2 k8s-worker3; do
       ssh -o BatchMode=yes $node "echo OK: $node"
   done
   ```

### SSH Options Explained

```bash
SSH_OPTIONS="-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10"
```

| Option | Purpose |
|--------|---------|
| `BatchMode=yes` | Disable password prompts; fail immediately if key auth fails |
| `StrictHostKeyChecking=no` | Auto-accept new host keys (use with caution) |
| `ConnectTimeout=10` | Fail after 10 seconds if connection not established |

### Using SSH Keys

```bash
# Option 1: Specify key in config
SSH_KEY="/root/.ssh/imgctl_key"

# Option 2: Use ssh-agent (no config needed)
eval $(ssh-agent)
ssh-add ~/.ssh/imgctl_key
```

### Troubleshooting SSH

```bash
# Enable SSH debug logging
SSH_OPTIONS="-vvv -o BatchMode=yes -o StrictHostKeyChecking=no"

# Test crictl manually
ssh root@k8s-worker1 "crictl images"
```

---

## Harbor Configuration

### Authentication

imgctl uses HTTP Basic Authentication for Harbor API:

```bash
HARBOR_URL="https://harbor.example.com:9443"
HARBOR_USER="admin"
HARBOR_PASSWORD="Harbor12345"
```

### SSL Configuration

For self-signed certificates:
```bash
HARBOR_VERIFY_SSL="false"  # Disable SSL verification
```

For production with valid certificates:
```bash
HARBOR_VERIFY_SSL="true"
```

### Testing Harbor Connection

```bash
# Manual test using curl
curl -k -u admin:Harbor12345 \
    "https://harbor.example.com:9443/api/v2.0/health"
```

Expected response:
```json
{"status":"healthy"}
```

### Pagination

For registries with many images:
```bash
HARBOR_PAGE_SIZE="100"  # Items per page (max 100 for Harbor)
```

---

## Image Filtering

### Ignore File Format

The ignore file is a CSV with header:

```csv
IMAGE,TAG,IMAGE ID,SIZE
docker.io/calico/cni,v3.29.2,cda13293c895a,99.3MB
docker.io/calico/node,v3.29.2,048bf7af1f8c6,142MB
registry.k8s.io/pause,3.8,4873874c08efc,311kB
```

**Note**: Only `IMAGE` and `TAG` columns are used for matching.

### Generating Ignore List

To generate an ignore list from current node images:

```bash
# Export current node images to ignore file format
imgctl get nodes -o csv | tail -n +2 | \
    awk -F',' '{print $2","$3",,"}'  > /etc/imgctl/images_to_ignore.txt
```

### Common Images to Ignore

Typical Kubernetes system images:

```csv
IMAGE,TAG,IMAGE ID,SIZE
# Calico CNI
docker.io/calico/cni,v3.29.2,,
docker.io/calico/node,v3.29.2,,
docker.io/calico/typha,v3.29.2,,
# Kubernetes
registry.k8s.io/pause,3.8,,
registry.k8s.io/kube-proxy,v1.30.13,,
# Prometheus Stack
quay.io/prometheus/prometheus,v3.2.1,,
quay.io/prometheus/alertmanager,v0.28.1,,
quay.io/prometheus/node-exporter,v1.9.0,,
# NVIDIA GPU Operator
nvcr.io/nvidia/cloud-native/gpu-operator-validator,v24.9.2,,
nvcr.io/nvidia/k8s-device-plugin,v0.17.0,,
```

---

## Performance Tuning

### Parallel Processing

```bash
# Increase concurrent Harbor API calls (default: 10)
MAX_PARALLEL_JOBS="20"

# Note: Too high values may cause API rate limiting
```

### Caching

```bash
# Enable caching for repeated queries
ENABLE_CACHE="true"
CACHE_TTL="300"  # 5 minutes

# Increase TTL for stable environments
CACHE_TTL="900"  # 15 minutes

# Disable caching for always-fresh data
ENABLE_CACHE="false"
```

### SSH Timeouts

```bash
# For slow networks, increase timeouts
SSH_OPTIONS="-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=30"
CRICTL_TIMEOUT="60"
```

### Performance Matrix

| Setting | Low Latency | High Throughput | Reliability |
|---------|-------------|-----------------|-------------|
| `MAX_PARALLEL_JOBS` | 5 | 20 | 10 |
| `CACHE_TTL` | 60 | 900 | 300 |
| `ConnectTimeout` | 5 | 10 | 30 |
| `CRICTL_TIMEOUT` | 15 | 30 | 60 |

---

## Logging Configuration

### Log Levels

```bash
LOG_LEVEL="DEBUG"    # All messages including debug
LOG_LEVEL="INFO"     # Normal operation messages (default)
LOG_LEVEL="WARNING"  # Warnings and errors only
LOG_LEVEL="ERROR"    # Errors only
```

### Log File Location

```bash
# Default log directory
LOG_DIR="/var/log/giindia/imgctl"

# Log file format: imgctl-YYYY-MM-DD.log
# Example: /var/log/giindia/imgctl/imgctl-2025-12-02.log
```

### Log Rotation

```bash
# Automatic cleanup of old logs
LOG_RETENTION_DAYS="30"  # Keep logs for 30 days

# Maximum log file size (stops writing when exceeded)
MAX_LOG_SIZE="104857600"  # 100MB
```

### Viewing Logs

```bash
# View today's log
tail -f /var/log/giindia/imgctl/imgctl-$(date +%Y-%m-%d).log

# Search for errors
grep "ERROR" /var/log/giindia/imgctl/*.log

# Filter by correlation ID
grep "abc12345" /var/log/giindia/imgctl/*.log
```

### Log Format

```
[2025-12-02 14:30:45] [abc12345] [INFO] Fetching images from 3 worker nodes...
[2025-12-02 14:30:46] [abc12345] [DEBUG] Harbor API call: /api/v2.0/projects
[2025-12-02 14:30:47] [abc12345] [WARNING] Failed to retrieve images from node: k8s-worker3
```

---

## Web GUI Configuration

The optional Web GUI (Cluster Image Portal) is configured by the same `imgctl.conf` — it
reuses imgctl's `HARBOR_URL`, `WORKER_NODES`, and ignore list, so the portal shows exactly
what the CLI does. All `WEB_*` keys are optional (the server has built-in defaults).

| Key | Default | Purpose |
|-----|---------|---------|
| `WEB_PORT` | `8088` | Portal TCP port. **The firewall port is opened manually** (see below). |
| `WEB_BIND_ADDRESS` | `0.0.0.0` | Listener address; `0.0.0.0` = all interfaces (remote access). |
| `WEB_SNAPSHOT_PATH` | `/var/lib/imgcatalog/all.json` | Snapshot the producer writes and the server reads. |
| `WEB_STALE_AFTER` | `900` | Seconds before the UI flags the snapshot stale. |
| `WEB_HARBOR_REGISTRY_HOST` | _(blank → `HARBOR_URL`)_ | Host prepended to custom/Harbor pull references. |
| `WEB_SITE_TITLE` | `Cluster Image Portal` | Header title (config-driven; nothing hardcoded). |
| `WEB_SITE_SUBTITLE` | _(blank → `CLUSTER_NAME`)_ | Header subtitle. |
| `WEB_LABEL_HARBOR` | `Harbor` | Badge/label for private-registry images. |
| `WEB_LABEL_NODE` | `Node` | Badge/label for worker-cached images (e.g. `DGX cache`). |

> **Firewall is a manual admin step.** `install.sh`/`uninstall.sh` never modify the firewall.
> On a BCM head node, open/close the port via `cmsh … roles … use firewall … openports`
> (never hand-edit `/etc/shorewall/rules`). Full runbook: [WEB_UI.md](./WEB_UI.md).

Apply changes with `sudo /opt/imgctl/web/refresh.sh` (or wait one refresh cycle).

---

## Example Configurations

### Small Cluster (2-3 nodes)

```bash
# /etc/imgctl/imgctl.conf

CLUSTER_NAME="small-cluster"
WORKER_NODES="node1 node2 node3"

SSH_USER="root"
SSH_OPTIONS="-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10"

HARBOR_URL="https://harbor.local:443"
HARBOR_USER="admin"
HARBOR_PASSWORD="secret"
HARBOR_VERIFY_SSL="false"

MAX_PARALLEL_JOBS="5"
ENABLE_CACHE="true"
CACHE_TTL="300"

LOG_LEVEL="INFO"
```

### Large Production Cluster (10+ nodes)

```bash
# /etc/imgctl/imgctl.conf

CLUSTER_NAME="production-dgx-cluster"
WORKER_NODES="dgx01 dgx02 dgx03 dgx04 dgx05 dgx06 dgx07 dgx08 dgx09 dgx10"

SSH_USER="imgctl"
SSH_KEY="/etc/imgctl/ssh/imgctl_key"
SSH_OPTIONS="-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=30"

HARBOR_URL="https://registry.company.com"
HARBOR_USER="imgctl-svc"
HARBOR_PASSWORD="encrypted-password"
HARBOR_VERIFY_SSL="true"
HARBOR_PAGE_SIZE="100"

MAX_PARALLEL_JOBS="20"
CRICTL_TIMEOUT="60"

ENABLE_CACHE="true"
CACHE_TTL="600"

LOG_LEVEL="INFO"
LOG_RETENTION_DAYS="90"
MAX_LOG_SIZE="209715200"  # 200MB
```

### Development/Testing

```bash
# /etc/imgctl/imgctl.conf

CLUSTER_NAME="dev-cluster"
WORKER_NODES="dev-worker1"

SSH_USER="developer"
SSH_OPTIONS="-o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5"

HARBOR_URL="https://localhost:5000"
HARBOR_USER="test"
HARBOR_PASSWORD="test"
HARBOR_VERIFY_SSL="false"

MAX_PARALLEL_JOBS="2"
ENABLE_CACHE="false"

LOG_LEVEL="DEBUG"
```

---

## Related Documentation

- [ARCHITECTURE.md](./ARCHITECTURE.md) - System architecture overview
- [DATA_FLOW.md](./DATA_FLOW.md) - Data flow documentation
- [WEB_UI.md](./WEB_UI.md) - Web GUI (Cluster Image Portal) runbook
- [README.md](../README.md) - Project overview and quick start

---

*This documentation was auto-generated based on codebase analysis.*

