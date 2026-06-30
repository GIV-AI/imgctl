#!/usr/bin/env python3
# ============================================================================
# imgctl Web GUI - Unit tests for the pure logic of web/server.py
# ============================================================================
# These tests exercise the pure (socket-free) functions of the Cluster Image
# Portal server: snapshot reshaping, pull-reference construction, staleness
# math, and static-asset route resolution. They never bind a port.
#
# Run:  python -m unittest discover -s tests -p 'test_*.py'
#   or: python tests/test_web_portal.py
#
# Author: Anubhav Patrick <anubhav.patrick@giindia.com>
# Organization: Global Info Ventures Pvt Ltd
# ============================================================================
import os
import sys
import unittest

# Make web/server.py importable without binding a socket (it guards main()).
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "web"))
import server  # noqa: E402

HOST = "vips-headnode:9443"

# A representative imgctl `get all -o json` blob for a SINGLE-worker cluster:
# every node image lands in comparison.common[]; node_specific is empty.
SAMPLE = {
    "timestamp": "2026-06-30T10:36:51Z",
    "harbor_images": [
        {"repository": "custom/srm-fdp-distributed-training", "tag": "1.2",
         "digest": "sha256:047399e5", "size": "13.2GB", "project": "custom"},
        {"repository": "custom/swas-image", "tag": "v1",
         "digest": "sha256:f97b8138", "size": "28MB", "project": "custom"},
    ],
    "comparison": {
        "common": [
            {"repository": "nvcr.io/nvidia/pytorch", "tag": "25.06-py3",
             "image_id": "06aa7e7a6f5a5", "size": "13.7GB"},
            {"repository": "docker.io/library/ubuntu", "tag": "22.04",
             "image_id": "86f1a8d7b38e7", "size": "29.7MB"},
        ],
        "node_specific": {},
    },
}


class BuildReferenceTests(unittest.TestCase):
    def test_node_reference_is_unprefixed(self):
        # NGC/Docker images are already fully host-qualified.
        ref = server.build_reference("node", "nvcr.io/nvidia/pytorch", "25.06-py3", HOST)
        self.assertEqual(ref, "nvcr.io/nvidia/pytorch:25.06-py3")

    def test_harbor_reference_gets_host_prefix(self):
        # Custom/Harbor images need the head-node host prepended.
        ref = server.build_reference("harbor", "custom/swas-image", "v1", HOST)
        self.assertEqual(ref, "vips-headnode:9443/custom/swas-image:v1")

    def test_harbor_host_trailing_slash_normalised(self):
        ref = server.build_reference("harbor", "custom/x", "t", "vips-headnode:9443/")
        self.assertEqual(ref, "vips-headnode:9443/custom/x:t")


class ReshapeTests(unittest.TestCase):
    def setUp(self):
        # Fixed "now" 60s after the snapshot so it is fresh.
        self.now = server._epoch("2026-06-30T10:37:51Z")
        self.out = server.reshape(SAMPLE, HOST, now_epoch=self.now, stale_after=900)

    def test_passthrough_generated_at(self):
        self.assertEqual(self.out["generated_at"], "2026-06-30T10:36:51Z")

    def test_flatten_count_matches_sources(self):
        # 2 harbor + 2 common + 0 node_specific
        self.assertEqual(len(self.out["images"]), 4)

    def test_source_counts(self):
        self.assertEqual(self.out["sources"]["harbor"]["count"], 2)
        self.assertEqual(self.out["sources"]["node"]["count"], 2)

    def test_harbor_rows_prefixed_and_labelled(self):
        harbor = [i for i in self.out["images"] if i["source"] == "harbor"]
        self.assertEqual(len(harbor), 2)
        srm = next(i for i in harbor if i["repository"].endswith("srm-fdp-distributed-training"))
        self.assertEqual(srm["reference"],
                         "vips-headnode:9443/custom/srm-fdp-distributed-training:1.2")
        self.assertEqual(srm["id"], "sha256:047399e5")  # harbor uses digest

    def test_node_rows_unprefixed_and_labelled(self):
        node = [i for i in self.out["images"] if i["source"] == "node"]
        self.assertEqual(len(node), 2)
        pt = next(i for i in node if "pytorch" in i["repository"])
        self.assertEqual(pt["reference"], "nvcr.io/nvidia/pytorch:25.06-py3")
        self.assertEqual(pt["id"], "06aa7e7a6f5a5")  # node uses image_id

    def test_harbor_listed_before_node(self):
        sources_in_order = [i["source"] for i in self.out["images"]]
        self.assertEqual(sources_in_order, ["harbor", "harbor", "node", "node"])

    def test_node_specific_images_included_as_node(self):
        # Multi-node future: node_specific entries must also appear as source=node.
        raw = {
            "timestamp": "2026-06-30T10:36:51Z",
            "harbor_images": [],
            "comparison": {
                "common": [],
                "node_specific": {
                    "w1": [{"repository": "docker.io/library/nginx", "tag": "latest",
                            "image_id": "abc", "size": "60MB"}],
                },
            },
        }
        out = server.reshape(raw, HOST, now_epoch=self.now, stale_after=900)
        self.assertEqual(len(out["images"]), 1)
        self.assertEqual(out["images"][0]["source"], "node")
        self.assertEqual(out["images"][0]["reference"], "docker.io/library/nginx:latest")

    def test_long_tag_preserved_verbatim(self):
        long_tag = "5" + "a" * 250
        raw = {
            "timestamp": "2026-06-30T10:36:51Z",
            "harbor_images": [{"repository": "custom/kaniko-test-ngc/cache",
                               "tag": long_tag, "digest": "sha256:56d0aa72", "size": "63MB"}],
            "comparison": {"common": [], "node_specific": {}},
        }
        out = server.reshape(raw, HOST, now_epoch=self.now, stale_after=900)
        self.assertEqual(out["images"][0]["tag"], long_tag)
        self.assertTrue(out["images"][0]["reference"].endswith(":" + long_tag))

    def test_missing_sections_tolerated(self):
        out = server.reshape({}, HOST, now_epoch=self.now, stale_after=900)
        self.assertEqual(out["images"], [])
        self.assertEqual(out["sources"]["harbor"]["count"], 0)
        self.assertEqual(out["sources"]["node"]["count"], 0)
        self.assertEqual(out["generated_at"], "")

    def test_rows_without_repository_are_dropped(self):
        raw = {
            "timestamp": "2026-06-30T10:36:51Z",
            "harbor_images": [{"tag": "v1", "digest": "d", "size": "1MB"}],  # no repository
            "comparison": {"common": [{"repository": "", "tag": "x", "image_id": "i"}],
                           "node_specific": {}},
        }
        out = server.reshape(raw, HOST, now_epoch=self.now, stale_after=900)
        self.assertEqual(out["images"], [])

    def test_stale_true_when_snapshot_old(self):
        old_now = server._epoch("2026-06-30T11:00:00Z")  # ~23 min later
        out = server.reshape(SAMPLE, HOST, now_epoch=old_now, stale_after=900)
        self.assertTrue(out["stale"])

    def test_stale_false_when_fresh(self):
        self.assertFalse(self.out["stale"])


class FaithfulDisplayTests(unittest.TestCase):
    """Harbor (registry on the head) and the worker's local cache are DIFFERENT storage,
    so an image present in both is shown as two rows -- never merged. NGC images cached
    under two names are likewise both shown. Nothing that exists is hidden."""
    def setUp(self):
        self.now = server._epoch("2026-06-30T10:37:51Z")

    def test_cross_source_identical_reference_shows_both(self):
        raw = {
            "timestamp": "2026-06-30T10:36:51Z",
            "harbor_images": [{"repository": "custom/app", "tag": "1.0",
                               "digest": "sha256:aa", "size": "1GB"}],
            "comparison": {"common": [
                {"repository": "vips-headnode:9443/custom/app", "tag": "1.0",
                 "image_id": "abc123", "size": "1GB"}], "node_specific": {}},
        }
        out = server.reshape(raw, HOST, now_epoch=self.now)
        self.assertEqual(len(out["images"]), 2)
        self.assertEqual(sorted(i["source"] for i in out["images"]), ["harbor", "node"])
        # Same pull reference is fine -- the differing source/storage is the whole point.
        self.assertEqual({i["reference"] for i in out["images"]},
                         {"vips-headnode:9443/custom/app:1.0"})
        self.assertEqual(out["sources"]["harbor"]["count"], 1)
        self.assertEqual(out["sources"]["node"]["count"], 1)

    def test_node_proxy_and_upstream_both_shown(self):
        raw = {
            "timestamp": "2026-06-30T10:36:51Z", "harbor_images": [],
            "comparison": {"common": [
                {"repository": "nvcr.io/nvidia/pytorch", "tag": "26.03-py3",
                 "image_id": "fba", "size": "9GB"},
                {"repository": "vips-headnode:9443/nvcr.io/nvidia/pytorch", "tag": "26.03-py3",
                 "image_id": "fba", "size": "9GB"}], "node_specific": {}},
        }
        out = server.reshape(raw, HOST, now_epoch=self.now)
        self.assertEqual(len(out["images"]), 2)
        self.assertEqual(out["sources"]["node"]["count"], 2)

    def test_distinct_images_all_present(self):
        out = server.reshape(SAMPLE, HOST, now_epoch=self.now)
        self.assertEqual(len(out["images"]), 4)


class StaleTests(unittest.TestCase):
    def test_fresh_is_not_stale(self):
        now = server._epoch("2026-06-30T10:40:00Z")
        self.assertFalse(server.is_stale("2026-06-30T10:39:00Z", now, 900))

    def test_old_is_stale(self):
        now = server._epoch("2026-06-30T11:00:00Z")
        self.assertTrue(server.is_stale("2026-06-30T10:39:00Z", now, 900))

    def test_unparseable_timestamp_is_stale(self):
        self.assertTrue(server.is_stale("not-a-date", 1_000_000, 900))

    def test_empty_timestamp_is_stale(self):
        self.assertTrue(server.is_stale("", 1_000_000, 900))

    def test_future_timestamp_is_not_stale(self):
        # Clock skew: snapshot timestamp slightly ahead of now must not flag stale.
        now = server._epoch("2026-06-30T10:39:00Z")
        self.assertFalse(server.is_stale("2026-06-30T10:40:00Z", now, 900))


class AssetRouteTests(unittest.TestCase):
    def test_root_maps_to_index(self):
        self.assertEqual(server.resolve_asset_route("/"), "/index.html")

    def test_known_assets_resolve_to_themselves(self):
        for p in ("/index.html", "/app.js", "/style.css"):
            self.assertEqual(server.resolve_asset_route(p), p)

    def test_traversal_attempts_rejected(self):
        for p in ("/../etc/passwd", "/..%2f..%2fetc/passwd", "/fonts/../../server.py",
                  "/app.js/../style.css", "//etc/passwd", "/.", "/static/secret"):
            self.assertIsNone(server.resolve_asset_route(p), p)

    def test_unknown_paths_rejected(self):
        for p in ("/admin", "/index.php", "/favicon.ico", "/app.js.bak"):
            self.assertIsNone(server.resolve_asset_route(p), p)


if __name__ == "__main__":
    unittest.main(verbosity=2)
