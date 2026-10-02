.pragma library

// Code that runs INSIDE the YouTube Music app page (pear-desktop), sent with
// Runtime.evaluate over the DevTools protocol on the app's private pipe
// (tools/cdp-bridge; no debug port is ever opened).
//
// Why this exists: the app's own control server (127.0.0.1:26538) covers
// playback, likes, shuffle, repeat and volume, but has no way to list your
// library or start a playlist, and its queue routes only take positions. The
// page itself can do all of it: it is signed in, and
// `ytmusic-app.networkManager.fetch` is the same call the app's own search
// endpoint uses (see peard:search in the app's renderer bundle).
//
// Everything here returns small plain objects, so the bar never has to parse
// YouTube's huge raw responses. No backticks in SOURCE: it is a template string.
//
// The page keeps window.__nicYtm between calls. The widget sends the length
// of SOURCE with every call (window.__nicYtmLen, see page() in Widget.qml),
// and the copy living in the app is replaced when that length changes, so an
// edit here takes effect without restarting the app. A hand-bumped number was
// easy to forget (audit 2026-09-24: three proposed rewrites were all tagged
// v 7). An edit that keeps the exact length (a one-letter swap) still needs
// the app restarted: omarchy-shell nic.youtube-music quit.
//
// SOURCE is a plain string constant ON PURPOSE. For a few hours on 2026-09-24
// it was built at load time instead (a hash over its 27 KB, then split, join
// and a regex replace to drop comments). With that, the Omarchy shell crashed
// in Qt's JS garbage collector on almost every start (use-after-free in Qt
// 6.11.2, 11 of 13 live starts; in a nested test shell 5 of 5 with it and
// 0 of 20 without it). Keep any work out of this file's load.
//
// SOURCE goes out with every call (about 1 ms of parsing per 10 KB in the app,
// measured 2026-09-24), comments included.
var SOURCE = String.raw`
(function () {
  if (window.__nicYtm && window.__nicYtm.len === window.__nicYtmLen) return;
  var text = function (t) {
    if (!t) return "";
    if (t.simpleText) return t.simpleText;
    return (t.runs || []).map(function (r) { return r.text; }).join("");
  };
  // YouTube's own separator, so the columns we join match the text inside them
  // (a column already reads "Song • Noah Kahan"; a "·" between columns looked mixed).
  var SEP = " • ";
  var thumbOf = function (r) {
    var list = null;
    var holders = [r.thumbnail, r.thumbnailRenderer, r.thumbnail && r.thumbnail.croppedSquareThumbnailRenderer];
    for (var i = 0; i < holders.length && !list; i++) {
      var h = holders[i];
      if (!h) continue;
      var m = h.musicThumbnailRenderer || h;
      if (m.thumbnail && m.thumbnail.thumbnails) list = m.thumbnail.thumbnails;
      else if (m.thumbnails) list = m.thumbnails;
    }
    if (!list || !list.length) return "";
    // Pick one near 120 px: plenty for a 40-50 px row on a 2x screen.
    var best = list[0];
    for (var j = 0; j < list.length; j++) if (list[j].width <= 226) best = list[j];
    var u = best.url || "";
    u = u.indexOf("//") === 0 ? "https:" + u : u;
    // Queue and Up next videos come as plain hqdefault.jpg: a 4:3 picture with
    // black bars above and below the 16:9 frame, which the square crop in the
    // panel kept. mqdefault.jpg is the same frame at 16:9 with no bars. (Search
    // results carry YouTube's "sqp=" crop and are already bar-free.)
    if (/\/\/i\.ytimg\.com\/vi\//.test(u) && u.indexOf("sqp=") === -1)
      u = u.replace(/\/(hq|sd)?default\.jpg.*$/, "/mqdefault.jpg");
    return u;
  };
  var playOf = function (overlay) {
    try {
      var c = overlay.musicItemThumbnailOverlayRenderer.content.musicPlayButtonRenderer;
      return c.playNavigationEndpoint || null;
    } catch (e) { return null; }
  };
  // The first play-type action among a card's or page header's buttons
  // (artist: Shuffle, then Mix; radio card: Play; album or playlist: the round play button).
  // Save, Share and Subscribe buttons carry other commands and are skipped.
  var buttonPlay = function (list) {
    for (var i = 0; list && i < list.length; i++) {
      var b = list[i] || {};
      var ep = b.musicPlayButtonRenderer ? b.musicPlayButtonRenderer.playNavigationEndpoint
        : b.buttonRenderer ? (b.buttonRenderer.command || b.buttonRenderer.navigationEndpoint) : null;
      if (ep && (ep.watchEndpoint || ep.watchPlaylistEndpoint)) return ep;
    }
    return null;
  };
  var kindOf = function (it) {
    var b = it.browseId || "";
    if (/^MPREb/.test(b)) return "album";
    if (/^(UC|MPLA)/.test(b)) return "artist";
    if (/^MPSP/.test(b)) return "podcast";
    if (/^(VL|RD|PL|OLAK)/.test(b)) return "playlist";
    // A song tile can carry a radio playlistId too; the videoId wins.
    if (it.videoId) return "song";
    if (it.playlistId) return "playlist";
    return b ? "page" : "";
  };
  var item = function (key, r) {
    var it = { title: "", subtitle: "", thumb: thumbOf(r), videoId: "", setId: "", playlistId: "", browseId: "", params: "", play: null, duration: "" };
    if (key === "musicResponsiveListItemRenderer") {
      var cols = (r.flexColumns || []).map(function (c) {
        return text((c.musicResponsiveListItemFlexColumnRenderer || {}).text);
      });
      it.title = cols[0] || "";
      it.subtitle = cols.slice(1).filter(Boolean).join(SEP);
      it.duration = (r.fixedColumns || []).map(function (c) {
        return text((c.musicResponsiveListItemFixedColumnRenderer || {}).text);
      }).join("");
      it.videoId = (r.playlistItemData && r.playlistItemData.videoId) || "";
      // A playlist can hold the same song twice (a 901-song "Library Songs"
      // has 11 such rows). Each entry has its own set id; keying on it keeps
      // them all, like the app does, instead of dropping the repeats.
      it.setId = (r.playlistItemData && r.playlistItemData.playlistSetVideoId) || "";
      it.play = playOf(r.overlay);
    } else if (key === "musicMultiRowListItemRenderer") {
      // Podcast episodes (show pages, "Episodes for Later"). Without this a
      // podcast page came back with no rows at all. Tapping one plays it
      // (onTap); its title links to an episode page with nothing to list. The
      // length goes in the subtitle, not the time column: it reads "36 min" or
      // "1 hr 12 min", which is wider than any song time the column is sized for.
      it.title = text(r.title);
      var pp = r.playbackProgress && r.playbackProgress.musicPlaybackProgressRenderer;
      var len = pp ? text(pp.durationText).replace(/^[\s•]+/, "") : "";
      it.subtitle = [text(r.subtitle), len].filter(Boolean).join(SEP);
      it.play = playOf(r.overlay);
      r = { navigationEndpoint: r.onTap, thumbnail: r.thumbnail };
    } else if (key === "musicTwoRowItemRenderer") {
      it.title = text(r.title);
      it.subtitle = text(r.subtitle);
      it.play = playOf(r.thumbnailOverlay);
    } else if (key === "musicCardShelfRenderer") {
      it.title = text(r.title);
      it.subtitle = text(r.subtitle);
      // Search's top-result card has no thumbnail overlay: its Shuffle / Play
      // button is the action (an artist card played nothing before).
      it.play = playOf(r.thumbnailOverlay) || buttonPlay(r.buttons);
      var tr = r.title && r.title.runs && r.title.runs[0];
      if (tr && tr.navigationEndpoint) r = { navigationEndpoint: tr.navigationEndpoint, thumbnail: r.thumbnail };
    } else if (key === "playlistPanelVideoRenderer") {
      it.title = text(r.title);
      it.subtitle = text(r.shortBylineText) || text(r.longBylineText);
      it.duration = text(r.lengthText);
      it.videoId = r.videoId || "";
    }
    var nav = r.navigationEndpoint || {};
    if (nav.browseEndpoint) {
      it.browseId = nav.browseEndpoint.browseId || "";
      it.params = nav.browseEndpoint.params || "";
    }
    if (nav.watchEndpoint) {
      it.videoId = it.videoId || nav.watchEndpoint.videoId || "";
      it.playlistId = nav.watchEndpoint.playlistId || "";
      if (!it.play) it.play = { watchEndpoint: nav.watchEndpoint };
    }
    // A library artist page's "Shuffle all" row links straight to a playlist.
    if (nav.watchPlaylistEndpoint && !it.play) it.play = { watchPlaylistEndpoint: nav.watchPlaylistEndpoint };
    if (it.play && it.play.watchPlaylistEndpoint) it.playlistId = it.playlistId || it.play.watchPlaylistEndpoint.playlistId;
    if (!it.play && it.videoId) it.play = { watchEndpoint: { videoId: it.videoId } };
    it.kind = kindOf(it);
    // Drop tiles that do nothing from here, like "New playlist".
    if (!it.videoId && !it.browseId && !it.play) return null;
    return it.title ? it : null;
  };
  var ITEM_KEYS = ["musicResponsiveListItemRenderer", "musicTwoRowItemRenderer", "musicCardShelfRenderer",
    "playlistPanelVideoRenderer", "musicMultiRowListItemRenderer"];
  var SHELF_KEYS = ["musicShelfRenderer", "musicCarouselShelfRenderer", "gridRenderer", "musicPlaylistShelfRenderer", "musicCardShelfRenderer"];
  var shelfTitle = function (k, s) {
    if (s.title) return text(s.title);
    var h = s.header || {};
    var hh = h.musicCarouselShelfBasicHeaderRenderer || h.gridHeaderRenderer || h.musicSideAlignedItemRenderer || {};
    return text(hh.title || hh.strapline);
  };
  // Where the next page of a list is, if it has one. YouTube Music sends long
  // lists a page at a time (checked live 2026-09-24: playlists and Liked songs
  // 100 rows, library artists 25 then 50, filtered search 20, Home 3 shelves).
  // Two shapes:
  //   - older: shelf.continuations[0].nextContinuationData.continuation
  //     (library artists, the playlists grid, filtered search, Home)
  //   - newer: a continuationItemRenderer as the list's last entry, holding
  //     continuationEndpoint.continuationCommand.token (every playlist)
  // reloadContinuationData is not a next page (sort menus, filter chips, the
  // offline tab), so it is never followed.
  var nextOf = function (s) {
    if (!s) return "";
    var c = s.continuations && s.continuations[0];
    if (c && c.nextContinuationData && c.nextContinuationData.continuation) return c.nextContinuationData.continuation;
    var list = s.contents || s.items || s.continuationItems || [];
    var last = list.length ? list[list.length - 1] : null;
    var ep = last && last.continuationItemRenderer && last.continuationItemRenderer.continuationEndpoint;
    if (!ep) return "";
    if (ep.continuationCommand) return ep.continuationCommand.token || "";
    var cmds = (ep.commandExecutorCommand && ep.commandExecutorCommand.commands) || [];
    for (var i = 0; i < cmds.length; i++) if (cmds[i].continuationCommand) return cmds[i].continuationCommand.token || "";
    return "";
  };
  // A shelf's own "Show all" or "More" button (artist pages: Top songs,
  // Albums, Singles, Videos; Home's Listen again). Only browse links count, so
  // it opens in place. Title links are left out on purpose: on Home a carousel
  // titled with an artist's name links to that artist, which is not "all of
  // this shelf". Artist-tab links (UC... with params: "Live performances",
  // "Playlists by") are kept. One of them once came back empty (2.2 KB, early
  // on 2026-09-24) and they were left out for it, but a recheck at about 17:00
  // the same day gave full pages for three artists (Noah Kahan 33 and 12 rows,
  // Hozier 35 and 19, Taylor Swift 34 and 17), and the very token that had
  // come back empty then gave 33 rows three times. If one ever is empty, the
  // list just says so.
  var moreOf = function (s) {
    var h = (s.header && s.header.musicCarouselShelfBasicHeaderRenderer) || {};
    var btn = h.moreContentButton && h.moreContentButton.buttonRenderer;
    var eps = [s.bottomEndpoint, btn && btn.navigationEndpoint];
    for (var i = 0; i < eps.length; i++) {
      var b = eps[i] && eps[i].browseEndpoint;
      if (b && b.browseId) return { browseId: b.browseId, params: b.params || "" };
    }
    return null;
  };
  // Walk any response and gather items into titled sections, in page order.
  var collect = function (root, limit) {
    var sections = [];
    var seen = new Set();
    // Rows that sit outside any shelf keep their place on the page. Search
    // (2026-09-24) sends its top result, an empty "More results" shelf and
    // then its rows one by one; before, those rows were gathered into one
    // untitled section and moved to the very top, above the top result
    // ("queen" listed the artist 30th, and Enter opened "Greatest Hits").
    var loose = null;
    var pendingTitle = "";
    var looseSec = function () {
      if (!loose) {
        loose = { title: pendingTitle, items: [] };
        pendingTitle = "";
        sections.push(loose);
      }
      return loose;
    };
    var push = function (sec, key, r) {
      var it = item(key, r);
      if (!it) return;
      var id = it.kind + ":" + (it.setId || it.videoId || it.browseId || it.playlistId) + ":" + it.title;
      if (seen.has(id)) return;
      seen.add(id);
      if (sec.items.length < (limit || 200)) sec.items.push(it);
    };
    // sec is null outside a shelf: a shelf found there starts a section, and
    // a shelf inside a shelf does not.
    var walk = function (o, sec) {
      if (!o || typeof o !== "object") return;
      if (Array.isArray(o)) { for (var i = 0; i < o.length; i++) walk(o[i], sec); return; }
      for (var k in o) {
        var v = o[k];
        if (!v || typeof v !== "object") continue;
        if (SHELF_KEYS.indexOf(k) !== -1 && !sec) {
          var s = { title: shelfTitle(k, v), items: [], cont: nextOf(v), more: moreOf(v) };
          loose = null;
          // The card's own title is the result's name ("Queen"), which read as
          // a header above a row that says the same thing.
          if (k === "musicCardShelfRenderer") { s.title = "Top result"; push(s, k, v); }
          walk(v.contents || v.items || [], s);
          if (s.items.length) sections.push(s);
          else if (s.title) pendingTitle = s.title;
        } else if (ITEM_KEYS.indexOf(k) !== -1) {
          push(sec || looseSec(), k, v);
        } else if (k !== "frameworkUpdates" && k !== "responseContext" && k !== "menu" && k !== "header") {
          walk(v, sec);
        }
      }
    };
    walk(root, null);
    return sections.filter(function (s) { return s.items.length > 0; });
  };
  var app = function () { return document.querySelector("ytmusic-app"); };
  var fetch = function (path, body) { return app().networkManager.fetch(path, body); };
  // pear swaps in its own offline page (assets/error.html) whenever a load
  // fails. The widget sends this code there too, so the answers say so.
  var offlinePage = function () {
    var loc = window.location;
    return !!loc && /\/assets\/error\.html$/.test(String(loc.pathname || ""));
  };
  // networkManager.fetch rejects with a plain {error: {code, message}} object, which
  // CDP describes only as "Object" (the list then said just "Object"), and a missing
  // app element throws a TypeError whose text is a stack trace. Answer
  // {error: "<one short sentence>"} instead, for the list's empty-state text.
  var safe = function (run) {
    var explain = function (e) {
      var code = e && e.error && e.error.code;
      return { error: offlinePage() ? "YouTube Music couldn't load. Check the internet connection."
        : !app() ? "The app is still loading. Try again in a moment."
        : typeof navigator !== "undefined" && navigator.onLine === false ? "No internet connection."
        : code === 401 || code === 403 ? "YouTube Music wants you to sign in again."
        : code ? "YouTube Music could not open this (error " + code + ")."
        : "Could not reach YouTube Music." };
    };
    try { return Promise.resolve(run()).catch(explain); } catch (e) { return Promise.resolve(explain(e)); }
  };
  // Page headers (album, playlist, artist). Only these renderer names count:
  // a looser match picked up carousel headers like "Other versions".
  var HEADER_KEYS = ["musicResponsiveHeaderRenderer", "musicImmersiveHeaderRenderer", "musicVisualHeaderRenderer",
    "musicDetailHeaderRenderer", "musicHeaderRenderer"];
  var headerOf = function (res) {
    var h = null;
    var queue = [res.header, res.contents];
    for (var n = 0; n < queue.length && !h && n < 4000; n++) {
      var o = queue[n];
      if (!o || typeof o !== "object") continue;
      for (var k in o) {
        if (HEADER_KEYS.indexOf(k) !== -1 && o[k] && o[k].title) { h = o[k]; break; }
        if (o[k] && typeof o[k] === "object") queue.push(o[k]);
      }
    }
    if (!h) return { title: "", subtitle: "", thumb: "", play: null };
    var sub = [text(h.straplineTextOne), text(h.subtitle)].filter(Boolean).join(SEP);
    // What the page's big button plays: artist Shuffle (then Mix), album or playlist Play.
    var play = buttonPlay([h.playButton, h.startRadioButton].concat(h.buttons || []));
    return { title: text(h.title), subtitle: sub, thumb: thumbOf(h), play: play };
  };
  var browseBody = function (browseId, params) {
    var body = { browseId: browseId };
    if (params) body.params = params;
    return body;
  };
  // Queue entries come plain or wrapped (a song with a video counterpart,
  // which the app shows as ONE row); the wrapper's primary renderer is the row.
  var unwrap = function (w) {
    return w && (w.playlistPanelVideoRenderer || (w.playlistPanelVideoWrapperRenderer
      && w.playlistPanelVideoWrapperRenderer.primaryRenderer
      && w.playlistPanelVideoWrapperRenderer.primaryRenderer.playlistPanelVideoRenderer));
  };
  // YouTube Music stamps every queue item with its own id in
  // watchEndpoint.index (fresh ids come from queue.nextQueueItemId) and finds
  // items by that id itself. Unlike a position it survives adds, removes and
  // shuffles, so rows are acted on by id, never by a remembered position.
  var qidOf = function (r) {
    var we = r && r.navigationEndpoint && r.navigationEndpoint.watchEndpoint;
    return we && typeof we.index === "number" ? we.index : -1;
  };
  // #queue appears once the player has loaded; before that there is no queue.
  var queueState = function () {
    var q = document.querySelector("#queue");
    var st = q && q.queue && q.queue.store && q.queue.store.store;
    return st ? st.getState().queue : null;
  };
  // Cheap fingerprint of both lists: polled while the panel is open, because
  // the app's WebSocket sends nothing when the queue changes.
  var sigOf = function (st) {
    if (!st) return "";
    var ids = function (a) {
      return (a || []).map(function (w) {
        var r = unwrap(w);
        return r ? r.videoId + ":" + qidOf(r) + (r.selected ? "*" : "") : "?";
      }).join(",");
    };
    return ids(st.items) + "|" + ids(st.automixItems) + "|" + st.autoplay + "|" + st.repeatMode;
  };
  window.__nicYtm = {
    len: window.__nicYtmLen,
    // Whether the page can take commands yet: the app element with its
    // network manager and the player. "offline" on pear's own error page.
    ready: function () {
      if (offlinePage()) return "offline";
      var a = app();
      return !!(a && a.networkManager && document.querySelector("#movie_player"));
    },
    signedIn: function () {
      try { return !!window.ytcfg.get("LOGGED_IN"); } catch (e) { return false; }
    },
    // params is a filter chip's (Songs, Albums, ...). The mixed results have no
    // next page at all; a filtered search pages 20 rows at a time.
    search: function (q, params) {
      return safe(function () {
        var body = { query: q };
        if (params) body.params = params;
        return fetch("/search", body).then(function (r) {
          var chips = [];
          try {
            var sl = r.contents.tabbedSearchResultsRenderer.tabs[0].tabRenderer.content.sectionListRenderer;
            (sl.header.chipCloudRenderer.chips || []).forEach(function (c) {
              var x = c.chipCloudChipRenderer || {};
              var se = x.navigationEndpoint && x.navigationEndpoint.searchEndpoint;
              if (se && se.params) chips.push({ label: text(x.text), params: se.params });
            });
          } catch (e) {}
          var secs = collect(r, params ? 300 : 30);
          // Name untitled runs, or the list shows them under the previous header: an
          // untitled first shelf is the top result (podcasts get no card), and the loose
          // rows after it are the rest ("More results" only comes with a named shelf).
          if (secs.length > 1) secs.forEach(function (s, i) {
            if (!s.title) s.title = i === 0 ? "Top result" : "More results";
          });
          return { sections: secs, chips: chips };
        });
      });
    },
    browse: function (browseId, params) {
      return safe(function () {
        return fetch("/browse", browseBody(browseId, params)).then(function (r) {
          var header = headerOf(r);
          var sections = collect(r, 300);
          // Album tracks come without their own art: use the album cover.
          if (header.thumb) sections.forEach(function (sec) {
            sec.items.forEach(function (it) { if (!it.thumb) it.thumb = header.thumb; });
          });
          // Home sends more shelves as you scroll: the section list's own next
          // page. Only the one-column layout counts. On a playlist page the
          // (two-column) section list's next page is "Suggestions": songs that
          // are NOT in the playlist, and it never ends.
          var sl = null;
          try { sl = r.contents.singleColumnBrowseResultsRenderer.tabs[0].tabRenderer.content.sectionListRenderer; } catch (e) {}
          return { header: header, sections: sections, cont: nextOf(sl) };
        });
      });
    },
    // The next page of a list. path is "/browse" or "/search" (the token is
    // enough on its own: the same body the app's own search uses). Returns
    // rows for the end of the list, or (Home) whole new sections, plus the
    // token for the page after, "" at the end.
    more: function (path, token) {
      return safe(function () {
        return fetch(path, { continuation: token }).then(function (r) {
          var cc = r.continuationContents || {};
          if (cc.sectionListContinuation)
            return { items: [], sections: collect(cc.sectionListContinuation, 300), cont: nextOf(cc.sectionListContinuation) };
          var shelf = cc.musicShelfContinuation || cc.musicPlaylistShelfContinuation || cc.gridContinuation || null;
          (r.onResponseReceivedActions || []).forEach(function (a) {
            if (!shelf && a.appendContinuationItemsAction) shelf = a.appendContinuationItemsAction;
          });
          var items = [];
          collect(shelf || {}, 1000).forEach(function (s) { items = items.concat(s.items); });
          return { items: items, sections: [], cont: nextOf(shelf) };
        });
      });
    },
    // Play a tile that has no play button of its own (artists): load its page and
    // press the header's big button, or else play the first playable row.
    playPage: function (browseId, params) {
      return safe(function () {
        return fetch("/browse", browseBody(browseId, params)).then(function (r) {
          var ep = headerOf(r).play;
          if (!ep) collect(r, 5).some(function (s) {
            return s.items.some(function (it) { ep = it.play; return !!ep; });
          });
          if (!ep) return { error: "Nothing here can be played." };
          window.__nicYtm.play(ep);
          return { ok: true };
        });
      });
    },
    // Whether a video still plays here (removed, private, region-blocked).
    // The same /player call the app makes before playing; it starts nothing.
    // A failed check counts as playable, so a network blip never forgets a song.
    playable: function (videoId) {
      return safe(function () {
        return fetch("/player", { videoId: videoId }).then(function (r) {
          var s = (r && r.playabilityStatus) || {};
          return { ok: s.status !== "ERROR" && s.status !== "UNPLAYABLE", reason: s.reason || "" };
        }, function () { return { ok: true, reason: "" }; });
      });
    },
    // The player as it really is. The app's own API cannot be trusted here: it
    // reports every newly loaded song as playing and never reports a play or
    // pause at 0:00. state is #movie_player.getPlayerState(): -1 unstarted,
    // 0 ended, 1 playing, 2 paused, 3 buffering, 5 cued.
    state: function () {
      var p = document.querySelector("#movie_player");
      var v = document.querySelector("video");
      if (!p && !v) return null;
      var st = null, vid = "";
      try { st = p && typeof p.getPlayerState === "function" ? p.getPlayerState() : null; } catch (e) {}
      try { vid = p && typeof p.getVideoData === "function" ? ((p.getVideoData() || {}).video_id || "") : ""; } catch (e) {}
      // t is the song's own time. With gapless playback the <video> keeps the
      // songs before this one in the same stream, so its currentTime runs on
      // from where the last song ended (4:18 into a 3:43 song, seen live);
      // off is that gap, for correcting the app's pushes (which use it raw).
      var vt = v ? v.currentTime : 0, t = vt;
      try { if (p && typeof p.getCurrentTime === "function") t = p.getCurrentTime(); } catch (e) {}
      return { state: typeof st === "number" ? st : null, videoId: vid, t: t, off: vt - t,
        paused: v ? v.paused : true, ended: v ? v.ended : false };
    },
    // The whole queue in one snapshot, for BOTH the Queue tab and Up next, so
    // the two lists can never disagree. queueIndex is the position in
    // queue.items; queueId is the item's own id (see qidOf).
    queue: function (n) {
      var st = queueState();
      if (!st) return { items: [], current: -1, upNext: [], sig: "" };
      var items = st.items || [];
      // The playing row is the FIRST selected one, exactly like the app's own
      // getCurrentItemIndex. Server refreshes insert items as sent, so a second
      // copy can arrive still marked selected until the next song change.
      var cur = -1;
      for (var i = 0; i < items.length && cur < 0; i++) { var s = unwrap(items[i]); if (s && s.selected) cur = i; }
      var row = function (w, pos, auto) {
        var r = unwrap(w);
        var it = r && item("playlistPanelVideoRenderer", r);
        if (!it) return null;
        delete it.play;  // rows are played by id through queueAct; keeps the reply small
        it.kind = "queue";
        it.queueIndex = auto ? -1 : pos;
        it.queueId = qidOf(r);
        it.auto = !!auto;
        it.current = !auto && pos === cur;
        it.played = !auto && cur >= 0 && pos < cur;
        return it;
      };
      var all = [];
      for (var j = 0; j < items.length; j++) { var it = row(items[j], j, false); if (it) all.push(it); }
      var next = all.filter(function (x) { return x.queueIndex > cur; }).slice(0, n);
      // Autoplay picks only ever play when autoplay is on, and not with
      // repeat all (the app wraps back to the top of the queue instead).
      if (st.autoplay !== false && st.repeatMode !== "ALL") {
        var mix = st.automixItems || [];
        for (var k = 0; k < mix.length && next.length < n; k++) { var a = row(mix[k], k, true); if (a) next.push(a); }
      }
      return { items: all, current: cur, upNext: next, sig: sigOf(st) };
    },
    queueSig: function () { return sigOf(queueState()); },
    // Jump to or remove one row, found by its id + videoId at the moment of
    // the click. pos (where the bar last saw it) only breaks a tie. Returns
    // false when the row is gone, so the bar can reload instead of hitting
    // whatever now sits at the old position.
    queueAct: function (op, id, videoId, pos, auto) {
      var qe = document.querySelector("#queue");
      var st = queueState();
      if (!qe || !st) return false;
      var list = (auto ? st.automixItems : st.items) || [];
      var at = -1, same = 0;
      for (var i = 0; i < list.length; i++) {
        var r = unwrap(list[i]);
        if (!r || qidOf(r) !== id) continue;
        same += 1;
        if (r.videoId === videoId && (at < 0 || Math.abs(i - pos) < Math.abs(at - pos))) at = i;
      }
      if (at < 0) return false;
      var hit = unwrap(list[at]);
      if (auto) {
        if (op !== "jump") return false;
        // Navigating to the pick's own endpoint is what the app's queue panel
        // does: it finds the pick by id, moves it into the queue and plays it,
        // keeping the queue.
        return window.__nicYtm.play({ watchEndpoint: hit.navigationEndpoint.watchEndpoint });
      }
      if (op === "jump") {
        // The same action the REST PATCH /queue sends, with a fresh position.
        qe.dispatch({ type: "SET_INDEX", payload: at });
        return true;
      }
      // The app's own removeItem skips ahead first when the row is playing and
      // tells the server-side queue too; the REST DELETE only drops the row
      // locally. It looks items up by id, so use it only when the id is unique.
      if (same === 1 && qe.queue && typeof qe.queue.removeItem === "function") qe.queue.removeItem(String(id));
      else qe.dispatch({ type: "REMOVE_ITEM", payload: at });
      return true;
    },
    // YouTube Music's own lyrics for a video (plain text, no timings): the
    // watch-next panel's Lyrics tab points at a MPLYt browse page holding one
    // musicDescriptionShelfRenderer (text plus a "Source: LyricFind" footer).
    // The widget uses this when LRCLIB has no timed lyrics (2026-09-24).
    lyrics: function (videoId) {
      return safe(function () {
        return fetch("/next", { videoId: videoId }).then(function (r) {
          var wn = ((((r && r.contents) || {}).singleColumnMusicWatchNextResultsRenderer || {}).tabbedRenderer || {}).watchNextTabbedResultsRenderer || {};
          var ep = null;
          (wn.tabs || []).forEach(function (t) {
            var b = t.tabRenderer && t.tabRenderer.endpoint && t.tabRenderer.endpoint.browseEndpoint;
            var cfg = b && b.browseEndpointContextSupportedConfigs && b.browseEndpointContextSupportedConfigs.browseEndpointContextMusicConfig;
            if (b && cfg && cfg.pageType === "MUSIC_PAGE_TYPE_TRACK_LYRICS") ep = b;
          });
          if (!ep) return { none: true };
          return fetch("/browse", { browseId: ep.browseId }).then(function (b) {
            var shelf = null;
            var list = (((b && b.contents) || {}).sectionListRenderer || {}).contents || [];
            list.forEach(function (c) { if (!shelf && c.musicDescriptionShelfRenderer) shelf = c.musicDescriptionShelfRenderer; });
            var t = shelf ? text(shelf.description) : "";
            if (!t) return { none: true };
            return { text: t, source: shelf ? text(shelf.footer) : "" };
          });
        });
      });
    },
    // Start playing an endpoint the same way clicking it in the app does.
    play: function (endpoint) {
      var a = app();
      if (!a) return false;   // mid-reload: the widget says "still loading" instead of a stack trace
      a.dispatchEvent(new CustomEvent("yt-navigate", { bubbles: true, composed: true, detail: { endpoint: endpoint } }));
      return true;
    }
  };
})();
`
