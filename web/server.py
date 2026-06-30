#!/usr/bin/env python3
# ============================================================================
# imgctl Web GUI - Cluster Image Portal (Python 3 stdlib only, zero deps)
# ============================================================================
# A tiny read-only HTTP server that turns the snapshot written by the imgctl
# refresh timer (`/var/lib/imgcatalog/all.json`) into:
#   - a JSON API (GET /api/images, /api/raw, /healthz, /version)
#   - a static, NVIDIA/Run:ai-themed web UI (GET / and its assets)
#
# Design notes (see docs/WEB_UI.md):
#   * The web process is UNPRIVILEGED and only READS the snapshot. It never
#     runs imgctl, SSHes, or reads Harbor credentials. The root refresh timer
#     produces the snapshot (and injects the Harbor registry host into it).
#   * Static assets are loaded into memory at startup behind a fixed route
#     allowlist -> there is no per-request filesystem path join, so directory
#     traversal is impossible by construction.
#   * Image/tag strings are attacker-influenceable, so they are only ever
#     emitted inside JSON (application/json) and rendered client-side via
#     textContent; a strict CSP makes any injected markup inert.
#
# Author: Anubhav Patrick <anubhav.patrick@giindia.com>
# Organization: Global Info Ventures Pvt Ltd
# ============================================================================
import calendar
import json
import os
import signal
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VERSION = "2.2.0"

# ---- Defaults (overridable via environment set in the systemd unit) --------
DEFAULT_PORT = 8088
DEFAULT_BIND = "0.0.0.0"            # public/remote access required (no LAN scoping)
DEFAULT_SNAPSHOT = "/var/lib/imgcatalog/all.json"
DEFAULT_STALE_AFTER = 900           # seconds; ~3 missed 5-min refresh cycles
DEFAULT_STATIC_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "static")
MAX_CONNECTIONS = 48                # in-process cap (paired with systemd TasksMax)
SOCKET_TIMEOUT = 10                 # seconds; mitigates slow-loris

# Fixed asset route allowlist: URL path -> canonical asset key.
# Fonts use the system stack (Inter if installed, else Helvetica/Arial) so we
# ship no binary blobs and stay fully offline-safe.
ASSET_ROUTES = {
    "/": "/index.html",
    "/index.html": "/index.html",
    "/app.js": "/app.js",
    "/style.css": "/style.css",
}
CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
}
CSP = ("default-src 'none'; script-src 'self'; style-src 'self'; "
       "img-src 'self' data:; font-src 'self'; connect-src 'self'; "
       "base-uri 'none'; form-action 'none'")

# Runtime config (populated by main(); kept module-level so the Handler sees it).
SNAPSHOT_PATH = DEFAULT_SNAPSHOT
STALE_AFTER = DEFAULT_STALE_AFTER
ENV_REGISTRY_HOST = ""
ASSETS = {}                         # route -> (bytes, content_type)


# ============================================================================
# Pure functions (unit-tested in tests/test_web_portal.py; socket-free)
# ============================================================================
def _epoch(iso):
    """Parse an 'YYYY-MM-DDTHH:MM:SSZ' (UTC) timestamp to epoch seconds.

    Raises ValueError on malformed input (callers handle it).
    """
    return calendar.timegm(time.strptime(iso, "%Y-%m-%dT%H:%M:%SZ"))


def is_stale(generated_at, now_epoch, stale_after):
    """True if the snapshot is missing/old/unparseable. Future ts (clock skew) is fresh."""
    if not generated_at:
        return True
    try:
        ts = _epoch(generated_at)
    except Exception:
        return True
    age = now_epoch - ts
    if age < 0:                      # snapshot slightly ahead of us -> treat as fresh
        return False
    return age > stale_after


def build_reference(source, repository, tag, registry_host):
    """Build the exact, copy-paste pull reference for an image.

    NGC/Docker (source='node') repos are already host-qualified -> returned as-is.
    Custom/Harbor (source='harbor') repos need the head-node registry host prepended,
    e.g. 'vips-headnode:9443/custom/<image>:<tag>'.
    """
    repository = (repository or "").strip()
    tag = (tag or "").strip()
    base = repository
    if source == "harbor" and registry_host:
        base = registry_host.rstrip("/") + "/" + repository
    if tag and tag != "<none>":
        return base + ":" + tag
    return base


def _row(source, repo, tag, id_, size, registry_host):
    """Normalise one image record; return None for rows without a repository."""
    repo = (repo or "").strip()
    if not repo:
        return None
    return {
        "source": source,
        "repository": repo,
        "tag": (tag or "").strip(),
        "size": (size or "").strip(),
        "id": (id_ or "").strip(),
        "reference": build_reference(source, repo, tag, registry_host),
    }


def reshape(raw, registry_host, now_epoch=None, stale_after=DEFAULT_STALE_AFTER):
    """Flatten an `imgctl get all -o json` blob into the portal's API shape.

    harbor_images[]            -> source='harbor' (registry on the head node), id=digest
    comparison.common[]        -> source='node'   (cached on the worker), id=image_id
    comparison.node_specific{} -> source='node'

    Every image is shown FAITHFULLY, exactly as it exists in each store. A custom image
    that lives in BOTH Harbor and the worker's local cache deliberately appears as two
    rows (one per source) -- the copies live in different storage, so they are not merged.
    Harbor rows are listed first. Malformed rows (no repository) are dropped, never crash.
    """
    if now_epoch is None:
        now_epoch = int(time.time())
    raw = raw if isinstance(raw, dict) else {}
    generated_at = raw.get("timestamp") or ""

    images = []
    for h in (raw.get("harbor_images") or []):
        if isinstance(h, dict):
            r = _row("harbor", h.get("repository"), h.get("tag"),
                     h.get("digest"), h.get("size"), registry_host)
            if r:
                images.append(r)
    harbor_count = len(images)

    comp = raw.get("comparison") or {}
    node_rows = []
    for n in (comp.get("common") or []):
        if isinstance(n, dict):
            r = _row("node", n.get("repository"), n.get("tag"),
                     n.get("image_id"), n.get("size"), registry_host)
            if r:
                node_rows.append(r)
    ns = comp.get("node_specific") or {}
    if isinstance(ns, dict):
        for _node, lst in ns.items():
            for n in (lst or []):
                if isinstance(n, dict):
                    r = _row("node", n.get("repository"), n.get("tag"),
                             n.get("image_id"), n.get("size"), registry_host)
                    if r:
                        node_rows.append(r)
    images.extend(node_rows)

    return {
        "generated_at": generated_at,
        "stale": is_stale(generated_at, now_epoch, stale_after),
        "sources": {"harbor": {"count": harbor_count},
                    "node": {"count": len(node_rows)}},
        "images": images,
    }


def resolve_asset_route(path):
    """Return the canonical asset key for a request path, or None if not allow-listed.

    Pure allowlist lookup -> traversal/encoded/unknown paths simply miss the map.
    """
    return ASSET_ROUTES.get(path)


# ============================================================================
# I/O helpers (not socket-bound)
# ============================================================================
def load_assets(static_dir):
    """Read each allow-listed asset into memory once at startup.

    Verifies every resolved path stays inside static_dir (defense in depth).
    """
    assets = {}
    base = os.path.realpath(static_dir)
    for route in set(ASSET_ROUTES.values()):
        full = os.path.realpath(os.path.join(base, route.lstrip("/")))
        if full != base and not full.startswith(base + os.sep):
            raise RuntimeError("asset path escapes static dir: %s" % route)
        with open(full, "rb") as fh:
            data = fh.read()
        ext = os.path.splitext(full)[1].lower()
        assets[route] = (data, CONTENT_TYPES.get(ext, "application/octet-stream"))
    return assets


def read_snapshot(path):
    """Return parsed snapshot dict, None if missing (warming up), or False if unreadable/corrupt."""
    try:
        with open(path, "rb") as fh:
            return json.loads(fh.read().decode("utf-8"))
    except FileNotFoundError:
        return None
    except Exception:
        return False


def registry_host_from(raw):
    """Prefer the host the root producer injected into the snapshot; fall back to env."""
    if isinstance(raw, dict) and raw.get("harbor_host"):
        return str(raw["harbor_host"])
    return ENV_REGISTRY_HOST


# ============================================================================
# HTTP layer
# ============================================================================
class Handler(BaseHTTPRequestHandler):
    server_version = "imgcatalog/" + VERSION
    sys_version = ""                 # don't leak Python version
    timeout = SOCKET_TIMEOUT

    # ---- response helpers ----
    def _send(self, status, body, content_type, include_body=True):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Security-Policy", CSP)
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("Connection", "close")
        self.end_headers()
        if include_body:
            self.wfile.write(body)

    def _json(self, status, obj, include_body=True):
        self._send(status, json.dumps(obj).encode("utf-8"),
                   "application/json; charset=utf-8", include_body)

    def _text(self, status, text, include_body=True):
        self._send(status, text.encode("utf-8"), "text/plain; charset=utf-8", include_body)

    # ---- routing ----
    def _route(self, include_body=True):
        try:
            path = self.path.split("?", 1)[0]
            if path == "/healthz":
                return self._json(200, {"status": "ok", "version": VERSION}, include_body)
            if path == "/version":
                return self._text(200, VERSION + "\n", include_body)
            if path == "/api/images":
                return self._api_images(include_body)
            if path == "/api/raw":
                return self._api_raw(include_body)
            route = resolve_asset_route(path)
            if route is not None and route in ASSETS:
                data, ctype = ASSETS[route]
                return self._send(200, data, ctype, include_body)
            return self._json(404, {"error": "not found"}, include_body)
        except Exception:
            # Never leak a stack trace to clients.
            try:
                self._json(500, {"error": "internal error"}, include_body)
            except Exception:
                pass

    def do_GET(self):
        self._route(include_body=True)

    def do_HEAD(self):
        self._route(include_body=False)

    def _method_not_allowed(self):
        self.send_response(405)
        self.send_header("Allow", "GET, HEAD")
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()

    do_POST = do_PUT = do_DELETE = do_PATCH = do_OPTIONS = _method_not_allowed

    # ---- API ----
    def _api_images(self, include_body=True):
        raw = read_snapshot(SNAPSHOT_PATH)
        if raw is None:
            return self._json(200, {"status": "warming", "generated_at": "", "stale": True,
                                    "sources": {"harbor": {"count": 0}, "node": {"count": 0}},
                                    "images": []}, include_body)
        if raw is False:
            return self._json(200, {"status": "error", "generated_at": "", "stale": True,
                                    "sources": {"harbor": {"count": 0}, "node": {"count": 0}},
                                    "images": []}, include_body)
        out = reshape(raw, registry_host_from(raw),
                      now_epoch=int(time.time()), stale_after=STALE_AFTER)
        out["status"] = "ok"
        # Config-driven, cluster-specific display text injected by the producer
        # (nothing institute/hardware-specific is hardcoded in the app).
        out["cluster_name"] = str(raw.get("cluster_name", ""))
        out["site_title"] = str(raw.get("site_title", ""))
        out["site_subtitle"] = str(raw.get("site_subtitle", ""))
        out["label_harbor"] = str(raw.get("label_harbor", ""))
        out["label_node"] = str(raw.get("label_node", ""))
        return self._json(200, out, include_body)

    def _api_raw(self, include_body=True):
        raw = read_snapshot(SNAPSHOT_PATH)
        if not isinstance(raw, dict):
            return self._json(200, {"status": "warming" if raw is None else "error"}, include_body)
        return self._json(200, raw, include_body)

    # ---- quiet, sanitised logging (journald) ----
    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(),
                                        (fmt % args).replace("\n", " ").replace("\r", " ")))


class GatedThreadingServer(ThreadingHTTPServer):
    """ThreadingHTTPServer with a hard cap on concurrent worker threads."""
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._sem = threading.BoundedSemaphore(MAX_CONNECTIONS)

    def process_request_thread(self, request, client_address):
        if not self._sem.acquire(blocking=False):
            try:
                request.close()
            finally:
                return
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._sem.release()


def main():
    global SNAPSHOT_PATH, STALE_AFTER, ENV_REGISTRY_HOST, ASSETS
    port = int(os.environ.get("WEB_PORT", DEFAULT_PORT))
    bind = os.environ.get("WEB_BIND_ADDRESS", DEFAULT_BIND)
    SNAPSHOT_PATH = os.environ.get("WEB_SNAPSHOT_PATH", DEFAULT_SNAPSHOT)
    STALE_AFTER = int(os.environ.get("WEB_STALE_AFTER", DEFAULT_STALE_AFTER))
    ENV_REGISTRY_HOST = os.environ.get("WEB_HARBOR_REGISTRY_HOST", "").strip()
    static_dir = os.environ.get("WEB_STATIC_DIR", DEFAULT_STATIC_DIR)

    ASSETS = load_assets(static_dir)

    httpd = GatedThreadingServer((bind, port), Handler)

    def _shutdown(_signo, _frame):
        threading.Thread(target=httpd.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _shutdown)
    signal.signal(signal.SIGINT, _shutdown)

    sys.stderr.write("imgcatalog %s serving on %s:%d (snapshot=%s)\n"
                     % (VERSION, bind, port, SNAPSHOT_PATH))
    try:
        httpd.serve_forever(poll_interval=0.5)
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
