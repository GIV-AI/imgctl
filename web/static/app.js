/* ==========================================================================
   imgctl Web GUI - Cluster Image Portal (vanilla JS, no dependencies)
   Renders the JSON from /api/images. All image/tag/reference strings are
   attacker-influenceable, so they are ONLY ever inserted via textContent.
   ========================================================================== */
(function () {
  "use strict";

  var $ = function (id) { return document.getElementById(id); };
  var els = {
    title: $("site-title"), subtitle: $("subtitle"), freshness: $("freshness"), refresh: $("refreshBtn"),
    cTotal: $("count-total"), cHarbor: $("count-harbor"), cNode: $("count-node"), cSize: $("count-size"),
    banner: $("banner"), search: $("search"), searchClear: $("searchClear"),
    sort: $("sort"), resultCount: $("result-count"),
    loading: $("loading"), tablewrap: $("tablewrap"), body: $("img-body"),
    empty: $("empty"), error: $("error"), footUrl: $("foot-url"),
    toast: $("toast"), srLive: $("sr-live"),
    popover: $("copyPopover"), popoverInput: $("copyPopoverInput"), popoverClose: $("copyPopoverClose")
  };

  var state = { all: [], meta: null, q: "", src: "all", sort: "default", lastError: false,
                labels: { harbor: "Harbor", node: "Node" } };

  function setText(id, text) { var e = $(id); if (e) e.textContent = text; }

  // ---- helpers ------------------------------------------------------------
  var UNIT = { B: 1, KB: 1e3, MB: 1e6, GB: 1e9, TB: 1e12 };
  function toBytes(s) {
    var m = /([\d.]+)\s*([KMGT]?)B/i.exec(s || "");
    if (!m) return 0;
    return parseFloat(m[1]) * (UNIT[(m[2] || "").toUpperCase() + "B"] || 1);
  }
  function relTime(iso) {
    if (!iso) return "unknown";
    var t = Date.parse(iso);
    if (isNaN(t)) return "unknown";
    var sec = Math.round((Date.now() - t) / 1000);
    if (sec < 0) return "just now";
    if (sec < 60) return sec + "s ago";
    var m = Math.round(sec / 60); if (m < 60) return m + " min ago";
    var h = Math.round(m / 60); if (h < 24) return h + "h ago";
    return Math.round(h / 24) + "d ago";
  }
  function fmtSize(bytes) {
    if (!bytes) return "—";
    var u = ["B", "KB", "MB", "GB", "TB"], i = 0, n = bytes;
    while (n >= 1000 && i < u.length - 1) { n /= 1000; i++; }
    return (n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)) + " " + u[i];
  }
  function midTruncate(s, head, tail) {
    if (!s || s.length <= head + tail + 1) return s;
    return s.slice(0, head) + "…" + s.slice(s.length - tail);
  }
  function debounce(fn, ms) {
    var t; return function () { var a = arguments, c = this; clearTimeout(t); t = setTimeout(function () { fn.apply(c, a); }, ms); };
  }
  // Append text to `el`, wrapping case-insensitive matches of any term in <mark>. Safe (no innerHTML).
  function appendHighlighted(el, text, terms) {
    text = text || "";
    if (!terms.length) { el.appendChild(document.createTextNode(text)); return; }
    var lower = text.toLowerCase(), i = 0;
    while (i < text.length) {
      var best = -1, bestLen = 0;
      for (var t = 0; t < terms.length; t++) {
        var idx = lower.indexOf(terms[t], i);
        if (idx !== -1 && (best === -1 || idx < best)) { best = idx; bestLen = terms[t].length; }
      }
      if (best === -1) { el.appendChild(document.createTextNode(text.slice(i))); break; }
      if (best > i) el.appendChild(document.createTextNode(text.slice(i, best)));
      var mk = document.createElement("mark");
      mk.textContent = text.slice(best, best + bestLen);
      el.appendChild(mk);
      i = best + bestLen;
    }
  }

  // ---- URL state ----------------------------------------------------------
  function readUrl() {
    var p = new URLSearchParams(location.search);
    state.q = p.get("q") || "";
    state.src = ["all", "harbor", "node"].indexOf(p.get("src")) >= 0 ? p.get("src") : "all";
    state.sort = p.get("sort") || "default";
  }
  function writeUrl() {
    var p = new URLSearchParams();
    if (state.q) p.set("q", state.q);
    if (state.src !== "all") p.set("src", state.src);
    if (state.sort !== "default") p.set("sort", state.sort);
    var qs = p.toString();
    history.replaceState(null, "", qs ? "?" + qs : location.pathname);
  }

  // ---- filtering & sorting ------------------------------------------------
  function terms() {
    return state.q.toLowerCase().split(/\s+/).filter(Boolean);
  }
  function matches(img, ts) {
    if (state.src !== "all" && img.source !== state.src) return false;
    if (!ts.length) return true;
    var hay = (img.repository + " " + img.tag + " " + img.reference + " " +
      (img.source === "harbor" ? "harbor custom" : "dgx cached node") + " " + img.id).toLowerCase();
    for (var i = 0; i < ts.length; i++) if (hay.indexOf(ts[i]) === -1) return false;
    return true;
  }
  function sorted(list) {
    var s = state.sort, a = list.slice();
    var byName = function (x, y) { return x.repository.localeCompare(y.repository) || x.tag.localeCompare(y.tag); };
    if (s === "name-asc") a.sort(byName);
    else if (s === "name-desc") a.sort(function (x, y) { return -byName(x, y); });
    else if (s === "size-desc") a.sort(function (x, y) { return toBytes(y.size) - toBytes(x.size) || byName(x, y); });
    else if (s === "size-asc") a.sort(function (x, y) { return toBytes(x.size) - toBytes(y.size) || byName(x, y); });
    else if (s === "source") a.sort(function (x, y) { return x.source.localeCompare(y.source) || byName(x, y); });
    else a.sort(function (x, y) { // default: harbor first, then name
      if (x.source !== y.source) return x.source === "harbor" ? -1 : 1;
      return byName(x, y);
    });
    return a;
  }

  // ---- rendering ----------------------------------------------------------
  function rowEl(img, ts) {
    var tr = document.createElement("tr");

    var src = document.createElement("td");
    var badge = document.createElement("span");
    badge.className = "badge " + (img.source === "harbor" ? "badge-harbor" : "badge-node");
    badge.textContent = img.source === "harbor" ? state.labels.harbor : state.labels.node;
    src.setAttribute("data-label", "Source"); src.appendChild(badge);

    var image = document.createElement("td");
    image.className = "cell-image"; image.setAttribute("data-label", "Image");
    var repo = document.createElement("div"); repo.className = "repo";
    appendHighlighted(repo, img.repository, ts);
    if (img.tag) {
      var chip = document.createElement("span"); chip.className = "tag-chip";
      chip.textContent = ":" + midTruncate(img.tag, 8, 6);
      if (img.tag.length > 14) chip.title = img.tag;
      repo.appendChild(chip);
    }
    var ref = document.createElement("div"); ref.className = "ref"; ref.title = img.reference;
    appendHighlighted(ref, img.reference, ts);
    image.appendChild(repo); image.appendChild(ref);

    var size = document.createElement("td");
    size.className = "cell-size"; size.setAttribute("data-label", "Size");
    size.textContent = img.size || "—";

    var copy = document.createElement("td");
    copy.className = "cell-copy"; copy.setAttribute("data-label", "");
    var btn = document.createElement("button");
    btn.className = "copy-btn"; btn.type = "button";
    btn.setAttribute("data-ref", img.reference);
    btn.setAttribute("aria-label", "Copy reference " + img.reference);
    var ico = document.createElement("span"); ico.className = "copy-ico"; ico.setAttribute("aria-hidden", "true"); ico.textContent = "⧉";
    var lbl = document.createElement("span"); lbl.className = "copy-lbl"; lbl.textContent = "Copy";
    btn.appendChild(ico); btn.appendChild(lbl);
    copy.appendChild(btn);

    tr.appendChild(src); tr.appendChild(image); tr.appendChild(size); tr.appendChild(copy);
    return tr;
  }

  function render() {
    var ts = terms();
    var list = sorted(state.all.filter(function (i) { return matches(i, ts); }));

    els.resultCount.textContent = "Showing " + list.length + " of " + state.all.length;

    // segmented + summary active sync
    Array.prototype.forEach.call(document.querySelectorAll(".seg-btn"), function (b) {
      var on = b.getAttribute("data-src") === state.src;
      b.classList.toggle("is-active", on); b.setAttribute("aria-checked", on ? "true" : "false");
    });
    els.sort.value = state.sort;
    els.search.value = state.q;
    els.searchClear.hidden = !state.q;

    if (state.lastError) { showError(); return; }

    els.body.textContent = "";
    if (!state.all.length) { showEmptyAll(); return; }
    if (!list.length) { showEmptyFiltered(); return; }

    els.empty.hidden = true; els.error.hidden = true; els.tablewrap.hidden = false;
    var frag = document.createDocumentFragment();
    for (var i = 0; i < list.length; i++) frag.appendChild(rowEl(list[i], ts));
    els.body.appendChild(frag);
  }

  function showEmptyAll() {
    els.tablewrap.hidden = true; els.error.hidden = true;
    els.empty.hidden = false; els.empty.textContent = "";
    panel(els.empty, "\u{1F50D}", "No images in the snapshot yet",
      "The catalog is empty or still warming up. It refreshes automatically.");
  }
  function showEmptyFiltered() {
    els.tablewrap.hidden = true; els.error.hidden = true;
    els.empty.hidden = false; els.empty.textContent = "";
    panel(els.empty, "\u{1F50D}", "No matching images",
      "Nothing matches your search/filter.", "Clear filters", function () {
        state.q = ""; state.src = "all"; writeUrl(); render();
      });
  }
  function showError() {
    els.tablewrap.hidden = true; els.empty.hidden = true;
    els.error.hidden = false; els.error.textContent = "";
    panel(els.error, "⚠", "Couldn't load images",
      "The portal couldn't reach /api/images. " +
      (state.all.length ? "Showing the last data loaded." : ""), "Retry", load);
    if (state.all.length) { // stale-while-error: keep showing last good data below
      els.error.hidden = false; els.tablewrap.hidden = false;
      els.body.textContent = "";
      var ts = terms(), list = sorted(state.all.filter(function (i) { return matches(i, ts); }));
      var frag = document.createDocumentFragment();
      for (var i = 0; i < list.length; i++) frag.appendChild(rowEl(list[i], ts));
      els.body.appendChild(frag);
    }
  }
  function panel(el, ico, title, msg, btnLabel, btnFn) {
    var i = document.createElement("span"); i.className = "state-ico"; i.setAttribute("aria-hidden", "true"); i.textContent = ico;
    var h = document.createElement("p"); h.className = "state-title"; h.textContent = title;
    var p = document.createElement("p"); p.textContent = msg;
    el.appendChild(i); el.appendChild(h); el.appendChild(p);
    if (btnLabel) {
      var b = document.createElement("button"); b.className = "btn"; b.type = "button"; b.textContent = btnLabel;
      b.addEventListener("click", btnFn); el.appendChild(b);
    }
  }

  // ---- header / banner ----------------------------------------------------
  function updateMeta() {
    var m = state.meta || {};
    var h = (m.sources && m.sources.harbor && m.sources.harbor.count) || 0;
    var n = (m.sources && m.sources.node && m.sources.node.count) || 0;
    els.cTotal.textContent = h + n; els.cHarbor.textContent = h; els.cNode.textContent = n;
    var totalBytes = 0; for (var i = 0; i < state.all.length; i++) totalBytes += toBytes(state.all[i].size);
    els.cSize.textContent = fmtSize(totalBytes);

    // Config-driven display text (nothing institute/hardware-specific is hardcoded).
    if (m.site_title) els.title.textContent = m.site_title;
    var sub = m.site_subtitle || m.cluster_name || "";
    if (sub) els.subtitle.textContent = sub;
    state.labels.harbor = m.label_harbor || "Harbor";
    state.labels.node = m.label_node || "Node";
    setText("seg-harbor", state.labels.harbor);
    setText("seg-node", state.labels.node);
    setText("legend-harbor", state.labels.harbor); setText("legend-node", state.labels.node);
    setText("legend-harbor-2", state.labels.harbor); setText("legend-node-2", state.labels.node);

    var age = relTime(m.generated_at);
    var stale = !!m.stale || m.status === "warming" || m.status === "error" || state.lastError;
    var pt = els.freshness.querySelector(".pill-text");
    if (pt) pt.textContent = state.lastError ? "Offline"
        : (m.status === "warming" ? "Warming up…" : "Updated " + age);
    els.freshness.title = m.generated_at || "";
    els.freshness.classList.toggle("is-stale", stale);

    els.banner.hidden = true; els.banner.classList.remove("is-info");
    if (state.lastError) { /* error panel covers it */ }
    else if (m.status === "warming") {
      els.banner.hidden = false; els.banner.classList.add("is-info");
      setBanner("Warming up — the first catalog refresh hasn't completed yet. This page will populate shortly.");
    } else if (m.stale) {
      els.banner.hidden = false;
      setBanner("Snapshot is " + age + " — automatic refresh may be failing. Showing the last known data.");
    } else {
      var down = [];
      if (h === 0) down.push(state.labels.harbor + " registry");
      if (n === 0) down.push(state.labels.node + " cache");
      if (down.length) {
        els.banner.hidden = false; els.banner.classList.add("is-info");
        setBanner("No images from the " + down.join(" or ") + " in the current snapshot.");
      }
    }
  }
  function setBanner(text) {
    els.banner.textContent = ""; els.banner.appendChild(document.createTextNode(text));
  }

  // ---- copy ---------------------------------------------------------------
  function copyText(text) {
    if (window.isSecureContext && navigator.clipboard && navigator.clipboard.writeText) {
      return navigator.clipboard.writeText(text);
    }
    return new Promise(function (resolve, reject) {
      var ta = document.createElement("textarea");
      ta.value = text; ta.setAttribute("readonly", "");
      ta.style.cssText = "position:fixed;top:-1000px;left:0;opacity:0";
      document.body.appendChild(ta); ta.select();
      try { ta.setSelectionRange(0, text.length); } catch (e) {}
      var ok = false; try { ok = document.execCommand("copy"); } catch (e) {}
      document.body.removeChild(ta);
      ok ? resolve() : reject();
    });
  }
  function onCopyClick(btn) {
    var ref = btn.getAttribute("data-ref");
    copyText(ref).then(function () {
      var lbl = btn.querySelector(".copy-lbl");
      btn.classList.add("is-copied"); if (lbl) lbl.textContent = "Copied ✓";
      setTimeout(function () { btn.classList.remove("is-copied"); if (lbl) lbl.textContent = "Copy"; }, 1500);
      toast("Copied reference"); announce("Copied " + ref);
    }).catch(function () { showCopyPopover(ref); });
  }
  function showCopyPopover(ref) {
    els.popoverInput.value = ref; els.popover.hidden = false;
    els.popoverInput.focus(); els.popoverInput.select();
  }
  var toastTimer;
  function toast(msg) {
    els.toast.textContent = msg; els.toast.hidden = false;
    clearTimeout(toastTimer); toastTimer = setTimeout(function () { els.toast.hidden = true; }, 2000);
  }
  function announce(msg) { els.srLive.textContent = msg; }

  // ---- data ---------------------------------------------------------------
  function load() {
    fetch("api/images", { headers: { "Accept": "application/json" }, cache: "no-store" })
      .then(function (r) { if (!r.ok) throw new Error("http " + r.status); return r.json(); })
      .then(function (data) {
        if (!data || !Array.isArray(data.images)) throw new Error("bad shape");
        state.all = data.images.filter(function (i) { return i && i.reference; });
        state.meta = data; state.lastError = false;
        els.loading.hidden = true;
        updateMeta(); render();
      })
      .catch(function () {
        state.lastError = true; els.loading.hidden = true;
        updateMeta(); render();
      });
  }

  // ---- events -------------------------------------------------------------
  function wire() {
    els.footUrl.textContent = location.host;

    els.search.addEventListener("input", debounce(function () {
      state.q = els.search.value; writeUrl(); render();
    }, 150));
    els.searchClear.addEventListener("click", function () {
      state.q = ""; els.search.value = ""; writeUrl(); render(); els.search.focus();
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "/" && document.activeElement !== els.search) { e.preventDefault(); els.search.focus(); }
      if (e.key === "Escape" && !els.popover.hidden) closePopover();
    });

    Array.prototype.forEach.call(document.querySelectorAll(".seg-btn"), function (b) {
      b.addEventListener("click", function () { state.src = b.getAttribute("data-src"); writeUrl(); render(); });
    });
    els.sort.addEventListener("change", function () { state.sort = els.sort.value; writeUrl(); render(); });
    Array.prototype.forEach.call(document.querySelectorAll(".th-sort"), function (th) {
      th.addEventListener("click", function () {
        var key = th.getAttribute("data-sort");
        if (key === "name") state.sort = state.sort === "name-asc" ? "name-desc" : "name-asc";
        else if (key === "size") state.sort = state.sort === "size-desc" ? "size-asc" : "size-desc";
        else state.sort = "source";
        syncSortHeaders(); writeUrl(); render();
      });
    });
    els.refresh.addEventListener("click", function () { els.loading.hidden = false; els.tablewrap.hidden = true; load(); });
    els.body.addEventListener("click", function (e) {
      var btn = e.target.closest && e.target.closest(".copy-btn");
      if (btn) onCopyClick(btn);
    });
    els.popoverClose.addEventListener("click", closePopover);
  }
  function syncSortHeaders() {
    var map = { "name-asc": ["name", "ascending"], "name-desc": ["name", "descending"],
      "size-asc": ["size", "ascending"], "size-desc": ["size", "descending"], "source": ["source", "ascending"] };
    Array.prototype.forEach.call(document.querySelectorAll(".th-sort"), function (th) { th.removeAttribute("aria-sort"); });
    var cur = map[state.sort];
    if (cur) { var th = document.querySelector('.th-sort[data-sort="' + cur[0] + '"]'); if (th) th.setAttribute("aria-sort", cur[1]); }
  }
  function closePopover() { els.popover.hidden = true; }

  // ---- boot ---------------------------------------------------------------
  readUrl(); wire(); syncSortHeaders(); load();
  setInterval(function () { if (state.meta) { updateMeta(); } }, 30000); // refresh "N min ago"
  setInterval(load, 300000); // auto-reload every 5 min, aligned to snapshot cadence
})();
