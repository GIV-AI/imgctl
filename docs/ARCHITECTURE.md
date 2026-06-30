# imgctl - System Architecture Documentation

> **Version:** 2.2.0  
> **Author:** Anubhav Patrick <anubhav.patrick@giindia.com>  
> **Organization:** Global Info Ventures Pvt Ltd  
> **Last Updated:** June 2026

> **v2.2.0** adds an optional **[Web GUI — Cluster Image Portal](WEB_UI.md)**: a read-only web portal + JSON API that reuses this same pipeline, served on the head node by a decoupled systemd producer/consumer (`imgcatalog-refresh.timer` → snapshot → unprivileged `imgcatalog.service`).

---

## Table of Contents

1. [Overview](#overview)
2. [High-Level Architecture](#high-level-architecture)
3. [Module Dependency Graph](#module-dependency-graph)
4. [Data Flow](#data-flow)
5. [File System Layout](#file-system-layout)
6. [Parallel Processing Architecture](#parallel-processing-architecture)
7. [Command Reference](#command-reference)
8. [Security Architecture](#security-architecture)
9. [Component Summary](#component-summary)

---

## Overview

**imgctl** is a scalable CLI tool designed for managing and viewing container images across a BCM (Bright Cluster Manager) cluster environment featuring:

- **NVIDIA DGX worker nodes** - High-performance GPU compute nodes running containerized workloads
- **Harbor private registry** - Enterprise container registry for storing and distributing images

### Key Capabilities

| Feature | Description |
|---------|-------------|
| **Multi-Source Viewing** | View images from Harbor registry and worker nodes simultaneously |
| **Parallel Processing** | Concurrent data fetching using GNU Parallel or native Bash jobs |
| **Image Comparison** | Compare images across nodes to identify common vs. unique images |
| **Flexible Output** | Table, JSON, and CSV output formats for different use cases |
| **Smart Filtering** | Exclude system images using configurable blocklists |
| **Caching** | TTL-based caching to reduce repeated API calls |

---

## High-Level Architecture

The following diagram illustrates the complete system architecture showing the relationship between the imgctl tool, worker nodes, and Harbor registry:

```
┌──────────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                          BCM CLUSTER ENVIRONMENT                                              │
│  ┌─────────────────────────────────────────────────────────────────────────────────────────────────────────┐ │
│  │                                           HEAD NODE                                                      │ │
│  │                                                                                                          │ │
│  │    ┌──────────────┐                                                                                      │ │
│  │    │   OPERATOR   │                                                                                      │ │
│  │    │              │                                                                                      │ │
│  │    │  $ imgctl    │                                                                                      │ │
│  │    │     get      │                                                                                      │ │
│  │    │   compare    │                                                                                      │ │
│  │    └──────┬───────┘                                                                                      │ │
│  │           │                                                                                              │ │
│  │           ▼                                                                                              │ │
│  │    ╔══════════════════════════════════════════════════════════════════════════════════════════════╗     │ │
│  │    ║                               imgctl CLI TOOL                                                 ║     │ │
│  │    ║  ┌─────────────────────────────────────────────────────────────────────────────────────────┐ ║     │ │
│  │    ║  │                            bin/imgctl (Entry Point)                                     │ ║     │ │
│  │    ║  │  • Command Parsing (get, compare, help)                                                 │ ║     │ │
│  │    ║  │  • Option Handling (-o, --no-color, -q, --version)                                      │ ║     │ │
│  │    ║  │  • Module Orchestration                                                                 │ ║     │ │
│  │    ║  │  • Parallel Data Fetching                                                               │ ║     │ │
│  │    ║  └───────────────────────────────────┬─────────────────────────────────────────────────────┘ ║     │ │
│  │    ║                                      │ sources                                               ║     │ │
│  │    ║  ┌───────────────────────────────────┴─────────────────────────────────────────────────────┐ ║     │ │
│  │    ║  │                                  lib/ MODULES                                           │ ║     │ │
│  │    ║  │                                                                                         │ ║     │ │
│  │    ║  │  ┌─────────────────────┐  ┌─────────────────────┐  ┌─────────────────────┐              │ ║     │ │
│  │    ║  │  │     common.sh       │  │     crictl.sh       │  │     harbor.sh       │              │ ║     │ │
│  │    ║  │  │  ─────────────────  │  │  ─────────────────  │  │  ─────────────────  │              │ ║     │ │
│  │    ║  │  │  • Logging          │  │  • SSH to workers   │  │  • Harbor REST API  │              │ ║     │ │
│  │    ║  │  │  • SSH Helpers      │  │  • crictl parsing   │  │  • URL encoding     │              │ ║     │ │
│  │    ║  │  │  • Cache Mgmt       │  │  • Parallel fetch   │  │  • Pagination       │              │ ║     │ │
│  │    ║  │  │  • Config Load      │  │  • Image compare    │  │  • Artifact fetch   │              │ ║     │ │
│  │    ║  │  │  • UUID/Correlation │  │  • Ignore filtering │  │  • Parallel repos   │              │ ║     │ │
│  │    ║  │  └─────────────────────┘  └─────────────────────┘  └─────────────────────┘              │ ║     │ │
│  │    ║  │                                                                                         │ ║     │ │
│  │    ║  │                           ┌─────────────────────┐                                       │ ║     │ │
│  │    ║  │                           │     output.sh       │                                       │ ║     │ │
│  │    ║  │                           │  ─────────────────  │                                       │ ║     │ │
│  │    ║  │                           │  • Table formatting │                                       │ ║     │ │
│  │    ║  │                           │  • JSON output      │                                       │ ║     │ │
│  │    ║  │                           │  • CSV export       │                                       │ ║     │ │
│  │    ║  │                           │  • Spinner/Progress │                                       │ ║     │ │
│  │    ║  │                           │  • Summary stats    │                                       │ ║     │ │
│  │    ║  │                           └─────────────────────┘                                       │ ║     │ │
│  │    ║  └─────────────────────────────────────────────────────────────────────────────────────────┘ ║     │ │
│  │    ╚══════════════════════════════════════════════════════════════════════════════════════════════╝     │ │
│  │           │                              │                                                               │ │
│  │           │ reads                        │ reads                                                         │ │
│  │           ▼                              ▼                                                               │ │
│  │    ┌─────────────────────────┐    ┌─────────────────────────┐                                           │ │
│  │    │  /etc/imgctl/           │    │  /var/cache/imgctl/     │                                           │ │
│  │    │  ├── imgctl.conf        │    │  └── *.cache files      │                                           │ │
│  │    │  └── images_to_ignore   │    │      (TTL: 300s)        │                                           │ │
│  │    └─────────────────────────┘    └─────────────────────────┘                                           │ │
│  │                                                                                                          │ │
│  └──────────────────────────────────────────────────────────────────────────────────────────────────────────┘ │
│                                                                                                               │
│        ┌──────────────────────────────────┐               ┌──────────────────────────────────┐               │
│        │          SSH (Port 22)           │               │        HTTPS (Port 9443)         │               │
│        │          ────────────            │               │        ──────────────            │               │
│        │  • BatchMode=yes                 │               │  • Harbor REST API v2.0          │               │
│        │  • StrictHostKeyChecking=no      │               │  • Basic Auth                    │               │
│        │  • ConnectTimeout=10s            │               │  • SSL (optional verify)         │               │
│        └─────────────┬────────────────────┘               └─────────────┬────────────────────┘               │
│                      │                                                  │                                    │
│                      ▼                                                  ▼                                    │
│  ┌────────────────────────────────────────────────┐    ┌────────────────────────────────────────────────┐   │
│  │             WORKER NODES (DGX)                  │    │              HARBOR REGISTRY                   │   │
│  │                                                 │    │                                                │   │
│  │  ┌──────────────┐    ┌──────────────┐           │    │  ┌──────────────────────────────────────────┐ │   │
│  │  │ k8s-worker1  │    │ k8s-worker2  │    ...    │    │  │          API Endpoints                   │ │   │
│  │  │              │    │              │           │    │  │  ─────────────────────────────────────── │ │   │
│  │  │ ┌──────────┐ │    │ ┌──────────┐ │           │    │  │  GET /api/v2.0/health                    │ │   │
│  │  │ │ containerd│ │    │ │ containerd│ │           │    │  │  GET /api/v2.0/projects                  │ │   │
│  │  │ │   + CRI   │ │    │ │   + CRI   │ │           │    │  │  GET /api/v2.0/projects/{p}/repositories│ │   │
│  │  │ └──────────┘ │    │ └──────────┘ │           │    │  │  GET /api/v2.0/.../artifacts              │ │   │
│  │  │      │       │    │      │       │           │    │  └──────────────────────────────────────────┘ │   │
│  │  │      ▼       │    │      ▼       │           │    │                                                │   │
│  │  │ ┌──────────┐ │    │ ┌──────────┐ │           │    │  ┌──────────────────────────────────────────┐ │   │
│  │  │ │  crictl  │ │    │ │  crictl  │ │           │    │  │           Projects                       │ │   │
│  │  │ │  images  │ │    │ │  images  │ │           │    │  │  ├── nvidia/                             │ │   │
│  │  │ └──────────┘ │    │ └──────────┘ │           │    │  │  │   └── pytorch:latest                  │ │   │
│  │  └──────────────┘    └──────────────┘           │    │  │  ├── ml-team/                            │ │   │
│  │                                                 │    │  │  │   └── training:v2.1                   │ │   │
│  │  Returns: IMAGE, TAG, IMAGE ID, SIZE            │    │  │  └── ...                                 │ │   │
│  └─────────────────────────────────────────────────┘    │  └──────────────────────────────────────────┘ │   │
│                                                         └────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Architecture Components

| Layer | Component | Description |
|-------|-----------|-------------|
| **User Interface** | CLI | Command-line interface for operators |
| **Application** | bin/imgctl | Main entry point and command router |
| **Libraries** | lib/*.sh | Modular bash libraries for specific functions |
| **Configuration** | /etc/imgctl/ | System configuration and ignore lists |
| **Cache** | /var/cache/imgctl/ | TTL-based response caching |
| **External - Compute** | Worker Nodes | DGX nodes running containerd + crictl |
| **External - Registry** | Harbor | Private container image registry |

---

## Module Dependency Graph

All library modules depend on `common.sh` which provides shared functionality:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           MODULE DEPENDENCIES                                    │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│                              ┌───────────────┐                                   │
│                              │   bin/imgctl  │                                   │
│                              │  (main CLI)   │                                   │
│                              └───────┬───────┘                                   │
│                                      │                                           │
│                     ┌────────────────┼────────────────┬────────────────┐         │
│                     │                │                │                │         │
│                     ▼                ▼                ▼                ▼         │
│              ┌───────────┐    ┌───────────┐    ┌───────────┐    ┌───────────┐   │
│              │ common.sh │    │ crictl.sh │    │ harbor.sh │    │ output.sh │   │
│              └───────────┘    └─────┬─────┘    └─────┬─────┘    └─────┬─────┘   │
│                    ▲                │                │                │         │
│                    │                │                │                │         │
│                    └────────────────┴────────────────┴────────────────┘         │
│                              (all depend on common.sh)                           │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Module Responsibilities

#### common.sh (Core Library)
The foundation module providing shared utilities used by all other modules:

```bash
# Exports provided by common.sh:
├── VERSION, Colors (RED, GREEN, YELLOW, BLUE, CYAN, NC, BOLD)
├── Logging: init_logging(), log_debug/info/warning/error()
├── SSH: build_ssh_command(), test_ssh_connection(), ssh_exec()
├── Cache: init_cache(), get_cache(), set_cache(), clear_cache()
├── Config: load_config(), find_config(), validate_config()
└── Utilities: print_header(), print_success/error/warning/info()
```

#### crictl.sh (Worker Node Module)
Handles communication with worker nodes via SSH:

- **parse_crictl_output()** - Converts crictl text output to JSON using AWK
- **get_node_images_single()** - Fetches images from one node with caching
- **get_all_nodes_images()** - Parallel orchestration across all nodes
- **compare_node_images()** - Map-reduce algorithm for image comparison

#### harbor.sh (Registry Module)
Manages Harbor REST API interactions:

- **harbor_curl()** - Low-level HTTP client with auth and SSL handling
- **harbor_api_get_all()** - Paginated API fetcher (up to 5000 items)
- **fetch_project_repos()** - Gets repositories for a project
- **process_harbor_repo()** - Extracts artifacts with tag flattening
- **get_harbor_images()** - Main orchestrator with parallel processing

#### output.sh (Display Module)
Handles all output formatting:

- **filter_harbor_images()** - Removes untagged images
- **start_spinner() / stop_spinner()** - Progress indicators
- **format_table()** - Columnar table output
- **format_comparison_table()** - Multi-section comparison display
- **format_report_json() / format_report_csv()** - Structured exports
- **display_output()** - Main routing function

---

## Data Flow

The following diagram shows how data flows through the system from user input to final output:

```
┌─────────────────────────────────────────────────────────────────────────────────────────────────────────┐
│                                        DATA FLOW                                                         │
├─────────────────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                                          │
│   ╔═══════════════╗                                                                                      │
│   ║  USER INPUT   ║                                                                                      │
│   ║  $ imgctl get ║                                                                                      │
│   ╚═══════┬═══════╝                                                                                      │
│           │                                                                                              │
│           ▼                                                                                              │
│   ┌───────────────────┐      ┌────────────────────────────────────────────────────────────────────┐     │
│   │   cmd_get()       │─────▶│                    PARALLEL DATA FETCH                             │     │
│   │   (orchestrator)  │      │  ┌─────────────────────────┐    ┌─────────────────────────┐        │     │
│   └───────────────────┘      │  │   get_harbor_images()   │    │  get_all_nodes_images() │        │     │
│                              │  │   (harbor.sh)           │    │  (crictl.sh)            │        │     │
│                              │  └───────────┬─────────────┘    └───────────┬─────────────┘        │     │
│                              └──────────────┼──────────────────────────────┼──────────────────────┘     │
│                                             │                              │                            │
│                                             ▼                              ▼                            │
│                              ┌──────────────────────────┐    ┌──────────────────────────┐               │
│                              │   Harbor REST API        │    │   SSH to Worker Nodes    │               │
│                              │   ─────────────────      │    │   ───────────────────    │               │
│                              │   GET /projects          │    │   crictl images          │               │
│                              │   GET /repositories      │    │   (parallel per node)    │               │
│                              │   GET /artifacts         │    │                          │               │
│                              │   (paginated + parallel) │    │                          │               │
│                              └───────────┬──────────────┘    └───────────┬──────────────┘               │
│                                          │                               │                              │
│                                          ▼                               ▼                              │
│                              ┌──────────────────────────┐    ┌──────────────────────────┐               │
│                              │   JSON Array             │    │   Text Table Output      │               │
│                              │   [{repository, tag,     │    │   IMAGE   TAG   ID SIZE  │               │
│                              │     digest, size,        │    │   nginx   1.0   abc 50MB │               │
│                              │     project}]            │    │   ...                    │               │
│                              └───────────┬──────────────┘    └───────────┬──────────────┘               │
│                                          │                               │                              │
│                                          │                               ▼                              │
│                                          │                  ┌──────────────────────────┐               │
│                                          │                  │  parse_crictl_output()   │               │
│                                          │                  │  (awk → JSON)            │               │
│                                          │                  └───────────┬──────────────┘               │
│                                          │                              │                              │
│                                          ▼                              ▼                              │
│                              ┌────────────────────────────────────────────────────────┐                │
│                              │                    FILTERING                           │                │
│                              │  ┌──────────────────────────────────────────────────┐ │                │
│                              │  │  • Remove <none> tags                            │ │                │
│                              │  │  • Apply images_to_ignore.txt blocklist          │ │                │
│                              │  │  • (regex matching via jq)                       │ │                │
│                              │  └──────────────────────────────────────────────────┘ │                │
│                              └───────────────────────────┬────────────────────────────┘                │
│                                                          │                                             │
│                                                          ▼                                             │
│                              ┌────────────────────────────────────────────────────────┐                │
│                              │              compare_node_images()                     │                │
│                              │  ┌──────────────────────────────────────────────────┐ │                │
│                              │  │  MAP-REDUCE: Node-Centric → Image-Centric        │ │                │
│                              │  │                                                  │ │                │
│                              │  │  Input:  {node1: [img1, img2], node2: [img1]}   │ │                │
│                              │  │  Output: {common: [img1], node_specific: {...}} │ │                │
│                              │  └──────────────────────────────────────────────────┘ │                │
│                              └───────────────────────────┬────────────────────────────┘                │
│                                                          │                                             │
│                                                          ▼                                             │
│                              ┌────────────────────────────────────────────────────────┐                │
│                              │                  display_output()                      │                │
│                              │  ┌──────────────────────────────────────────────────┐ │                │
│                              │  │  Format Selection:                               │ │                │
│                              │  │    table → format_table(), format_comparison()   │ │                │
│                              │  │    json  → format_report_json()                  │ │                │
│                              │  │    csv   → format_report_csv()                   │ │                │
│                              │  └──────────────────────────────────────────────────┘ │                │
│                              └───────────────────────────┬────────────────────────────┘                │
│                                                          │                                             │
│                                                          ▼                                             │
│                              ╔════════════════════════════════════════════════════════╗                │
│                              ║                     USER OUTPUT                        ║                │
│                              ╚════════════════════════════════════════════════════════╝                │
│                                                                                                          │
└─────────────────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Data Transformation Pipeline

1. **Collection Phase**
   - Harbor: REST API responses (JSON)
   - Nodes: crictl text tables via SSH

2. **Normalization Phase**
   - Parse crictl output to JSON using AWK
   - Flatten Harbor artifacts (one row per tag)
   - Convert sizes to human-readable format

3. **Filtering Phase**
   - Remove `<none>` tagged images
   - Apply ignore list from CSV file
   - Match using `repository,tag` keys

4. **Analysis Phase**
   - Map-reduce transformation for comparison
   - Identify common images (present on all nodes)
   - Identify unique images (node-specific)

5. **Output Phase**
   - Format selection (table/json/csv)
   - Summary statistics calculation
   - Final display to user

---

## File System Layout

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            FILESYSTEM LAYOUT                                     │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  DEVELOPMENT (Repository)              INSTALLED (System)                        │
│  ═════════════════════════             ══════════════════════                    │
│                                                                                  │
│  imgctl/                               /opt/imgctl/                              │
│  ├── bin/                              ├── bin/                                  │
│  │   └── imgctl ──────────────────────▶│   └── imgctl                           │
│  ├── lib/                              ├── lib/                                  │
│  │   ├── common.sh ───────────────────▶│   ├── common.sh                        │
│  │   ├── crictl.sh ───────────────────▶│   ├── crictl.sh                        │
│  │   ├── harbor.sh ───────────────────▶│   ├── harbor.sh                        │
│  │   └── output.sh ───────────────────▶│   └── output.sh                        │
│  ├── conf/                             └── conf/                                 │
│  │   └── imgctl.conf ─────────────────────────────────┐                         │
│  ├── images_to_ignore.txt ────────────────────────────┤                         │
│  ├── install.sh                                       │                         │
│  ├── uninstall.sh                                     │                         │
│  ├── tests/                                           │                         │
│  │   ├── common_test_cases.md                         │                         │
│  │   ├── crictl_test_cases.md                         ▼                         │
│  │   └── harbor_test_cases.md          /etc/imgctl/                             │
│  ├── docs/                             ├── imgctl.conf                          │
│  └── README.md                         └── images_to_ignore.txt                 │
│                                                                                  │
│                                        /usr/local/bin/                           │
│                                        └── imgctl ──▶ /opt/imgctl/bin/imgctl    │
│                                            (symlink)                             │
│                                                                                  │
│                                        /var/log/giindia/imgctl/                  │
│                                        └── imgctl-YYYY-MM-DD.log                │
│                                                                                  │
│                                        /var/cache/imgctl/                        │
│                                        ├── node_k8s_worker1.cache               │
│                                        ├── node_k8s_worker2.cache               │
│                                        └── harbor_images.cache                  │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Directory Purposes

| Path | Purpose | Permissions |
|------|---------|-------------|
| `/opt/imgctl/` | Application installation directory | 755 (root:root) |
| `/opt/imgctl/bin/` | Executable scripts | 755 |
| `/opt/imgctl/lib/` | Library modules | 644 |
| `/etc/imgctl/` | System configuration | 750 (root:root) |
| `/var/log/giindia/imgctl/` | Application logs | 750 (root:root) |
| `/var/cache/imgctl/` | Response cache | 750 (root:root) |
| `/usr/local/bin/imgctl` | Command symlink | symlink |

---

## Parallel Processing Architecture

imgctl uses a multi-level parallelization strategy to maximize performance:

```
┌─────────────────────────────────────────────────────────────────────────────────────────────┐
│                           PARALLEL PROCESSING STRATEGY                                       │
├─────────────────────────────────────────────────────────────────────────────────────────────┤
│                                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────────────────────┐   │
│  │                        cmd_get("all") - Top Level Parallelism                         │   │
│  │                                                                                       │   │
│  │    ┌─────────────────────────────┐      ┌─────────────────────────────┐              │   │
│  │    │  get_harbor_images() &      │      │  get_all_nodes_images() &   │              │   │
│  │    │  (background process)       │      │  (background process)       │              │   │
│  │    │         pid_harbor          │      │         pid_nodes           │              │   │
│  │    └─────────────────────────────┘      └─────────────────────────────┘              │   │
│  │                 │                                    │                               │   │
│  │                 └──────────────┬─────────────────────┘                               │   │
│  │                                │                                                     │   │
│  │                                ▼                                                     │   │
│  │                    wait $pid_harbor $pid_nodes                                       │   │
│  └──────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────────────────────┐   │
│  │                    get_all_nodes_images() - Node-Level Parallelism                   │   │
│  │                                                                                       │   │
│  │    Detection: HAS_PARALLEL=$(command -v parallel)                                     │   │
│  │                                                                                       │   │
│  │    ┌─────────────────────────────────────┐   ┌─────────────────────────────────────┐ │   │
│  │    │  GNU Parallel Available:            │   │  Fallback (Bash Background Jobs):  │ │   │
│  │    │  ─────────────────────────          │   │  ───────────────────────────────── │ │   │
│  │    │  printf '%s\n' "${nodes[@]}" |      │   │  for node in "${nodes[@]}"; do     │ │   │
│  │    │    parallel -j ${#nodes[@]} \       │   │    (get_node_images_single $node   │ │   │
│  │    │      get_node_images_single {}      │   │      > tmpdir/$node.json) &        │ │   │
│  │    │                                     │   │    pids+=($!)                      │ │   │
│  │    └─────────────────────────────────────┘   │  done                              │ │   │
│  │                                              │  wait "${pids[@]}"                 │ │   │
│  │                                              └─────────────────────────────────────┘ │   │
│  └──────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                              │
│  ┌──────────────────────────────────────────────────────────────────────────────────────┐   │
│  │                    get_harbor_images() - Repository-Level Parallelism                │   │
│  │                                                                                       │   │
│  │    Phase 1: Fetch Project Repos (Parallel)                                           │   │
│  │    ═══════════════════════════════════════                                           │   │
│  │    ┌─────────────┐  ┌─────────────┐  ┌─────────────┐                                 │   │
│  │    │ Project A   │  │ Project B   │  │ Project C   │  ...                            │   │
│  │    │ fetch_repos │  │ fetch_repos │  │ fetch_repos │                                 │   │
│  │    └──────┬──────┘  └──────┬──────┘  └──────┬──────┘                                 │   │
│  │           └────────────────┴────────────────┘                                        │   │
│  │                            │                                                         │   │
│  │                            ▼                                                         │   │
│  │    Phase 2: Process Artifacts (Parallel, max MAX_PARALLEL_JOBS=10)                   │   │
│  │    ═══════════════════════════════════════════════════════════════                   │   │
│  │    ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐                       │   │
│  │    │ Repo 1  │ │ Repo 2  │ │ Repo 3  │ │ Repo 4  │ │  ...    │                       │   │
│  │    │artifacts│ │artifacts│ │artifacts│ │artifacts│ │         │                       │   │
│  │    └─────────┘ └─────────┘ └─────────┘ └─────────┘ └─────────┘                       │   │
│  │                                                                                       │   │
│  └──────────────────────────────────────────────────────────────────────────────────────┘   │
│                                                                                              │
└─────────────────────────────────────────────────────────────────────────────────────────────┘
```

### Parallelization Levels

| Level | Scope | Method | Max Concurrency |
|-------|-------|--------|-----------------|
| **L1** | Top-level (Harbor vs Nodes) | Background processes | 2 |
| **L2** | Worker nodes | GNU Parallel / Bash jobs | Number of nodes |
| **L3** | Harbor projects | GNU Parallel / Bash jobs | MAX_PARALLEL_JOBS (10) |
| **L4** | Harbor repositories | GNU Parallel / Bash jobs | MAX_PARALLEL_JOBS (10) |

### Performance Benefits

- **Reduced latency**: Harbor and node fetching happen simultaneously
- **Scalability**: Supports clusters with many worker nodes
- **Graceful degradation**: Falls back to Bash jobs if GNU Parallel unavailable
- **Resource control**: Configurable MAX_PARALLEL_JOBS prevents overload

---

## Command Reference

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                              COMMAND REFERENCE                                   │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  imgctl get [SCOPE] [OPTIONS]                                                    │
│  ═════════════════════════════                                                   │
│                                                                                  │
│  ┌────────────┬────────────────────────────────────────────────────────────┐    │
│  │   SCOPE    │                      DATA SOURCES                          │    │
│  ├────────────┼────────────────────────────────────────────────────────────┤    │
│  │   all      │  Harbor API + Worker Nodes (parallel) + Compare            │    │
│  │   harbor   │  Harbor API only                                           │    │
│  │   nodes    │  Worker Nodes only + Compare                               │    │
│  └────────────┴────────────────────────────────────────────────────────────┘    │
│                                                                                  │
│  ┌────────────┬────────────────────────────────────────────────────────────┐    │
│  │   OPTION   │                      BEHAVIOR                              │    │
│  ├────────────┼────────────────────────────────────────────────────────────┤    │
│  │ -o table   │  Formatted table output (default)                          │    │
│  │ -o json    │  JSON output for scripting/automation                      │    │
│  │ -o csv     │  CSV export for spreadsheets                               │    │
│  │ --no-color │  Disable ANSI colors                                       │    │
│  │ -q/--quiet │  Minimal output (errors only)                              │    │
│  └────────────┴────────────────────────────────────────────────────────────┘    │
│                                                                                  │
│  imgctl compare [OPTIONS]                                                        │
│  ════════════════════════                                                        │
│  Fetches images from all worker nodes and produces:                              │
│    • Common images (present on ALL nodes)                                        │
│    • Node-specific images (unique to each node)                                  │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Usage Examples

```bash
# Get all images from Harbor and nodes
imgctl get

# Get only Harbor registry images
imgctl get harbor

# Get only worker node images
imgctl get nodes

# Export to JSON for automation
imgctl get -o json > images.json

# Export to CSV for spreadsheets
imgctl get -o csv > images.csv

# Compare images across nodes
imgctl compare

# Quiet mode for scripts
imgctl get -q -o json

# Show version
imgctl --version

# Show help
imgctl help
```

---

## Security Architecture

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            SECURITY CONSIDERATIONS                               │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │                         INSTALLATION SECURITY                             │   │
│  │  • Symlink attack protection (check_path_security)                        │   │
│  │  • Ownership verification (root-owned directories)                        │   │
│  │  • Secure umask (027) during directory creation                           │   │
│  │  • No symlink following during file copy                                  │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │                           CACHE SECURITY                                  │   │
│  │  • Cache key sanitization (alphanumeric only: ^[a-zA-Z0-9_-]+$)           │   │
│  │  • Prevents directory traversal attacks                                   │   │
│  │  • TTL-based expiration (default 300s)                                    │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │                          CREDENTIAL HANDLING                              │   │
│  │  • Config file permissions: 640 (root:root)                               │   │
│  │  • Harbor credentials in config file (not command line)                   │   │
│  │  • SSH key-based authentication supported                                 │   │
│  │  • Generic error messages (no internal path exposure)                     │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
│  ┌──────────────────────────────────────────────────────────────────────────┐   │
│  │                            LOGGING SECURITY                               │   │
│  │  • Correlation ID per session (traceable)                                 │   │
│  │  • Log rotation (30-day retention)                                        │   │
│  │  • Max log size limit (default 10MB)                                      │   │
│  │  • Secure log directory permissions (750)                                 │   │
│  └──────────────────────────────────────────────────────────────────────────┘   │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Security Checklist

| Category | Measure | Implementation |
|----------|---------|----------------|
| **Installation** | Symlink attack prevention | `check_path_security()` in install.sh |
| **Installation** | Ownership verification | `stat -c '%u'` check before operations |
| **Runtime** | Cache key validation | Regex `^[a-zA-Z0-9_-]+$` |
| **Runtime** | Path traversal prevention | Key sanitization in `get_cache()` |
| **Credentials** | Secure storage | Config file with 640 permissions |
| **Credentials** | No CLI exposure | Credentials read from config only |
| **Logging** | Session tracing | Correlation ID in all log entries |
| **Logging** | Log rotation | `LOG_RETENTION_DAYS` setting |
| **Errors** | Information hiding | Generic messages to users, detailed logs |

---

## Component Summary

| Component | File | Purpose |
|-----------|------|---------|
| **Main CLI** | `bin/imgctl` | Entry point, command routing, orchestration |
| **Common Library** | `lib/common.sh` | Logging, SSH, caching, config, utilities |
| **Crictl Module** | `lib/crictl.sh` | Worker node image retrieval via SSH+crictl |
| **Harbor Module** | `lib/harbor.sh` | Harbor REST API integration |
| **Output Module** | `lib/output.sh` | Table/JSON/CSV formatting, spinners |
| **Configuration** | `conf/imgctl.conf` | Cluster settings, credentials, paths |
| **Ignore List** | `images_to_ignore.txt` | CSV blocklist for filtering system images |
| **Installer** | `install.sh` | Secure installation to `/opt/imgctl` |
| **Uninstaller** | `uninstall.sh` | Clean removal with symlink protection |

---

## Related Documentation

- [README.md](../README.md) - Project overview and quick start
- [Test Cases - Common](../tests/common_test_cases.md)
- [Test Cases - Crictl](../tests/crictl_test_cases.md)
- [Test Cases - Harbor](../tests/harbor_test_cases.md)

---

*This documentation was auto-generated based on codebase analysis.*

