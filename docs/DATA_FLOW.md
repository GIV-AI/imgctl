# imgctl - Data Flow & Processing Pipeline

> **Version:** 2.2.0  
> **Author:** Anubhav Patrick <anubhav.patrick@giindia.com>  
> **Organization:** Global Info Ventures Pvt Ltd

> **v2.2.0** — the Web GUI's snapshot producer (`web/refresh.sh`) runs this same `imgctl get all -o json` pipeline every ~5 min and atomically writes `/var/lib/imgcatalog/all.json`; the portal server reshapes it into `/api/images`. See [WEB_UI.md](WEB_UI.md).

---

## Overview

This document provides a detailed explanation of how data flows through imgctl, from initial user command to final output. Understanding this flow is essential for debugging, extending, or maintaining the tool.

---

## Table of Contents

1. [Command Entry Points](#command-entry-points)
2. [Data Collection Phase](#data-collection-phase)
3. [Data Transformation Phase](#data-transformation-phase)
4. [Comparison Algorithm](#comparison-algorithm)
5. [Output Generation](#output-generation)
6. [Caching Strategy](#caching-strategy)

---

## Command Entry Points

When a user executes an imgctl command, the following flow occurs:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            COMMAND ROUTING                                       │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   User Command                    Handler Function                               │
│   ────────────                    ────────────────                               │
│   $ imgctl get         ──────▶   cmd_get()                                      │
│   $ imgctl get all     ──────▶   cmd_get() → scope="all"                        │
│   $ imgctl get harbor  ──────▶   cmd_get() → scope="harbor"                     │
│   $ imgctl get nodes   ──────▶   cmd_get() → scope="nodes"                      │
│   $ imgctl compare     ──────▶   cmd_compare()                                  │
│   $ imgctl help        ──────▶   show_usage()                                   │
│                                                                                  │
│   main() Function Flow:                                                          │
│   ┌────────────────────────────────────────────────────────────────────────┐    │
│   │  1. Parse global options (--output, --no-color, --quiet, --version)    │    │
│   │  2. Load configuration (find_config → load_config)                     │    │
│   │  3. Check dependencies (ssh, curl, jq)                                 │    │
│   │  4. Initialize logging (init_logging)                                  │    │
│   │  5. Initialize cache (init_cache)                                      │    │
│   │  6. Validate configuration (validate_config)                           │    │
│   │  7. Route to command handler                                           │    │
│   │  8. Cleanup old logs (cleanup_old_logs)                                │    │
│   └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Initialization Sequence

```bash
# Configuration search order (first found wins)
1. /etc/imgctl/imgctl.conf          # System-wide configuration
2. /root/imgctl/conf/imgctl.conf    # Fallback for root user
```

---

## Data Collection Phase

### Harbor Registry Collection

The Harbor module (`harbor.sh`) collects images through a multi-stage process:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        HARBOR DATA COLLECTION                                    │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   Stage 1: Check Cache                                                           │
│   ════════════════════                                                           │
│   ┌────────────────────────────────────────────────────────────────────────┐    │
│   │  cache_key = "harbor_images"                                           │    │
│   │  if cache exists && age < CACHE_TTL:                                   │    │
│   │      return cached data                                                │    │
│   └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
│   Stage 2: Fetch Projects                                                        │
│   ═══════════════════════                                                        │
│   ┌────────────────────────────────────────────────────────────────────────┐    │
│   │  GET /api/v2.0/projects?page=1&page_size=100                           │    │
│   │  GET /api/v2.0/projects?page=2&page_size=100  (if needed)              │    │
│   │  ... (paginated until < page_size results)                             │    │
│   │                                                                        │    │
│   │  Result: ["nvidia", "ml-team", "devops", ...]                          │    │
│   └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
│   Stage 3: Fetch Repositories (Parallel)                                         │
│   ═══════════════════════════════════════                                        │
│   ┌────────────────────────────────────────────────────────────────────────┐    │
│   │  For each project (in parallel):                                       │    │
│   │    GET /api/v2.0/projects/{project}/repositories                       │    │
│   │                                                                        │    │
│   │  Output format (tab-separated):                                        │    │
│   │    project_name\tfull_repo_name                                        │    │
│   │    nvidia       nvidia/pytorch                                         │    │
│   │    nvidia       nvidia/cuda                                            │    │
│   │    ml-team      ml-team/training                                       │    │
│   └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
│   Stage 4: Fetch Artifacts (Parallel)                                            │
│   ════════════════════════════════════                                           │
│   ┌────────────────────────────────────────────────────────────────────────┐    │
│   │  For each repository (max MAX_PARALLEL_JOBS concurrent):               │    │
│   │    GET /api/v2.0/projects/{p}/repositories/{r}/artifacts?with_tag=true │    │
│   │                                                                        │    │
│   │  Input artifact:                                                       │    │
│   │  {                                                                     │    │
│   │    "digest": "sha256:abc123...",                                       │    │
│   │    "size": 5690831667,                                                 │    │
│   │    "tags": [{"name": "v1.0"}, {"name": "latest"}]                      │    │
│   │  }                                                                     │    │
│   │                                                                        │    │
│   │  Output (flattened - one row per tag):                                 │    │
│   │  [                                                                     │    │
│   │    {"repository": "nvidia/pytorch", "tag": "v1.0",                     │    │
│   │     "digest": "sha256:abc123...", "size": "5.3GB", "project": "nvidia"}│    │
│   │    {"repository": "nvidia/pytorch", "tag": "latest",                   │    │
│   │     "digest": "sha256:abc123...", "size": "5.3GB", "project": "nvidia"}│    │
│   │  ]                                                                     │    │
│   └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
│   Stage 5: Combine & Cache                                                       │
│   ════════════════════════                                                       │
│   ┌────────────────────────────────────────────────────────────────────────┐    │
│   │  all_images = jq -s 'map(select(. != null)) | add // []'               │    │
│   │  set_cache("harbor_images", all_images)                                │    │
│   │  return all_images                                                     │    │
│   └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Worker Node Collection

The crictl module (`crictl.sh`) collects images from worker nodes via SSH:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                        NODE DATA COLLECTION                                      │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   Stage 1: Node Discovery                                                        │
│   ═══════════════════════                                                        │
│   ┌────────────────────────────────────────────────────────────────────────┐    │
│   │  WORKER_NODES="k8s-worker1 k8s-worker2 k8s-worker3"                    │    │
│   │  read -ra nodes <<< "$WORKER_NODES"                                    │    │
│   │  nodes = ["k8s-worker1", "k8s-worker2", "k8s-worker3"]                 │    │
│   └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
│   Stage 2: Parallel SSH Execution                                                │
│   ═══════════════════════════════                                                │
│   ┌────────────────────────────────────────────────────────────────────────┐    │
│   │                                                                        │    │
│   │  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                │    │
│   │  │ k8s-worker1 │    │ k8s-worker2 │    │ k8s-worker3 │                │    │
│   │  │             │    │             │    │             │                │    │
│   │  │ ssh exec:   │    │ ssh exec:   │    │ ssh exec:   │                │    │
│   │  │ crictl      │    │ crictl      │    │ crictl      │                │    │
│   │  │ images      │    │ images      │    │ images      │                │    │
│   │  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘                │    │
│   │         │                  │                  │                        │    │
│   │         ▼                  ▼                  ▼                        │    │
│   │  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐                │    │
│   │  │ Text Output │    │ Text Output │    │ Text Output │                │    │
│   │  │ ─────────── │    │ ─────────── │    │ ─────────── │                │    │
│   │  │ IMAGE  TAG  │    │ IMAGE  TAG  │    │ IMAGE  TAG  │                │    │
│   │  │ nginx  1.0  │    │ nginx  1.0  │    │ redis  6.0  │                │    │
│   │  │ redis  6.0  │    │ redis  6.0  │    │ mongo  4.4  │                │    │
│   │  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘                │    │
│   │         │                  │                  │                        │    │
│   │         ▼                  ▼                  ▼                        │    │
│   │    parse_crictl_output() - AWK transforms to JSON                      │    │
│   │                                                                        │    │
│   └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
│   Stage 3: Parse crictl Output                                                   │
│   ════════════════════════════                                                   │
│   ┌────────────────────────────────────────────────────────────────────────┐    │
│   │  Input (crictl images text):                                           │    │
│   │  ┌──────────────────────────────────────────────────────────────────┐ │    │
│   │  │ IMAGE                          TAG       IMAGE ID       SIZE     │ │    │
│   │  │ docker.io/library/nginx        1.25      abc123def456   50MB     │ │    │
│   │  │ docker.io/library/redis        7.0       def456ghi789   40MB     │ │    │
│   │  └──────────────────────────────────────────────────────────────────┘ │    │
│   │                                                                        │    │
│   │  AWK Processing:                                                       │    │
│   │  1. Extract column positions from header                               │    │
│   │  2. Parse each row using substring extraction                          │    │
│   │  3. Trim whitespace from fields                                        │    │
│   │  4. Escape special characters                                          │    │
│   │  5. Build JSON array                                                   │    │
│   │                                                                        │    │
│   │  Output (JSON):                                                        │    │
│   │  [                                                                     │    │
│   │    {"repository": "docker.io/library/nginx", "tag": "1.25",            │    │
│   │     "image_id": "abc123def456", "size": "50MB"},                       │    │
│   │    {"repository": "docker.io/library/redis", "tag": "7.0",             │    │
│   │     "image_id": "def456ghi789", "size": "40MB"}                        │    │
│   │  ]                                                                     │    │
│   └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
│   Stage 4: Combine Node Results                                                  │
│   ═════════════════════════════                                                  │
│   ┌────────────────────────────────────────────────────────────────────────┐    │
│   │  Output format:                                                        │    │
│   │  {                                                                     │    │
│   │    "k8s-worker1": [...images...],                                      │    │
│   │    "k8s-worker2": [...images...],                                      │    │
│   │    "k8s-worker3": [...images...]                                       │    │
│   │  }                                                                     │    │
│   └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Data Transformation Phase

### Filtering Pipeline

Both Harbor and node images pass through filtering:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          FILTERING PIPELINE                                      │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   Filter 1: Remove Untagged Images                                               │
│   ════════════════════════════════                                               │
│   ┌────────────────────────────────────────────────────────────────────────┐    │
│   │  jq '.[] | select(.tag != "<none>" and .tag != "")'                    │    │
│   │                                                                        │    │
│   │  Removes:                                                              │    │
│   │  - Images with tag = "<none>"                                          │    │
│   │  - Images with empty tag                                               │    │
│   │  - Dangling images without proper tags                                 │    │
│   └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
│   Filter 2: Apply Ignore List (Node Images Only)                                 │
│   ══════════════════════════════════════════════                                 │
│   ┌────────────────────────────────────────────────────────────────────────┐    │
│   │  Ignore file format (images_to_ignore.txt):                            │    │
│   │  ┌──────────────────────────────────────────────────────────────────┐ │    │
│   │  │ IMAGE,TAG,IMAGE ID,SIZE                                          │ │    │
│   │  │ docker.io/calico/cni,v3.29.2,cda13293c895a,99.3MB                │ │    │
│   │  │ docker.io/calico/node,v3.29.2,048bf7af1f8c6,142MB                │ │    │
│   │  │ registry.k8s.io/pause,3.8,4873874c08efc,311kB                    │ │    │
│   │  └──────────────────────────────────────────────────────────────────┘ │    │
│   │                                                                        │    │
│   │  Conversion to JSON array:                                             │    │
│   │  ["docker.io/calico/cni,v3.29.2", "docker.io/calico/node,v3.29.2"...] │    │
│   │                                                                        │    │
│   │  Matching logic:                                                       │    │
│   │  key = "{repository},{tag}"                                            │    │
│   │  if key IN ignore_array: exclude                                       │    │
│   └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Size Normalization

Harbor artifact sizes are converted from bytes to human-readable format:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         SIZE NORMALIZATION                                       │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   Input: size in bytes (e.g., 5690831667)                                        │
│                                                                                  │
│   Conversion logic (in jq):                                                      │
│   ┌────────────────────────────────────────────────────────────────────────┐    │
│   │  if size < 1048576 (1MB):                                              │    │
│   │      format as KB (e.g., "512KB")                                      │    │
│   │  elif size < 1073741824 (1GB):                                         │    │
│   │      format as MB (e.g., "150MB")                                      │    │
│   │  else:                                                                 │    │
│   │      format as GB with 1 decimal (e.g., "5.3GB")                       │    │
│   └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
│   Examples:                                                                      │
│   524288        → "512KB"                                                        │
│   157286400     → "150MB"                                                        │
│   5690831667    → "5.3GB"                                                        │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Comparison Algorithm

The `compare_node_images()` function implements a map-reduce algorithm to transform node-centric data into image-centric data:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                      MAP-REDUCE COMPARISON ALGORITHM                             │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   INPUT: Node-Centric View                                                       │
│   ════════════════════════                                                       │
│   {                                                                              │
│     "node1": [                                                                   │
│       {"repository": "nginx", "tag": "1.0", ...},                               │
│       {"repository": "redis", "tag": "6.0", ...}                                │
│     ],                                                                           │
│     "node2": [                                                                   │
│       {"repository": "nginx", "tag": "1.0", ...}                                │
│     ]                                                                            │
│   }                                                                              │
│                                                                                  │
│   STEP 1: MAP - Create Image References                                          │
│   ═══════════════════════════════════════                                        │
│   ┌────────────────────────────────────────────────────────────────────────┐    │
│   │  For each node, for each image:                                        │    │
│   │    ref = "{repository}:{tag}"                                          │    │
│   │    emit: { ref, node, image_data }                                     │    │
│   │                                                                        │    │
│   │  Emitted records:                                                      │    │
│   │    { ref: "nginx:1.0", node: "node1", image: {...} }                   │    │
│   │    { ref: "redis:6.0", node: "node1", image: {...} }                   │    │
│   │    { ref: "nginx:1.0", node: "node2", image: {...} }                   │    │
│   └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
│   STEP 2: REDUCE - Group by Image Reference                                      │
│   ═════════════════════════════════════════                                      │
│   ┌────────────────────────────────────────────────────────────────────────┐    │
│   │  Group by ref, collect nodes:                                          │    │
│   │                                                                        │    │
│   │  {                                                                     │    │
│   │    "nginx:1.0": {                                                      │    │
│   │      image: {...nginx data...},                                        │    │
│   │      nodes: ["node1", "node2"]     ← present on 2 nodes               │    │
│   │    },                                                                  │    │
│   │    "redis:6.0": {                                                      │    │
│   │      image: {...redis data...},                                        │    │
│   │      nodes: ["node1"]              ← present on 1 node                │    │
│   │    }                                                                   │    │
│   │  }                                                                     │    │
│   └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
│   STEP 3: CLASSIFY - Common vs Node-Specific                                     │
│   ══════════════════════════════════════════                                     │
│   ┌────────────────────────────────────────────────────────────────────────┐    │
│   │  node_count = 2  (total nodes)                                         │    │
│   │                                                                        │    │
│   │  For each image:                                                       │    │
│   │    if nodes.length == node_count:                                      │    │
│   │      → add to "common"                                                 │    │
│   │    else:                                                               │    │
│   │      → add to "node_specific[node]" for each node in nodes            │    │
│   └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
│   OUTPUT: Image-Centric View                                                     │
│   ══════════════════════════                                                     │
│   {                                                                              │
│     "common": [                                                                  │
│       {"repository": "nginx", "tag": "1.0", ...}                                │
│     ],                                                                           │
│     "node_specific": {                                                           │
│       "node1": [                                                                 │
│         {"repository": "redis", "tag": "6.0", ...}                              │
│       ],                                                                         │
│       "node2": []                                                                │
│     }                                                                            │
│   }                                                                              │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### jq Implementation

The actual jq implementation in `crictl.sh`:

```jq
# Filter all node images first
map_values([.[] | select(should_keep)]) |

# Capture node names BEFORE transforming
keys as $nodes |

# MAP-REDUCE transformation
reduce (to_entries[] | .key as $node | .value[] | {
    ref: "\(.repository):\(.tag)",
    node: $node,
    image: .
}) as $item (
    {};
    .[$item.ref] = (.[$item.ref] // {image: $item.image, nodes: []}) |
    .[$item.ref].nodes += [$item.node]
) |

# CLASSIFY into common and node-specific
. as $map |
($nodes | length) as $node_count |
{
    common: [$map | to_entries[] | 
             select(.value.nodes | length == $node_count) | 
             .value.image],
    
    node_specific: (reduce $nodes[] as $node ({}; 
        .[$node] = [$map | to_entries[] | 
            select(.value.nodes | length < $node_count) | 
            select(.value.nodes | contains([$node])) | 
            .value.image
        ]
    ))
}
```

---

## Output Generation

### Output Format Selection

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         OUTPUT FORMAT ROUTING                                    │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   display_output(format, harbor_images, node_images, comparison)                 │
│                                                                                  │
│   ┌────────────┬────────────────────────────────────────────────────────────┐   │
│   │   FORMAT   │                      HANDLER                              │   │
│   ├────────────┼────────────────────────────────────────────────────────────┤   │
│   │   table    │  format_table() + format_comparison_table()               │   │
│   │            │  + print_summary()                                        │   │
│   ├────────────┼────────────────────────────────────────────────────────────┤   │
│   │   json     │  format_report_json()                                     │   │
│   │            │  Returns: { timestamp, harbor_images, comparison }        │   │
│   ├────────────┼────────────────────────────────────────────────────────────┤   │
│   │   csv      │  format_report_csv()                                      │   │
│   │            │  Header: source,repository,tag,id,size                    │   │
│   └────────────┴────────────────────────────────────────────────────────────┘   │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Table Output Structure

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                         TABLE OUTPUT STRUCTURE                                   │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   Section Order:                                                                 │
│   ══════════════                                                                 │
│   1. Harbor Registry Images                                                      │
│   2. Common Images (present on all nodes)                                        │
│   3. Unique Images per Node (sorted by node name)                                │
│   4. Summary Statistics                                                          │
│                                                                                  │
│   Example Output:                                                                │
│   ┌──────────────────────────────────────────────────────────────────────────┐  │
│   │                                                                          │  │
│   │  Harbor Registry Images (5 images)                                       │  │
│   │  ───────────────────────────────────────────────────────────────────     │  │
│   │  REPOSITORY                       TAG          DIGEST          SIZE      │  │
│   │  ───────────────────────────────────────────────────────────────────     │  │
│   │  nvidia/pytorch                   2.1          sha256:abc...   5.3GB     │  │
│   │  nvidia/cuda                      12.0         sha256:def...   3.1GB     │  │
│   │  ...                                                                     │  │
│   │                                                                          │  │
│   │  === Worker Node Images (Filtered) ===                                   │  │
│   │                                                                          │  │
│   │  Common Images (Present on all worker nodes) - 3 images                  │  │
│   │  ───────────────────────────────────────────────────────────────────     │  │
│   │  REPOSITORY                       TAG          IMAGE ID        SIZE      │  │
│   │  ───────────────────────────────────────────────────────────────────     │  │
│   │  docker.io/library/nginx          1.25         abc123def456    50MB      │  │
│   │  ...                                                                     │  │
│   │                                                                          │  │
│   │  Unique Images on k8s-worker1 - 2 images                                 │  │
│   │  ───────────────────────────────────────────────────────────────────     │  │
│   │  ...                                                                     │  │
│   │                                                                          │  │
│   │  Summary                                                                 │  │
│   │  ────────────────────────────────────────────────                        │  │
│   │    Harbor Registry:         5 images                                     │  │
│   │    Common across nodes:     3 images                                     │  │
│   │    Unique to k8s-worker1:   2 images                                     │  │
│   │    Unique to k8s-worker2:   0 images                                     │  │
│   │                                                                          │  │
│   │    Total images per node (before filtering):                             │  │
│   │      k8s-worker1: 25 images                                              │  │
│   │      k8s-worker2: 23 images                                              │  │
│   │                                                                          │  │
│   └──────────────────────────────────────────────────────────────────────────┘  │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## Caching Strategy

imgctl implements a TTL-based caching strategy to reduce redundant API calls:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          CACHING ARCHITECTURE                                    │
├─────────────────────────────────────────────────────────────────────────────────┤
│                                                                                  │
│   Cache Configuration:                                                           │
│   ════════════════════                                                           │
│   ENABLE_CACHE="true"           # Enable/disable caching                         │
│   CACHE_DIR="/var/cache/imgctl" # Cache file location                            │
│   CACHE_TTL="300"               # Time-to-live in seconds (5 minutes)            │
│                                                                                  │
│   Cache Keys:                                                                    │
│   ════════════                                                                   │
│   ┌────────────────────────────────────────────────────────────────────────┐    │
│   │  Source          │  Key Format            │  Example                   │    │
│   │  ─────────────── │  ───────────────────── │  ─────────────────────────│    │
│   │  Harbor Registry │  "harbor_images"       │  harbor_images.cache       │    │
│   │  Worker Node     │  "node_{sanitized}"    │  node_k8s_worker1.cache    │    │
│   └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
│   Cache Flow:                                                                    │
│   ════════════                                                                   │
│   ┌────────────────────────────────────────────────────────────────────────┐    │
│   │                                                                        │    │
│   │                 ┌──────────────────┐                                   │    │
│   │                 │   get_cache(key) │                                   │    │
│   │                 └────────┬─────────┘                                   │    │
│   │                          │                                             │    │
│   │            ┌─────────────┴─────────────┐                               │    │
│   │            │                           │                               │    │
│   │            ▼                           ▼                               │    │
│   │    ┌─────────────┐             ┌─────────────┐                         │    │
│   │    │ Cache Hit   │             │ Cache Miss  │                         │    │
│   │    │ & Fresh     │             │ or Stale    │                         │    │
│   │    └──────┬──────┘             └──────┬──────┘                         │    │
│   │           │                           │                                │    │
│   │           ▼                           ▼                                │    │
│   │    ┌─────────────┐             ┌─────────────┐                         │    │
│   │    │ Return      │             │ Fetch Fresh │                         │    │
│   │    │ Cached Data │             │ Data        │                         │    │
│   │    └─────────────┘             └──────┬──────┘                         │    │
│   │                                       │                                │    │
│   │                                       ▼                                │    │
│   │                                ┌─────────────┐                         │    │
│   │                                │ set_cache() │                         │    │
│   │                                │ Store Data  │                         │    │
│   │                                └─────────────┘                         │    │
│   │                                                                        │    │
│   └────────────────────────────────────────────────────────────────────────┘    │
│                                                                                  │
│   Cache Security:                                                                │
│   ═══════════════                                                                │
│   • Key sanitization: Only [a-zA-Z0-9_-] allowed                                 │
│   • Prevents directory traversal attacks                                         │
│   • Stale cache is deleted, not returned                                         │
│                                                                                  │
└─────────────────────────────────────────────────────────────────────────────────┘
```

### Cache Invalidation

Cache entries are automatically invalidated based on:

1. **TTL Expiration**: Entries older than `CACHE_TTL` seconds are deleted on access
2. **Manual Clear**: `clear_cache()` function removes all cache files
3. **Config Change**: Cache is per-node/per-registry, so adding nodes creates new entries

---

## Related Documentation

- [ARCHITECTURE.md](./ARCHITECTURE.md) - System architecture overview
- [README.md](../README.md) - Project overview and quick start

---

*This documentation was auto-generated based on codebase analysis.*

