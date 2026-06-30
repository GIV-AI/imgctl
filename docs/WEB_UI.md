# Web GUI — Cluster Image Portal

A read-only web portal + JSON API that lists the images `imgctl` discovers, so end users
(e.g. Run:ai users in a browser) can find an image and copy its exact pull reference
**without SSH-ing into the head node**.

- **Version:** 2.2.0
- **Author:** Anubhav Patrick — Global Info Ventures Pvt Ltd

---

## 1. Architecture (decoupled producer / consumer)

```
 imgcatalog-refresh.timer  ──every ~5 min──▶  imgcatalog-refresh.service  (root, oneshot)
                                                  │  runs: imgctl get all -o json
                                                  │  validates (parses + expected shape)
                                                  │  injects harbor_host + display text
                                                  ▼  atomic mv (never a partial write)
                                        /var/lib/imgcatalog/all.json   (0644, world-readable)
                                                  │  (read-only)
 imgcatalog.service  (unprivileged, DynamicUser) ─┘
   python3 /opt/imgctl/web/server.py   →  serves static UI + JSON API on TCP 8088
                                                  │
        http://<head-ip>:8088/   (UI)    http://<head-ip>:8088/api/images   (JSON)
```

**Why this shape**
- The data lives only on the head node (root SSH to the worker for `crictl` + the head-local
  Harbor API). `imgctl` already owns both, so the portal runs on the head and **reuses imgctl**.
- The web tier is **unprivileged** and only ever **reads** a file — it never runs `imgctl`,
  never SSHes, and never sees Harbor credentials. The only root piece is the refresh oneshot.
- The slow head→worker SSH is kept **off the request path**: pages are instant, and a transient
  Harbor/worker error leaves the last-good snapshot in place (the UI shows a "stale" banner).

**Faithful display (no de-duplication).** Harbor (registry on the head) and the worker's local
cache are *different storage*. An image present in both is shown as **two rows** — one per
source/badge — on purpose. Nothing that exists is hidden or merged.

---

## 2. Files

| Path (installed) | Purpose |
|---|---|
| `/opt/imgctl/web/server.py` | Python-stdlib HTTP server (UI + `/api/*`). Zero pip deps. |
| `/opt/imgctl/web/refresh.sh` | Producer: `imgctl get all -o json` → validate → atomic write snapshot. |
| `/opt/imgctl/web/static/{index.html,style.css,app.js}` | The single-page UI (no build, no CDN). |
| `/etc/systemd/system/imgcatalog.service` | Unprivileged web service. |
| `/etc/systemd/system/imgcatalog-refresh.service` | Root oneshot that runs `refresh.sh`. |
| `/etc/systemd/system/imgcatalog-refresh.timer` | Fires the refresh every 5 min (+ on boot). |
| `/var/lib/imgcatalog/all.json` | The snapshot (root writes; web reads). |

Source lives in the repo under `web/` and is installed by `install.sh`.

---

## 3. Install

```bash
sudo ./install.sh          # installs CLI + GUI
sudo ./install.sh --no-gui # CLI only
```

The installer copies `web/` to `/opt/imgctl/web`, installs + enables the units, writes the
first snapshot, and **preserves** any existing `/etc/imgctl/imgctl.conf` and
`images_to_ignore.txt` (it backs them up and does not overwrite them — so the portal shows
exactly what the CLI does). It does **not** touch the firewall (see next).

---

## 4. Open the firewall port — MANUAL admin step

The portal listens on **TCP `WEB_PORT`** (default `8088`). The scripts never modify the
firewall; an admin opens it once. On a BCM head node use `cmsh` — **do not hand-edit
`/etc/shorewall/rules`**, CMDaemon regenerates it:

```
cmsh
% device; use $(hostname -s); roles; use firewall
% openports; add ACCEPT net 8088 tcp fw; commit
```

Verify, then share the URL:

```bash
curl -s http://127.0.0.1:8088/healthz          # {"status":"ok",...}
# from another host on the network / the public IP:
curl -s http://<head-ip>:8088/api/images | jq '.images | length'
```

Browse to `http://<head-host-or-ip>:8088/`.

---

## 5. Configuration

All keys are in `/etc/imgctl/imgctl.conf`. The server has built-in defaults, so it runs even
if these are absent. After changing them, the next refresh (≤5 min) applies them, or run
`sudo /opt/imgctl/web/refresh.sh` to apply immediately.

| Key | Default | Notes |
|---|---|---|
| `WEB_PORT` | `8088` | Listener port (also referenced in the systemd unit `Environment=`). |
| `WEB_BIND_ADDRESS` | `0.0.0.0` | `0.0.0.0` = remote-reachable via the head IP. |
| `WEB_SNAPSHOT_PATH` | `/var/lib/imgcatalog/all.json` | Producer writes / server reads. |
| `WEB_STALE_AFTER` | `900` | Seconds before the UI flags data stale. |
| `WEB_HARBOR_REGISTRY_HOST` | _(blank → from `HARBOR_URL`)_ | Prepended to **custom/Harbor** pull refs; NGC/Docker node refs already carry their host. |
| `WEB_SITE_TITLE` | `Cluster Image Portal` | Header title. |
| `WEB_SITE_SUBTITLE` | _(blank → `CLUSTER_NAME`)_ | Header subtitle. |
| `WEB_LABEL_HARBOR` | `Harbor` | Badge/label for registry images. |
| `WEB_LABEL_NODE` | `Node` | Badge/label for worker-cached images (e.g. `DGX cache`). |

> The port lives in two places — the conf (read by `refresh.sh` for messages) and the
> `imgcatalog.service` `Environment=WEB_PORT=` (read by the server). To change the listening
> port, edit the unit's `Environment=` (or add a drop-in) and `systemctl daemon-reload`.

---

## 6. API

| Endpoint | Returns |
|---|---|
| `GET /` | The web UI (static). |
| `GET /api/images` | `{generated_at, stale, sources:{harbor:{count},node:{count}}, images:[{source,repository,tag,size,id,reference}], ...}` — each `reference` is the exact copy-paste pull string. |
| `GET /api/raw` | The unmodified `imgctl get all -o json` snapshot. |
| `GET /healthz` | `{"status":"ok","version":"..."}`. |
| `GET /version` | Plain-text version. |

Only `GET`/`HEAD` are allowed (others get `405`); unknown paths get `404`; errors never leak a
stack trace.

---

## 7. Operate

```bash
systemctl status imgcatalog.service imgcatalog-refresh.timer
systemctl list-timers imgcatalog-refresh.timer        # next/last fire
journalctl -u imgcatalog.service -n 50                # web logs
journalctl -u imgcatalog-refresh.service -n 50        # producer logs
sudo /opt/imgctl/web/refresh.sh                       # force a refresh now
stat -c '%y %s bytes' /var/lib/imgcatalog/all.json    # snapshot freshness/size
```

---

## 8. Troubleshooting (failure modes & expected behavior)

| Symptom | Cause | Behavior / fix |
|---|---|---|
| UI shows **"Warming up"** | First refresh hasn't completed | Wait one cycle, or run `refresh.sh`. |
| UI shows a **stale banner** | Refresh failing (worker SSH down, Harbor down, imgctl error) | Last-good snapshot is still served. Check `journalctl -u imgcatalog-refresh`. The producer **never overwrites** a good snapshot with a bad run. |
| One source shows **0** | That source returned nothing | Banner notes which source; the other source still lists. Verify `imgctl get harbor` / `imgctl get nodes`. |
| **Couldn't load images** (browser) | Web service down / `/api/images` unreachable | `systemctl restart imgcatalog.service`; the service has `Restart=always`. |
| Port not reachable off-host | Firewall rule not added (or reverted) | Re-add via `cmsh openports` (§4). Confirm with `ss -ltn | grep 8088` on the head. |
| Copy button does nothing | Plain-HTTP origin blocks the async clipboard API | The UI falls back to `execCommand`, then to a "press Ctrl+C" popover — all copy the full reference. |

---

## 9. Security / exposure

- **No authentication.** With `WEB_BIND_ADDRESS=0.0.0.0` the portal is reachable by anyone who
  can reach the port (intended for remote team access). It exposes only image
  names/tags/sizes, read-only. If that inventory is sensitive, scope the `openports` source to
  a CIDR, or front the service with an authenticating reverse proxy.
- **Hardened web unit:** unprivileged (`DynamicUser`), `NoNewPrivileges`, empty
  `CapabilityBoundingSet`, `ProtectSystem=strict`, syscall filter, and `MemoryMax`/`CPUQuota`/
  `TasksMax` caps + an in-process connection cap — a leak or flood can't disturb
  CMDaemon/Harbor/BIND/kubectl on the head.
- **By construction:** static assets are loaded into memory behind a fixed route allowlist (no
  filesystem path join → no traversal); the UI renders image/tag strings via `textContent`
  under a strict CSP (injected markup is inert); Harbor credentials never enter the web tier.

---

## 10. Rollback / uninstall

`sudo ./uninstall.sh` stops + removes the three units and `/var/lib/imgcatalog`, removes
`/opt/imgctl` (incl. `web/`), and **backs up `imgctl.conf` + `images_to_ignore.txt` to
`/var/backups/imgctl/<timestamp>/` before removing anything**. It then reminds you to remove
the firewall rule manually:

```
cmsh
% device; use $(hostname -s); roles; use firewall
% openports; remove ACCEPT net 8088 tcp fw; commit
```

The GUI is purely additive — removing it does not affect the `imgctl` CLI, Harbor, or the
cluster.

---

## 11. Development & tests

```bash
# Unit tests for the server's pure logic (reshape, pull-reference, stale, path-safety):
python -m unittest discover -s tests -p 'test_*.py'

# Run the server locally against a captured snapshot (no install needed):
WEB_SNAPSHOT_PATH=/path/to/all.json WEB_STATIC_DIR=web/static \
  WEB_BIND_ADDRESS=127.0.0.1 WEB_PORT=8099 python3 web/server.py
```

Manual UI/API/security test cases: [`tests/web_test_cases.md`](../tests/web_test_cases.md).
