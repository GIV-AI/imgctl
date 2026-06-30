# Cluster Image Portal — Architecture & Sequence Diagrams

> Web GUI component of `imgctl` (v2.2.0). Short visual reference for admins and developers.
> A rendered PDF of this file is at [`Cluster-Image-Portal-Architecture.pdf`](Cluster-Image-Portal-Architecture.pdf).

**The one idea:** a **root producer** collects images on a timer and atomically writes a
JSON **snapshot**; an **unprivileged web service** only *reads* that snapshot. They share one
file and nothing else — so the public, no-auth web tier never runs `imgctl`, never SSHes, and
never sees Harbor credentials.

---

## 1. Architecture

```mermaid
flowchart LR
  browser["Browser<br/>Run:ai user"]

  subgraph head["BCM head node"]
    direction TB
    subgraph rootb["root · privileged producer"]
      direction TB
      timer["imgcatalog-refresh.timer<br/>every 5 min"]
      refresh["imgcatalog-refresh.service<br/>refresh.sh · root oneshot"]
      imgctl["imgctl get all -o json<br/>root CLI"]
      conf[("imgctl.conf · 640 root<br/>Harbor creds + config")]
      timer -->|fires| refresh
      refresh -->|runs| imgctl
      imgctl -.->|JSON stdout| refresh
      imgctl -. reads .-> conf
    end
    snap[("Snapshot<br/>/var/lib/imgcatalog/all.json<br/>0644 · atomic write")]
    subgraph unpriv["unprivileged · DynamicUser · hardened"]
      web["imgcatalog.service<br/>server.py · UI + /api/images"]
    end
    harbor["Harbor REST API<br/>/api/v2.0 · on head"]
    refresh ==>|"validate + atomic write"| snap
    web ==>|read per request| snap
    imgctl -->|curl REST| harbor
  end

  worker["DGX worker<br/>crictl / containerd"]
  imgctl -->|"SSH · crictl images"| worker
  browser -->|"HTTP :8088 · no auth<br/>firewall opened manually via cmsh"| web

  classDef seam fill:#76B900,stroke:#1A1A1A,color:#1A1A1A,font-weight:bold;
  classDef cfg fill:#FBEAE7,stroke:#C0341D;
  class snap seam;
  class conf cfg;
```

---

## 2. Sequence — refresh path (root producer, periodic)

```mermaid
sequenceDiagram
  autonumber
  participant T as refresh.timer
  participant R as refresh.sh (root)
  participant I as imgctl
  participant H as Harbor API
  participant W as DGX worker (crictl)
  participant S as Snapshot all.json
  T->>R: fire (boot+30s, then every 5 min)
  R->>I: imgctl get all -o json
  I->>H: GET /api/v2.0 (projects → repos → artifacts)
  I->>W: SSH → crictl images
  I-->>R: JSON {timestamp, harbor_images, comparison}
  R->>R: validate (jq) + inject harbor_host / cluster_name
  R->>S: temp → chmod 0644 → sync → atomic mv
  Note over R,S: on ANY failure, the last-good snapshot is left untouched
```

---

## 3. Sequence — request path (unprivileged web tier)

```mermaid
sequenceDiagram
  autonumber
  participant B as Browser (Run:ai user)
  participant Wb as imgcatalog.service
  participant S as Snapshot all.json
  B->>Wb: GET /  (HTTP :8088)
  Wb-->>B: static SPA (assets cached in memory)
  B->>Wb: GET /api/images
  Wb->>S: read snapshot (per request)
  Wb->>Wb: reshape → images[] each with exact pull reference
  Wb-->>B: application/json (+ CSP, X-Content-Type-Options)
  Note over B,Wb: no imgctl · no SSH · no Harbor · no creds — served only from the snapshot
  B->>B: search / filter / copy reference
```

---

## 4. Components & responsibilities

| Component | Runs as | Triggered by | Reads | Writes | Purpose |
|---|---|---|---|---|---|
| `imgcatalog-refresh.timer` | systemd | boot + every 5 min | — | — | Fires the refresh oneshot (`Persistent=true`) |
| `imgcatalog-refresh.service` → `refresh.sh` | **root** (oneshot) | the timer | `imgctl.conf` | the snapshot | Run imgctl, validate, atomically publish |
| `imgctl` | **root** (CLI) | `refresh.sh` | `imgctl.conf` | stdout → temp | Query Harbor API + `crictl` over SSH |
| Harbor REST API | service on head | imgctl | — | — | Source: custom/registry images |
| DGX worker `crictl` | on worker (via SSH) | imgctl | — | — | Source: node-cached NGC/Docker images |
| Snapshot `all.json` | file (`0644`) | — | by web tier | by `refresh.sh` | The decoupling seam (one JSON file) |
| `imgcatalog.service` → `server.py` | **unprivileged** `DynamicUser` (hardened) | always-on (`Restart=always`) | the snapshot | — | Serve UI + JSON API |
| Browser | client | user | `/`, `/api/images` | — | Browse + copy pull reference |

**API endpoints:** `GET /` (UI) · `GET /api/images` (flattened JSON, exact `reference` per image) · `GET /api/raw` (imgctl passthrough) · `GET /healthz` · `GET /version`. Non-GET/HEAD → `405`.

**Key paths / ops:** snapshot `/var/lib/imgcatalog/all.json`; units `imgcatalog.service` + `imgcatalog-refresh.timer`; install via `install.sh`; **firewall opened manually** via `cmsh … openports` (never hand-edit `/etc/shorewall/rules`).

**Security note:** the portal has **no authentication** and binds `0.0.0.0:8088` (plain HTTP) — access is gated **only by the firewall port**. The web tier is sandboxed (`DynamicUser`, `NoNewPrivileges`, empty `CapabilityBoundingSet`, `ProtectSystem=strict`, `MemoryMax`/`CPUQuota`/`TasksMax`, in-process connection cap) and is **read-only** — it exposes image names/tags/sizes only.
