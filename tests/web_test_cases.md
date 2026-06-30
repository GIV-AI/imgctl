# Web GUI (Cluster Image Portal) — Test Cases

**Module:** `web/server.py`, `web/refresh.sh`, `web/static/*`, systemd units
**Version:** 2.2.0
**Author:** Anubhav Patrick
**Last Updated:** 2026-06-30

> Automated unit tests for the server's pure logic live in `tests/test_web_portal.py`
> (`python -m unittest discover -s tests -p 'test_*.py'`). The cases below are manual /
> integration checks. On a live cluster, all checks here are read-only except the gated
> install + the manual `cmsh openports` step.

---

## Table of Contents
1. [API Contract](#1-api-contract)
2. [Data Reshaping & Pull References](#2-data-reshaping--pull-references)
3. [UI Rendering & Interaction](#3-ui-rendering--interaction)
4. [Security](#4-security)
5. [Service / Lifecycle](#5-service--lifecycle)
6. [Exposure / Network](#6-exposure--network)
7. [Failure Modes](#7-failure-modes)

---

## 1. API Contract

### TC-API-001: Health endpoint
| Field | Value |
|-------|-------|
| **Objective** | `/healthz` returns ok + version |
| **Test Command** | `curl -s http://127.0.0.1:8088/healthz` |
| **Expected Result** | `{"status":"ok","version":"2.2.0"}`, HTTP 200, `Content-Type: application/json` |
| **Status** | ☐ Pass ☐ Fail |

### TC-API-002: Images endpoint shape
| Field | Value |
|-------|-------|
| **Objective** | `/api/images` returns the documented shape |
| **Test Command** | `curl -s http://127.0.0.1:8088/api/images \| jq '{status,generated_at,stale,sources,n:(.images\|length)}'` |
| **Expected Result** | Object with `status`, `generated_at`, `stale`, `sources.harbor.count`, `sources.node.count`, and an `images` array |
| **Status** | ☐ Pass ☐ Fail |

### TC-API-003: Each image row has a pull reference
| Field | Value |
|-------|-------|
| **Objective** | Every row carries source/repository/tag/size/id/reference |
| **Test Command** | `curl -s .../api/images \| jq '[.images[] \| select(.reference==null or .reference=="")] \| length'` |
| **Expected Result** | `0` |
| **Status** | ☐ Pass ☐ Fail |

### TC-API-004: Method not allowed
| Field | Value |
|-------|-------|
| **Objective** | Non-GET/HEAD is rejected |
| **Test Command** | `curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:8088/api/images` |
| **Expected Result** | `405` with an `Allow: GET, HEAD` header |
| **Status** | ☐ Pass ☐ Fail |

### TC-API-005: Unknown path 404 (no stack trace)
| Field | Value |
|-------|-------|
| **Objective** | Unknown route returns a clean 404 |
| **Test Command** | `curl -s -w '\n%{http_code}' http://127.0.0.1:8088/nope` |
| **Expected Result** | `{"error":"not found"}` + `404`; no Python traceback in body |
| **Status** | ☐ Pass ☐ Fail |

---

## 2. Data Reshaping & Pull References

### TC-RSH-001: Count cross-check vs imgctl
| Field | Value |
|-------|-------|
| **Objective** | API row count == imgctl harbor + node counts |
| **Test Command** | Compare `curl .../api/images \| jq '.images\|length'` against `imgctl get all -o json \| jq '(.harbor_images\|length) + (.comparison.common\|length) + ([.comparison.node_specific[]?]\|add\|length // 0)'` |
| **Expected Result** | Equal |
| **Status** | ☐ Pass ☐ Fail |

### TC-RSH-002: Harbor pull reference is host-prefixed
| Field | Value |
|-------|-------|
| **Objective** | Custom/Harbor refs get `<host>:9443/` prepended |
| **Test Command** | `curl -s .../api/images \| jq -r '.images[] \| select(.source=="harbor") \| .reference' \| head` |
| **Expected Result** | e.g. `vips-headnode:9443/custom/<image>:<tag>` |
| **Status** | ☐ Pass ☐ Fail |

### TC-RSH-003: Node (NGC/Docker) reference is unprefixed
| Field | Value |
|-------|-------|
| **Objective** | Already-host-qualified node refs are returned as-is |
| **Test Command** | `curl -s .../api/images \| jq -r '.images[] \| select(.source=="node" and (.repository\|startswith("nvcr.io"))) \| .reference' \| head` |
| **Expected Result** | e.g. `nvcr.io/nvidia/pytorch:25.06-py3` (no head-host prefix) |
| **Status** | ☐ Pass ☐ Fail |

### TC-RSH-004: Faithful display — both copies shown
| Field | Value |
|-------|-------|
| **Objective** | An image in BOTH Harbor and the worker cache appears twice (one per source) |
| **Test Command** | Pick a custom image present in both; `curl .../api/images \| jq '[.images[] \| select(.repository\|contains("<name>"))] \| group_by(.source) \| length'` |
| **Expected Result** | `2` (a harbor row and a node row) — never merged |
| **Status** | ☐ Pass ☐ Fail |

### TC-RSH-005: Config-driven labels & title
| Field | Value |
|-------|-------|
| **Objective** | `WEB_*` display keys flow through to the API |
| **Test Command** | `curl -s .../api/images \| jq '{site_title,site_subtitle,label_harbor,label_node,cluster_name}'` |
| **Expected Result** | Values match `/etc/imgctl/imgctl.conf` (or sensible blanks) — nothing hardcoded |
| **Status** | ☐ Pass ☐ Fail |

---

## 3. UI Rendering & Interaction

### TC-UI-001: Page loads and lists images
| Objective | Open `http://<head>:8088/` |
|---|---|
| **Expected** | Header + summary metrics + table render; "Showing N of N"; no console errors |
| **Status** | ☐ Pass ☐ Fail |

### TC-UI-002: Search (multi-term AND) + highlight
| Objective | Type two terms (e.g. `pytorch 26`) |
|---|---|
| **Expected** | Only rows matching both terms; matched substrings highlighted; URL gains `?q=` |
| **Status** | ☐ Pass ☐ Fail |

### TC-UI-003: Source filter (single mechanism)
| Objective | Click `Harbor` then `Node/DGX cache` in the segmented control |
|---|---|
| **Expected** | Rows filter by source; count updates; summary cards are **informational only** (do not also filter) |
| **Status** | ☐ Pass ☐ Fail |

### TC-UI-004: Copy button copies exact reference (HTTP fallback)
| Objective | Click `Copy`, then paste elsewhere |
|---|---|
| **Expected** | Clipboard holds the exact `reference` (incl. host prefix for custom); over plain HTTP the `execCommand` fallback works; button shows "Copied ✓" |
| **Status** | ☐ Pass ☐ Fail |

### TC-UI-005: Long image name / digest tag
| Objective | View a row with a 64-char digest tag |
|---|---|
| **Expected** | Tag chip middle-truncated (`539ce8…0e430c`), reference line ellipsised with full value in tooltip; layout intact; Copy still yields the full string |
| **Status** | ☐ Pass ☐ Fail |

### TC-UI-006: Responsive (mobile cards)
| Objective | Narrow the window < 640px |
|---|---|
| **Expected** | Table switches to stacked cards; Copy button full-width; reference wraps; no horizontal overflow |
| **Status** | ☐ Pass ☐ Fail |

### TC-UI-007: Stale banner
| Objective | Snapshot older than `WEB_STALE_AFTER` |
|---|---|
| **Expected** | Freshness pill turns red ("…ago"), a banner notes staleness; data still shown |
| **Status** | ☐ Pass ☐ Fail |

---

## 4. Security

### TC-SEC-001: Path traversal blocked
| Objective | Request traversal/encoded paths |
|---|---|
| **Test Command** | `curl -s -o /dev/null -w '%{http_code}\n' 'http://127.0.0.1:8088/../server.py' 'http://127.0.0.1:8088/..%2f..%2fetc/passwd'` |
| **Expected** | `404` for all; no file contents served |
| **Status** | ☐ Pass ☐ Fail |

### TC-SEC-002: XSS in image name is inert
| Objective | A repo/tag containing HTML must render as text |
|---|---|
| **Expected** | Rendered literally via `textContent`; CSP blocks inline script; no execution |
| **Status** | ☐ Pass ☐ Fail |

### TC-SEC-003: Security headers present
| Objective | Responses carry CSP + nosniff |
|---|---|
| **Test Command** | `curl -sI http://127.0.0.1:8088/ \| grep -iE 'content-security-policy|x-content-type-options'` |
| **Expected** | CSP `default-src 'none'…connect-src 'self'…` and `X-Content-Type-Options: nosniff` |
| **Status** | ☐ Pass ☐ Fail |

### TC-SEC-004: No Harbor credentials in web tier
| Objective | Web service cannot read imgctl.conf creds |
|---|---|
| **Expected** | `imgcatalog.service` runs unprivileged; `/api/raw` + snapshot contain no `HARBOR_PASSWORD`; journald has no creds |
| **Status** | ☐ Pass ☐ Fail |

---

## 5. Service / Lifecycle

### TC-SVC-001: Services active after install
| Test Command | `systemctl is-active imgcatalog.service; systemctl is-active imgcatalog-refresh.timer` |
|---|---|
| **Expected** | `active` / `active` |
| **Status** | ☐ Pass ☐ Fail |

### TC-SVC-002: Web service auto-restarts
| Objective | Kill the web process |
|---|---|
| **Test Command** | `systemctl kill imgcatalog.service; sleep 3; systemctl is-active imgcatalog.service` |
| **Expected** | `active` again (`Restart=always`) |
| **Status** | ☐ Pass ☐ Fail |

### TC-SVC-003: Timer fires & refreshes
| Test Command | `systemctl start imgcatalog-refresh.service; stat -c '%y' /var/lib/imgcatalog/all.json` |
|---|---|
| **Expected** | Snapshot mtime updates; producer logs success in journald |
| **Status** | ☐ Pass ☐ Fail |

### TC-SVC-004: Survives reboot
| Objective | Reboot the head node |
|---|---|
| **Expected** | Both units come back; `OnBootSec` repopulates the snapshot; portal reachable |
| **Status** | ☐ Pass ☐ Fail |

---

## 6. Exposure / Network

### TC-NET-001: Reachable off-host after openports
| Test Command | From another host: `curl -s http://<head-ip>:8088/healthz` |
|---|---|
| **Expected** | 200 ok (after the manual `cmsh openports` rule is committed) |
| **Status** | ☐ Pass ☐ Fail |

### TC-NET-002: Port closed before openports
| Objective | Before adding the rule, the port is not reachable externally |
|---|---|
| **Expected** | Connection refused/timeout from off-host; reachable only on the head itself |
| **Status** | ☐ Pass ☐ Fail |

---

## 7. Failure Modes

### TC-FAIL-001: Snapshot missing (first boot)
| Trigger | No `/var/lib/imgcatalog/all.json` yet |
| **Required** | `/api/images` returns `status:"warming"`, empty images, HTTP 200; UI shows "Warming up" (no crash) |
| **Status** | ☐ Pass ☐ Fail |

### TC-FAIL-002: Worker SSH down during refresh
| Trigger | Worker unreachable when the timer runs |
| **Required** | Node images empty for that run; producer keeps the **last-good** snapshot; UI marks stale; no 5xx |
| **Status** | ☐ Pass ☐ Fail |

### TC-FAIL-003: Harbor down/unauthorized during refresh
| Trigger | Harbor API failing |
| **Required** | Harbor images empty for that run; last-good kept; banner notes the empty source |
| **Status** | ☐ Pass ☐ Fail |

### TC-FAIL-004: imgctl returns invalid/partial JSON
| Trigger | Corrupt `imgctl` output |
| **Required** | `refresh.sh` validation rejects it and does **not** overwrite the good snapshot (exit non-zero, logged) |
| **Status** | ☐ Pass ☐ Fail |

### TC-FAIL-005: Corrupt snapshot file
| Trigger | Truncated/garbage `all.json` |
| **Required** | Server returns `status:"error"` + empty images (200), never a stack trace; atomic writes prevent mid-write reads |
| **Status** | ☐ Pass ☐ Fail |

### TC-FAIL-006: 200+ char image name
| Trigger | Very long tag/reference |
| **Required** | JSON stays valid; UI truncates display but Copy yields the full string; no layout break |
| **Status** | ☐ Pass ☐ Fail |

### TC-FAIL-007: Concurrent load
| Trigger | Many simultaneous requests |
| **Required** | Server stays responsive within `TasksMax`/connection cap; head services (CMDaemon/Harbor) unaffected |
| **Status** | ☐ Pass ☐ Fail |

---

## Test Summary Report

| Category | Total | Passed | Failed |
|----------|-------|--------|--------|
| API Contract | 5 | | |
| Reshaping & References | 5 | | |
| UI | 7 | | |
| Security | 4 | | |
| Service / Lifecycle | 4 | | |
| Exposure / Network | 2 | | |
| Failure Modes | 7 | | |
| **TOTAL** | **34** | | |

---

## Sign-Off

| Role | Name | Date |
|------|------|------|
| Tester | | |
| Reviewer | | |
