# imgctl - Quick Reference

> One-page visual guide to imgctl architecture and usage

> **Web GUI (v2.2.0):** browse cluster images in a browser at `http://<head>:8088/` — see [WEB_UI.md](WEB_UI.md). Installed by `sudo ./install.sh`; open the firewall port manually via `cmsh … openports`.

---

## System Overview

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              imgctl OVERVIEW                                     │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│    ┌─────────────┐         ┌─────────────────────────────────────────────┐      │
│    │   OPERATOR  │         │              imgctl                         │      │
│    │             │────────▶│   "View container images across cluster"    │      │
│    │  $ imgctl   │         └────────────────────┬────────────────────────┘      │
│    └─────────────┘                              │                               │
│                              ┌──────────────────┴──────────────────┐            │
│                              │                                     │            │
│                              ▼                                     ▼            │
│                  ┌───────────────────────┐           ┌───────────────────────┐  │
│                  │   HARBOR REGISTRY     │           │    WORKER NODES       │  │
│                  │   (REST API)          │           │    (SSH + crictl)     │  │
│                  │                       │           │                       │  │
│                  │  • Projects           │           │  • k8s-worker1        │  │
│                  │  • Repositories       │           │  • k8s-worker2        │  │
│                  │  • Artifacts/Tags     │           │  • k8s-worker3        │  │
│                  └───────────────────────┘           └───────────────────────┘  │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Command Cheat Sheet

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            COMMAND CHEAT SHEET                                   │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   BASIC COMMANDS                                                                 │
│   ══════════════                                                                 │
│   imgctl get               # Get ALL images (Harbor + Nodes)                     │
│   imgctl get harbor        # Get Harbor images only                              │
│   imgctl get nodes         # Get worker node images only                         │
│   imgctl compare           # Compare images across nodes                         │
│   imgctl help              # Show help                                           │
│   imgctl --version         # Show version                                        │
│                                                                                  │
│   OUTPUT OPTIONS                                                                 │
│   ══════════════                                                                 │
│   -o table                 # Table format (default)                              │
│   -o json                  # JSON format for scripts                             │
│   -o csv                   # CSV format for spreadsheets                         │
│                                                                                  │
│   OTHER OPTIONS                                                                  │
│   ═════════════                                                                  │
│   --no-color               # Disable colored output                              │
│   -q, --quiet              # Quiet mode (errors only)                            │
│                                                                                  │
│   EXAMPLES                                                                       │
│   ════════                                                                       │
│   imgctl get -o json > images.json     # Export all to JSON                      │
│   imgctl get harbor -o csv             # Export Harbor to CSV                    │
│   imgctl compare -o json | jq .common  # Get common images as JSON               │
│   imgctl get nodes -q -o json          # Quiet JSON output for scripts           │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Architecture at a Glance

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         ARCHITECTURE AT A GLANCE                                 │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   FILE STRUCTURE                                                                 │
│   ══════════════                                                                 │
│                                                                                  │
│   /opt/imgctl/                    # Installation directory                       │
│   ├── bin/imgctl                  # Main CLI executable                          │
│   └── lib/                        # Library modules                              │
│       ├── common.sh               #   └─ Logging, SSH, Cache, Config             │
│       ├── crictl.sh               #   └─ Worker node operations                  │
│       ├── harbor.sh               #   └─ Harbor API operations                   │
│       └── output.sh               #   └─ Formatting (table/json/csv)             │
│                                                                                  │
│   /etc/imgctl/                    # Configuration                                │
│   ├── imgctl.conf                 #   └─ Main config file                        │
│   └── images_to_ignore.txt        #   └─ Filter blocklist (CSV)                  │
│                                                                                  │
│   /var/log/giindia/imgctl/        # Logs                                         │
│   └── imgctl-YYYY-MM-DD.log       #   └─ Daily log files                         │
│                                                                                  │
│   /var/cache/imgctl/              # Cache                                        │
│   ├── harbor_images.cache         #   └─ Harbor response cache                   │
│   └── node_*.cache                #   └─ Per-node response cache                 │
│                                                                                  │
│   /usr/local/bin/imgctl           # Symlink to /opt/imgctl/bin/imgctl            │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Data Flow Summary

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            DATA FLOW SUMMARY                                     │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   $ imgctl get all                                                               │
│         │                                                                        │
│         ▼                                                                        │
│   ┌───────────────────────────────────────────────────────────────────────┐     │
│   │                     PARALLEL FETCH                                    │     │
│   │   ┌─────────────────────┐    ┌─────────────────────┐                  │     │
│   │   │  Harbor API         │    │  SSH to Nodes       │                  │     │
│   │   │  (curl + REST)      │    │  (crictl images)    │                  │     │
│   │   └──────────┬──────────┘    └──────────┬──────────┘                  │     │
│   │              │                          │                             │     │
│   └──────────────┼──────────────────────────┼─────────────────────────────┘     │
│                  │                          │                                   │
│                  ▼                          ▼                                   │
│   ┌───────────────────────────────────────────────────────────────────────┐     │
│   │                       FILTERING                                       │     │
│   │   • Remove <none> tags                                                │     │
│   │   • Apply ignore list                                                 │     │
│   └───────────────────────────────────────────────────────────────────────┘     │
│                  │                                                              │
│                  ▼                                                              │
│   ┌───────────────────────────────────────────────────────────────────────┐     │
│   │                       COMPARISON                                      │     │
│   │   • Map: node→images to image→nodes                                   │     │
│   │   • Reduce: classify common vs unique                                 │     │
│   └───────────────────────────────────────────────────────────────────────┘     │
│                  │                                                              │
│                  ▼                                                              │
│   ┌───────────────────────────────────────────────────────────────────────┐     │
│   │                       OUTPUT                                          │     │
│   │   Table │ JSON │ CSV                                                  │     │
│   └───────────────────────────────────────────────────────────────────────┘     │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Key Configuration

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         KEY CONFIGURATION                                        │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   # /etc/imgctl/imgctl.conf                                                      │
│                                                                                  │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │  # REQUIRED SETTINGS                                                    │   │
│   │  WORKER_NODES="k8s-worker1 k8s-worker2"    # Space-separated            │   │
│   │  HARBOR_URL="https://harbor.local:9443"    # Include port               │   │
│   │  HARBOR_USER="admin"                                                    │   │
│   │  HARBOR_PASSWORD="secret"                                               │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│   ┌─────────────────────────────────────────────────────────────────────────┐   │
│   │  # COMMON TUNING                                                        │   │
│   │  HARBOR_VERIFY_SSL="false"     # For self-signed certs                  │   │
│   │  SSH_USER="root"               # User for SSH to workers                │   │
│   │  CACHE_TTL="300"               # Cache lifetime (seconds)               │   │
│   │  MAX_PARALLEL_JOBS="10"        # Concurrent API calls                   │   │
│   │  LOG_LEVEL="INFO"              # DEBUG|INFO|WARNING|ERROR               │   │
│   └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Troubleshooting

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          TROUBLESHOOTING                                         │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   PROBLEM                      │  SOLUTION                                       │
│   ─────────────────────────────│─────────────────────────────────────────────    │
│   "No images from worker"      │  Check SSH: ssh root@node "crictl images"       │
│   "Harbor connection failed"   │  Test: curl -k -u user:pass HARBOR_URL/health   │
│   "Permission denied"          │  Run as root: sudo imgctl get                   │
│   "Config not found"           │  Check: ls -la /etc/imgctl/imgctl.conf          │
│   "Empty output"               │  Enable debug: LOG_LEVEL="DEBUG"                │
│   "Slow performance"           │  Check cache: ls /var/cache/imgctl/             │
│                                                                                  │
│   VIEW LOGS                                                                      │
│   ─────────                                                                      │
│   tail -f /var/log/giindia/imgctl/imgctl-$(date +%Y-%m-%d).log                   │
│                                                                                  │
│   CLEAR CACHE                                                                    │
│   ───────────                                                                    │
│   rm -rf /var/cache/imgctl/*.cache                                               │
│                                                                                  │
│   TEST SSH                                                                       │
│   ────────                                                                       │
│   for n in k8s-worker1 k8s-worker2; do ssh $n "echo OK"; done                    │
│                                                                                  │
│   TEST HARBOR                                                                    │
│   ───────────                                                                    │
│   curl -k -u admin:pass "https://harbor:9443/api/v2.0/projects"                  │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Output Examples

### Table Output
```
Harbor Registry Images (3 images)
───────────────────────────────────────────────────────────────────────────────────
REPOSITORY                       TAG          DIGEST          SIZE
───────────────────────────────────────────────────────────────────────────────────
nvidia/pytorch                   2.1          sha256:abc...   5.3GB
nvidia/cuda                      12.0         sha256:def...   3.1GB
ml-team/training                 latest       sha256:ghi...   2.8GB

Common Images (Present on all worker nodes) - 2 images
───────────────────────────────────────────────────────────────────────────────────
REPOSITORY                       TAG          IMAGE ID        SIZE
───────────────────────────────────────────────────────────────────────────────────
docker.io/library/nginx          1.25         abc123def456    50MB
docker.io/library/redis          7.0          def456ghi789    40MB
```

### JSON Output
```json
{
  "timestamp": "2025-12-02T14:30:00Z",
  "harbor_images": [
    {"repository": "nvidia/pytorch", "tag": "2.1", "digest": "sha256:abc...", "size": "5.3GB"}
  ],
  "comparison": {
    "common": [
      {"repository": "docker.io/library/nginx", "tag": "1.25", "image_id": "abc123", "size": "50MB"}
    ],
    "node_specific": {
      "k8s-worker1": [],
      "k8s-worker2": []
    }
  }
}
```

### CSV Output
```csv
source,repository,tag,id,size
harbor,nvidia/pytorch,2.1,sha256:abc...,5.3GB
common,docker.io/library/nginx,1.25,abc123def456,50MB
k8s-worker1,docker.io/library/mongo,6.0,jkl012mno345,150MB
```

---

## See Also

| Document | Description |
|----------|-------------|
| [ARCHITECTURE.md](./ARCHITECTURE.md) | Detailed system architecture |
| [DATA_FLOW.md](./DATA_FLOW.md) | Data processing pipeline |
| [CONFIGURATION.md](./CONFIGURATION.md) | Full configuration guide |
| [README.md](../README.md) | Project overview |

---

*Quick Reference v2.1.0 - imgctl*

