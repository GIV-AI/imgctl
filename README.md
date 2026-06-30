# imgctl - Cluster Image Management Tool

A scalable command-line tool for managing and viewing container images across NVIDIA BCM clusters with DGX nodes and Harbor private registry.

## Overview

`imgctl` provides a unified interface to:

- View container images in Harbor private registry
- View and compare container images across worker nodes via `crictl`
- Filter out Kubernetes system images using an ignore list
- Export data in multiple formats (table, JSON, CSV)

Designed for BCM (Base Command Manager) clusters running Kubernetes on NVIDIA DGX H200 servers.

## Features

- **Multi-node Support**: Scalable to any number of worker nodes
- **Harbor Integration**: Full support for Harbor API v2.0 with pagination
- **Image Filtering**: Exclude Kubernetes/system images via configurable ignore file
- **Automatic Tag Filtering**: Images without tags (`<none>`) are automatically excluded
- **Comparison Analysis**: Identify common and unique images across nodes
- **Parallel Processing**: Uses GNU `parallel` for faster execution
- **Multiple Output Formats**: Table, JSON, CSV
- **Caching**: Reduce API calls with configurable TTL cache
- **Day-wise Logging**: Automatic log rotation in `/var/log/giindia/imgctl/`
- **Web GUI (optional)**: a read-only, NVIDIA/Run:ai-themed browser portal + JSON API so users can browse images and copy pull references without SSH (see [Web GUI](#web-gui-cluster-image-portal))

## Requirements

- Bash 4.0+
- `jq` (JSON processor)
- `curl` (HTTP client)
- `parallel` (GNU parallel - optional but recommended for performance)
- SSH access to worker nodes (key-based authentication recommended)
- `crictl` installed on worker nodes

## Quick Start

### Installation

```bash
# Clone or copy the project to the head node
cd ~/imgctl

# Ensure correct directory structure
tree
# Expected:
# .
# ├── bin/
# │   └── imgctl
# ├── conf/
# │   └── imgctl.conf
# ├── docs/
# │   ├── ARCHITECTURE.md
# │   ├── CONFIGURATION.md
# │   ├── DATA_FLOW.md
# │   └── QUICK_REFERENCE.md
# ├── lib/
# │   ├── common.sh
# │   ├── crictl.sh
# │   ├── harbor.sh
# │   └── output.sh
# ├── images_to_ignore.txt
# ├── install.sh
# ├── uninstall.sh
# └── README.md

# Run installation
chmod +x install.sh
sudo ./install.sh
```

The installer will automatically:
- Install dependencies (`jq`, `curl`) if missing
- Copy files to `/opt/imgctl/`
- Install configuration to `/etc/imgctl/imgctl.conf`
- Copy the ignore list to `/etc/imgctl/images_to_ignore.txt`
- Create log and cache directories
- Create symlink at `/usr/local/bin/imgctl`

### Enable for Non-Root Users (Optional)

`imgctl` requires root privileges because it:
- Uses SSH to access worker nodes (with root's SSH keys)
- Reads Harbor credentials from protected configuration files

To allow all users to run `imgctl` without typing `sudo`, configure sudoers and a shell alias:

**Step 1: Create sudoers rule**

```bash
sudo visudo -f /etc/sudoers.d/imgctl
```

Add the following entry:

```
ALL ALL=(root) NOPASSWD: /opt/imgctl/bin/imgctl
```

**Step 2: Create shell alias for all users**

```bash
sudo vim /etc/profile.d/imgctl.sh
```

Add the following entry:

```bash
alias imgctl='sudo /opt/imgctl/bin/imgctl'
```

**Step 3:** Users must log out and log back in for the alias to take effect.

**Security Note**: This configuration only grants passwordless sudo for the `imgctl` command specifically — users cannot run other commands as root.

**To remove** (during uninstall):

```bash
sudo rm /etc/sudoers.d/imgctl
sudo rm /etc/profile.d/imgctl.sh
```

### Configuration

Edit the configuration file:

```bash
sudo nano /etc/imgctl/imgctl.conf
```

Key settings to update:

```bash
# Worker nodes (space-separated)
WORKER_NODES="k8s-worker1 k8s-worker2"

# Harbor configuration
HARBOR_URL="https://bcm11-headnode:9443"
HARBOR_USER="admin"
HARBOR_PASSWORD="your-password"
HARBOR_VERIFY_SSL="false"

# Ignore file path
IGNORE_FILE="/etc/imgctl/images_to_ignore.txt"
```

### Verify Installation

```bash
# Check version
imgctl --version

# Show help
imgctl help
```

## Usage

### Get Images

```bash
# Get all images (Harbor + node comparison)
imgctl get

# Same as above (explicit)
imgctl get all

# Get Harbor images only
imgctl get harbor

# Get images from all nodes (with comparison)
imgctl get nodes

# Output in JSON format
imgctl get -o json

# Output in CSV format
imgctl get -o csv
```

### Compare Images

```bash
# Compare images across all nodes
imgctl compare

# Output comparison in JSON
imgctl compare -o json
```

### Options

```bash
# Quiet mode (errors only)
imgctl -q get

# Disable colored output
imgctl --no-color get

# Show version
imgctl --version

# Show help
imgctl help
```

## Output Format

The default table output displays in this order:

1. **Harbor Registry Images** - All tagged images in Harbor
2. **Common Images** - Images present on all worker nodes (filtered)
3. **Unique Images per Node** - Images only on specific nodes (filtered)
4. **Summary** - Statistics

### Example Output

```
Harbor Registry Images (10 images)
-----------------------------------------------------------------------------------------------------------
REPOSITORY                                              TAG                       DIGEST          SIZE
-----------------------------------------------------------------------------------------------------------
nvcr/nvidia/pytorch                                     20.12-py3                 sha256:cc14c0cf 5.8GB
nvcr/nvidia/pytorch                                     24.04-py3                 sha256:a1b2c3d4 9.3GB
test/custom                                             v1                        sha256:b992cbf6 9.3GB
...

=== Worker Node Images (Filtered) ===

Common Images (Present on all worker nodes) - 25 images
-----------------------------------------------------------------------------------------------------------
REPOSITORY                                              TAG                       IMAGE ID        SIZE
-----------------------------------------------------------------------------------------------------------
bcm11-headnode:9443/nvcr/nvidia/pytorch                 20.12-py3                 ad0f29ddeb63e   6.26GB
nvcr.io/nvidia/pytorch                                  24.10-py3                 295f8a46d16eb   10.7GB
...

Unique Images on k8s-worker1 - 3 images
-----------------------------------------------------------------------------------------------------------
REPOSITORY                                              TAG                       IMAGE ID        SIZE
-----------------------------------------------------------------------------------------------------------
docker.io/kubeflow/training-operator                    v1-855e096                29b5090daeb1a   27.8MB
...

Unique Images on k8s-worker2 - 5 images
-----------------------------------------------------------------------------------------------------------
REPOSITORY                                              TAG                       IMAGE ID        SIZE
-----------------------------------------------------------------------------------------------------------
docker.io/library/nginx                                 latest                    07ccdb7838758   62.7MB
...

Summary
------------------------------------------------------------
  Harbor Registry:         10 images
  Common across nodes:     25 images
  Unique to k8s-worker1:   3 images
  Unique to k8s-worker2:   5 images

  Total images per node (before filtering):
    k8s-worker1: 35 images
    k8s-worker2: 48 images
```

## Image Filtering

### Ignore File Format

The ignore file (`/etc/imgctl/images_to_ignore.txt`) uses CSV format:

```csv
IMAGE,TAG,IMAGE ID,SIZE
docker.io/calico/cni,v3.29.2,cda13293c895a,99.3MB
docker.io/calico/node,v3.29.2,048bf7af1f8c6,142MB
registry.k8s.io/pause,3.8,4873874c08efc,311kB
registry.k8s.io/kube-proxy,v1.30.13,a6946560b0b08,29.2MB
```

**Note**: Only the `IMAGE` and `TAG` columns are used for matching. The `IMAGE ID` and `SIZE` columns are for reference only.

### Automatic Filtering

The following are automatically filtered:

- Images without tags (`<none>`)
- Images matching entries in the ignore file

### Managing the Ignore List

```bash
# View current ignore list
cat /etc/imgctl/images_to_ignore.txt

# Add a new image to ignore
echo "docker.io/library/busybox,latest,abc123,2MB" >> /etc/imgctl/images_to_ignore.txt

# Clear cache after modifying ignore list (to see changes immediately)
sudo rm -rf /var/cache/imgctl/*.cache
```

## Web GUI (Cluster Image Portal)

`imgctl` ships an optional **read-only web portal + JSON API** so end users (e.g. Run:ai users working entirely in a browser) can see the same images `imgctl` lists — and copy the exact pull reference — **without SSH-ing into the head node**.

- **What it shows:** the same data as `imgctl get all` (Harbor registry images + worker‑cached images). Images are shown **faithfully** — if a custom image is both pushed to Harbor *and* cached on the worker, it appears as two rows (one per source), distinguished by a source badge, because the two copies live in different storage.
- **How it works (decoupled producer/consumer):** a root `imgcatalog-refresh.timer` runs `imgctl get all -o json` every ~5 minutes and atomically writes `/var/lib/imgcatalog/all.json`; an **unprivileged** Python‑stdlib web service (`imgcatalog.service`) only reads that snapshot and serves the UI + API. The slow head→worker SSH never sits on the request path, and a transient failure keeps serving the last‑good data with a "stale" banner.
- **Zero extra dependencies:** Python 3 standard library only (no pip/venv); the UI is a single static page (no build step, no CDN).

### Install

`sudo ./install.sh` installs the GUI automatically (pass `--no-gui` to skip). It copies the portal to `/opt/imgctl/web`, installs and enables the systemd units, and writes the first snapshot. It will **not** overwrite an existing `/etc/imgctl/imgctl.conf` or `images_to_ignore.txt` — it backs them up and keeps your tuned values, so the portal shows exactly what the CLI does.

### Open the firewall port (manual admin step)

The installer never modifies the firewall. The portal listens on **TCP 8088** by default (`WEB_PORT`). On a BCM head node, open it with `cmsh` (do **not** hand‑edit `/etc/shorewall/rules` — CMDaemon regenerates it):

```
cmsh
% device; use $(hostname -s); roles; use firewall
% openports; add ACCEPT net 8088 tcp fw; commit
```

Then browse to `http://<head-node-host-or-ip>:8088/`. To remove it later: `% openports; remove ACCEPT net 8088 tcp fw; commit`.

> **Exposure:** the portal has **no authentication**, and with `WEB_BIND_ADDRESS=0.0.0.0` it is reachable by anyone who can reach the port (intended for remote team access via the head node's IP). It exposes only image names/tags/sizes (read‑only). Scope the source or front it with auth if that inventory is sensitive.

### Configuration

All keys live in `/etc/imgctl/imgctl.conf` (the GUI reuses imgctl's config and ignore list):

| Setting | Description | Default |
|---|---|---|
| `WEB_PORT` | Portal TCP port | `8088` |
| `WEB_BIND_ADDRESS` | Listener address (`0.0.0.0` = all interfaces) | `0.0.0.0` |
| `WEB_SNAPSHOT_PATH` | Snapshot the producer writes / server reads | `/var/lib/imgcatalog/all.json` |
| `WEB_STALE_AFTER` | Seconds before the UI flags data stale | `900` |
| `WEB_HARBOR_REGISTRY_HOST` | Host prefixed to custom‑image pull refs (blank → from `HARBOR_URL`) | _(blank)_ |
| `WEB_SITE_TITLE` | Header title | `Cluster Image Portal` |
| `WEB_SITE_SUBTITLE` | Header subtitle (blank → `CLUSTER_NAME`) | _(blank)_ |
| `WEB_LABEL_HARBOR` | Badge/label for registry images | `Harbor` |
| `WEB_LABEL_NODE` | Badge/label for worker‑cached images (e.g. `DGX cache`) | `Node` |

Nothing institute‑ or hardware‑specific is hardcoded in the app — the header/badge text above is config‑driven. Changes appear within one refresh cycle (or run `sudo /opt/imgctl/web/refresh.sh`).

### Endpoints

`GET /` (UI) · `GET /api/images` (flattened JSON with the exact pull `reference` per image) · `GET /api/raw` (imgctl passthrough) · `GET /healthz` · `GET /version`.

> Full operate / troubleshoot / rollback runbook: **[docs/WEB_UI.md](docs/WEB_UI.md)**.

## Directory Structure

### Installation Paths

```
/opt/imgctl/                    # Installation directory
├── bin/
│   └── imgctl                  # Main executable
├── lib/
│   ├── common.sh               # Core utilities, logging, SSH, cache
│   ├── crictl.sh               # Worker node image retrieval
│   ├── harbor.sh               # Harbor API integration
│   └── output.sh               # Output formatting
└── conf/
    └── imgctl.conf             # Default configuration template

/etc/imgctl/                    # Configuration directory
├── imgctl.conf                 # System configuration
└── images_to_ignore.txt        # Images to exclude from output

/var/log/giindia/imgctl/        # Log directory
└── imgctl-YYYY-MM-DD.log       # Daily log files

/var/cache/imgctl/              # Cache directory
└── *.cache                     # Cached data files

/usr/local/bin/imgctl           # Symlink to executable
```

### Source Repository Structure

```
imgctl/                         # Project root
├── bin/imgctl                  # Main CLI executable
├── conf/imgctl.conf            # Default configuration template
├── docs/                       # Documentation
│   ├── ARCHITECTURE.md         # System architecture diagrams
│   ├── CONFIGURATION.md        # Configuration guide
│   ├── DATA_FLOW.md            # Data flow documentation
│   ├── QUICK_REFERENCE.md      # Quick reference guide
│   └── WEB_UI.md               # Web GUI (Cluster Image Portal) runbook
├── lib/                        # Library modules
│   ├── common.sh               # Core utilities
│   ├── crictl.sh               # Worker node operations
│   ├── harbor.sh               # Harbor API operations
│   └── output.sh               # Output formatting
├── web/                        # Web GUI (Cluster Image Portal)
│   ├── server.py               # Python-stdlib HTTP server (UI + JSON API)
│   ├── refresh.sh              # Snapshot producer (run by the refresh timer)
│   ├── static/                 # index.html, style.css, app.js (no build, no CDN)
│   └── systemd/                # imgcatalog.service + imgcatalog-refresh.{service,timer}
├── tests/                      # Test documentation + automated unit tests
│   ├── common_test_cases.md
│   ├── crictl_test_cases.md
│   ├── harbor_test_cases.md
│   ├── web_test_cases.md       # Manual test cases for the Web GUI
│   └── test_web_portal.py      # Unit tests for the server's pure logic
├── images_to_ignore.txt        # Default ignore list
├── install.sh                  # Installation script (installs CLI + GUI)
├── uninstall.sh                # Uninstallation script (backs up config first)
└── README.md                   # This file
```

## Configuration Reference

| Setting | Description | Default |
|---------|-------------|---------|
| `CLUSTER_NAME` | Cluster identifier | `dgx-cluster` |
| `WORKER_NODES` | Space-separated node list | - |
| `SSH_USER` | SSH username | `root` |
| `SSH_OPTIONS` | SSH command options | `-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=10` |
| `SSH_KEY` | Path to SSH key file | - |
| `HARBOR_URL` | Harbor registry URL | - |
| `HARBOR_USER` | Harbor username | - |
| `HARBOR_PASSWORD` | Harbor password | - |
| `HARBOR_VERIFY_SSL` | Verify SSL certificate | `false` |
| `HARBOR_PAGE_SIZE` | API pagination size | `100` |
| `IGNORE_FILE` | Path to ignore list CSV | `/etc/imgctl/images_to_ignore.txt` |
| `MAX_PARALLEL_JOBS` | Parallel job limit | `10` |
| `CRICTL_PATH` | Path to crictl on workers | `/usr/bin/crictl` |
| `CRICTL_TIMEOUT` | Crictl command timeout (seconds) | `30` |
| `LOG_DIR` | Log file directory | `/var/log/giindia/imgctl` |
| `LOG_LEVEL` | Logging level (DEBUG/INFO/WARNING/ERROR) | `INFO` |
| `LOG_RETENTION_DAYS` | Days to keep logs | `30` |
| `MAX_LOG_SIZE` | Maximum log file size in bytes | `104857600` (100MB) |
| `ENABLE_CACHE` | Enable caching | `true` |
| `CACHE_DIR` | Cache directory | `/var/cache/imgctl` |
| `CACHE_TTL` | Cache TTL in seconds | `300` |
| `DEFAULT_OUTPUT_FORMAT` | Default output format | `table` |

## Performance Tuning

### Enable GNU Parallel

For best performance with many nodes/repositories, install GNU parallel:

```bash
# Ubuntu/Debian
sudo apt-get install parallel

# RHEL/CentOS
sudo yum install parallel
```

The tool auto-detects GNU parallel and uses it when available. Otherwise, it falls back to native Bash background jobs.

### Adjust Parallel Jobs

Edit `/etc/imgctl/imgctl.conf`:

```bash
# Increase for faster Harbor processing (default: 10)
MAX_PARALLEL_JOBS="20"
```

### Cache Settings

Edit `/etc/imgctl/imgctl.conf`:

```bash
# Shorter TTL for more frequent updates (default: 300 seconds)
CACHE_TTL="60"

# Disable cache for always-fresh data
ENABLE_CACHE="false"
```

To manually clear the cache:

```bash
sudo rm -rf /var/cache/imgctl/*.cache
```

## Troubleshooting

### SSH Connection Issues

```bash
# Test SSH manually
ssh -o BatchMode=yes root@k8s-worker1 "echo OK"

# Check SSH key permissions
chmod 600 ~/.ssh/id_rsa

# Verify SSH config
cat ~/.ssh/config
```

### Harbor Connection Issues

```bash
# Test Harbor API
curl -k -u admin:password https://harbor:9443/api/v2.0/health

# Check Harbor certificate
openssl s_client -connect harbor:9443
```

### crictl Issues

```bash
# Verify crictl on worker node
ssh k8s-worker1 "which crictl"
ssh k8s-worker1 "crictl images"

# Check containerd status
ssh k8s-worker1 "systemctl status containerd"
```

### Check Logs

```bash
# View today's log file
tail -f /var/log/giindia/imgctl/imgctl-$(date +%Y-%m-%d).log

# Enable debug logging by editing config
sudo nano /etc/imgctl/imgctl.conf
# Set: LOG_LEVEL="DEBUG"
```

### Clear Cache

If you see stale data:

```bash
sudo rm -rf /var/cache/imgctl/*.cache
imgctl get
```

## Uninstallation

```bash
sudo ./uninstall.sh
```

The uninstaller will prompt before removing configuration and logs.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         Head Node                               │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │                        imgctl                             │  │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐  │  │
│  │  │ common   │  │ crictl   │  │ harbor   │  │ output   │  │  │
│  │  │   .sh    │  │   .sh    │  │   .sh    │  │   .sh    │  │  │
│  │  └──────────┘  └──────────┘  └──────────┘  └──────────┘  │  │
│  └───────────────────────────────────────────────────────────┘  │
│           │                │                                    │
│           │ SSH            │ HTTPS                              │
│           ▼                ▼                                    │
│  ┌────────────────┐  ┌────────────────┐                        │
│  │   DGX Worker   │  │    Harbor      │                        │
│  │    Nodes       │  │    Registry    │                        │
│  │   (crictl)     │  │                │                        │
│  └────────────────┘  └────────────────┘                        │
└─────────────────────────────────────────────────────────────────┘
```

## Documentation

Detailed documentation is available in the `docs/` directory:

| Document | Description |
|----------|-------------|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | System architecture diagrams, module dependencies, and component overview |
| [DATA_FLOW.md](docs/DATA_FLOW.md) | Data collection, transformation pipeline, and comparison algorithm |
| [CONFIGURATION.md](docs/CONFIGURATION.md) | Complete configuration guide with examples for different environments |
| [QUICK_REFERENCE.md](docs/QUICK_REFERENCE.md) | One-page visual guide with command cheat sheet and troubleshooting |
| [WEB_UI.md](docs/WEB_UI.md) | Web GUI (Cluster Image Portal): architecture, install, the manual firewall step, operate/troubleshoot/rollback |

### Quick Links

- **New to imgctl?** Start with [QUICK_REFERENCE.md](docs/QUICK_REFERENCE.md)
- **Setting up a cluster?** See [CONFIGURATION.md](docs/CONFIGURATION.md)
- **Understanding the internals?** Read [ARCHITECTURE.md](docs/ARCHITECTURE.md) and [DATA_FLOW.md](docs/DATA_FLOW.md)

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 2.2.0 | 2026-06-30 | Added the optional **Web GUI (Cluster Image Portal)**: read-only web portal + JSON API (systemd producer/consumer), config-driven display text, install/uninstall integration |
| 2.1.0 | 2025-12-02 | Added ignore file support, `<none>` tag filtering, new display order |
| 2.0.0 | 2025-11-28 | Complete rewrite in shell with parallel processing |
| 1.0.0 | 2025-11-27 | Initial Python-based implementation |

## Author

- **Anubhav Patrick**
- Email: anubhav.patrick@giindia.com
- Organization: Global Info Ventures Pvt Ltd

## License

Copyright © 2025 Global Info Ventures Pvt Ltd. All rights reserved.
