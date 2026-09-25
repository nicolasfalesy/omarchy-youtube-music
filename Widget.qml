import QtQuick
import QtQuick.Effects
import QtWebSockets
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Page.js" as Page

// YouTube Music for the bar — a full remote for the YouTube Music desktop app
// (pear-desktop, https://github.com/pear-devs/pear-desktop).
//
// History: v1 was a now-playing card for a Firefox tab. It was then asked to
// be "way more elegant" and "way more powerful", and moved to the desktop app
// plus search, library and playlists, queue, and like/shuffle/repeat/volume.
// The audit on 2026-09-24 added paging, a play state that matches the page,
// a safe resume, queue rows acted on by id, keyboard control and tooltips, and
// removed a reconnect loop that kept a CPU core busy. The why is at each change.
//
// Two local connections, both bound to 127.0.0.1 only:
//   - The app's API server plugin (127.0.0.1:26538, set in
//     ~/.config/YouTube Music/config.json; see README.md for the keys). REST for commands, and a WebSocket (/api/v1/ws) that pushes
//     song, play state, position, volume, repeat and shuffle live, so nothing
//     here polls while music plays. Auth is NONE today. When
//     ~/.local/state/omarchy/nic-youtube-music/token holds a token, every
//     request sends it (a Bearer header, and ?token= on the socket), so the app
//     can move to AUTH_AT_FIRST without another edit here.
//   - The app's debug port (9223, set in ~/.config/youtube-music-flags.conf),
//     used for what the API cannot do or gets wrong: list the library, open
//     albums, playlists and artists, page long lists, act on queue rows by id,
//     and read the player's real state. See Page.js.
//
// The app's own word on "playing" is not trusted. It marks every newly loaded
// song as playing (isPaused false) and never reports a play or pause at 0:00,
// and on every start YouTube Music restores the account's last queue as a
// cued, unstarted song. So a song only counts as the user's (songReal) once it has
// really played or the widget started it itself (expectSong). The page is asked
// 1.5 s after each song change and whenever the pushes stop, and only the last
// position the app pushed (never the smoothed one) is saved.
//
// The app runs only while it is needed (the brief: run it in the background,
// never keep it running when it is not needed, and keep it all seamless):
//   - Its window lives on the hidden "music" workspace (rule in
//     ~/.config/hypr/hyprland.lua); the cover art in the panel toggles it.
//   - Pressing play starts it in the background, and so does opening the panel
//     (after 400 ms, so Tab passing through the panels does not count).
//   - After idleMinutes (default 5) paused, with the panel closed on every
//     monitor and the app window not on screen, it quits cleanly over the debug
//     port (Browser.close; a plain kill made Chromium crash on purpose and pop a
//     crash notice). The page gets one last look first, in case music plays.
//   - The last song, position and playlist are kept in
//     ~/.local/state/omarchy/nic-youtube-music/last.json, so the bar keeps
//     showing it while the app is closed and play resumes right where it was.
//     A song that can no longer play is dropped with a note; with nothing
//     remembered, play starts Liked songs. (The app's own resumeOnStart is off
//     so it never starts music by itself.)
// It never opens a browser tab.
Panel {
  id: root
  moduleName: "nic.youtube-music"
  ipcTarget: "nic.youtube-music"
  manageIpc: false

  readonly property string api: "http://127.0.0.1:26538/api/v1"
  readonly property string cdpList: "http://127.0.0.1:9223/json"
  readonly property string appClass: "com.github.th-ch.youtube-music"
  // Its own folder, not ~/.local/state/omarchy itself: the shell watches three
  // folders there (toggles, indicators, current), and a FileView on a folder
  // also fires for any file created or renamed next to it, so every atomic save
  // of the old nic-youtube-music-last.json made the bar and the idle service
  // each spawn a bash probe (sandbox test 2026-09-24: 8 saves, 19 fileChanged).
  // FileView creates the folder on the first write.
  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/nic-youtube-music"

  readonly property color fg: bar ? bar.foreground : Color.foreground
  // Bar items follow the bar's own foreground: it differs from the panel's
  // when the bar is transparent (it then follows the wallpaper).
  readonly property color barFg: bar ? bar.barForeground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  function a(c, x) { return Qt.rgba(c.r, c.g, c.b, x) }

  readonly property bool showTitle: String(setting("showTitle", true)) !== "false"
  readonly property real maxLabelWidth: Number(setting("maxLabelWidth", 150)) || 150

  // Glyphs as code points: file tools on this laptop have dropped pasted
  // Nerd Font glyphs before.
  function g(cp) { return String.fromCodePoint(cp) }
  readonly property string gYouTube: g(0xF05C3)
  readonly property string gPlay: g(0xF040A)
  readonly property string gPause: g(0xF03E4)
  readonly property string gPrev: g(0xF04AE)
  readonly property string gNext: g(0xF04AD)
  readonly property string gShuffle: g(0xF049D)
  readonly property string gRepeat: g(0xF0456)
  readonly property string gRepeatOne: g(0xF0458)
  readonly property string gLike: g(0xF0514)
  readonly property string gLikeOn: g(0xF0513)
  readonly property string gDislike: g(0xF0512)
  readonly property string gDislikeOn: g(0xF0511)
  readonly property string gVolume: g(0xF057E)
  readonly property string gMute: g(0xF075F)
  readonly property string gMusic: g(0xF075A)
  readonly property string gBack: g(0xF004D)
  readonly property string gPlayNext: g(0xF0411)
  readonly property string gQueueAdd: g(0xF0412)
  readonly property string gClose: g(0xF0156)
  readonly property string gSearch: g(0xF0349)
  readonly property string gOpen: g(0xF03CC)
  readonly property string gUp: g(0xF005D)

  // ------------------------------------------------------------ player state
  property bool appUp: false
  property var song: null
  property bool isPlaying: false
  property real position: 0
  property int volume: 100
  property bool muted: false
  property string repeatMode: "NONE"   // NONE | ALL | ONE
  property bool shuffle: false
  property string likeState: "INDIFFERENT"
  // True once the app's current song is really the user's: it has played (a push
  // past 0:00, or the page says it plays), or the widget started it. On start
  // YouTube Music restores the account's last queue as a cued song at 0:00,
  // which may not even be the song played here last. It must not replace the
  // remembered song and second, and it must never show as playing. It did on
  // 2026-09-24: "Willing and Able @90" became "Meet Me Halfway @284", a song
  // nobody pressed play on, and the bar danced for 20 minutes in silence.
  property bool songReal: false
  // Set when the widget itself starts a song (a row, a jump, next, the
  // resume), so that song's VIDEO_CHANGED counts as real. Cleared by the
  // VIDEO_CHANGED of that song (any song when the video is not known), or
  // after 15 s if none comes.
  property bool expectSong: false
  // The video that song is, when known (a resume, a song row, a queue jump).
  property string expectVideo: ""
  onExpectSongChanged: if (!expectSong) { expectVideo = ""; expectTimer.stop() }
  Timer { id: expectTimer; interval: 15000; onTriggered: root.expectSong = false }
  // Set on every monitor's copy (see peers()): each copy has its own socket
  // and gets the same pushes, and a copy that was not clicked took the resumed
  // song's first pushes for the cue's (offline test with two copies,
  // 2026-09-24).
  function expect(videoId) {
    var ps = peers()
    for (var i = 0; i < ps.length; i++) if (ps[i] && ps[i] !== root) ps[i].expectHere(videoId)
    expectHere(videoId)
  }
  function expectHere(videoId) { expectVideo = videoId || ""; expectSong = true; expectTimer.restart() }
  // The start failed: stop waiting, on every copy.
  function unexpect() {
    var ps = peers()
    for (var i = 0; i < ps.length; i++) if (ps[i] && ps[i] !== root) ps[i].expectSong = false
    expectSong = false
  }
  // The app sends VIDEO_CHANGED only after its main process has downloaded
  // the new cover (HEAD + GET, api-server source), so the new song's time and
  // play pushes can arrive while song still holds the old one, or nothing yet
  // (PLAYER_INFO came before the page had a song). When the widget is waiting
  // for a known video and song is not it, those pushes belong to the incoming
  // song and must not make the old one (often the restored cue) the user's. A null
  // song counts too: those pushes made songReal true, and the cue's late
  // VIDEO_CHANGED then inherited it (offline test, 2026-09-24).
  function incomingSong() { return expectSong && expectVideo !== "" && (!song || song.videoId !== expectVideo) }
  // The last position the app itself pushed (or the page reported). This is
  // what gets saved, never the smoothed guess, which ran on to the song's end
  // while nothing played (the state file held 284 of 284 on 2026-09-24).
  property real reportedPosition: 0
  // When the app last pushed anything (ms), and the last POSITION_CHANGED.
  property double lastPush: 0
  property real posPushPos: -1
  property double posPushAt: 0
  // When the play state last went from playing to not playing (ms). The app
  // pauses at a song's end (the video's own pause event) just before the next
  // song loads, so "was playing a moment ago" still counts for autoplay.
  property double stoppedPlayingAt: 0
  onIsPlayingChanged: {
    if (!isPlaying) { stoppedPlayingAt = Date.now(); return }
    // One player at a time (2026-09-24: starting either one stops the
    // other). World Radio (the nic.world-radio plugin, when installed) plays
    // inside the shell and has no MPRIS, so it is stopped over its IPC, and
    // only while it is actually on (its stop also forgets the current
    // station). Without that plugin the status call fails and nothing runs. One copy does it, not one
    // per monitor. The radio's side pauses this widget through pauseOnly().
    if (isPrimary())
      Quickshell.execDetached(["sh", "-c", "omarchy-shell nic.world-radio status | jq -e '.playing or .buffering' >/dev/null && omarchy-shell -q nic.world-radio stop"])
  }
  // Bumped by every real play/pause event and every play/pause the widget
  // sends. A page check asked before one of those answers with the state from
  // before it, so its answer is dropped when the number moved on. Without
  // this, a check still on its way at a pause came back "playing" and the
  // pause icon stayed for 3-5 s (real clicks, 2026-09-24).
  property int stateEpoch: 0
  // When a real pause event (or the widget's own /pause) last happened. The
  // "two forward pushes mean it plays" rule ignores pushes for 3 s after it:
  // the progress bar can push one last second after the pause event.
  property double pausedAt: 0
  // A resume the widget asked for: the song and the second it should start at,
  // for the one fallback seek (see doPending). Dropped after 20 s.
  property var resumeTarget: null
  // While the app is closed (or still waking), show the remembered song.
  property var lastSong: null
  // Whether the bar and panel show the app's own song (a real one, or any
  // song when nothing is remembered) rather than the remembered one.
  readonly property bool showingLive: appUp && !!song && !!song.title && (songReal || !lastSong)
  readonly property var shownSong: showingLive ? song : lastSong
  // The app has one of the user's songs loaded: commands like seek, like and dislike
  // act on something real.
  readonly property bool songLive: appUp && songReal && !!song && !!song.title
  readonly property bool hasSong: shownSong !== null && shownSong !== undefined && !!shownSong.title
  readonly property string title: hasSong ? shownSong.title : ""
  readonly property string artist: hasSong ? (shownSong.artist || "") : ""
  readonly property string album: hasSong ? (shownSong.album || "") : ""
  readonly property string artUrl: hasSong ? (shownSong.imageSrc || "") : ""
  readonly property real duration: hasSong ? Number(shownSong.songDuration || 0) : 0

  // ------------------------------------------------------------ browse state
  property string view: "home"            // home | library | queue
  property string libraryPage: "FEmusic_liked_playlists"
  property string searchText: ""
  property var sections: []                // [{title, items, cont, more}] for the list
  property var pageStack: []               // drilled-in pages: {browseId, params, title, play, back}
  property var pageHeader: null
  property bool loading: false
  property string listError: ""
  property bool signedIn: true
  // The whole queue and the next songs, both from one page snapshot
  // (loadQueue), so the Queue tab and Up next always agree.
  property var queueItems: []
  property var upNext: []
  // Fingerprint of the page's queue from the last load (see the queue poll).
  property string queueSig: ""
  property int queueSerial: 0
  // Set when the Queue tab comes up, so its first load scrolls to the playing
  // song instead of the top of the history.
  property bool queueScrollToNow: false
  // Up next as list rows, with an "Autoplay" divider where the queue ends
  // and YouTube Music's own picks begin.
  readonly property var upNextRows: {
    var out = []
    var marked = false
    for (var i = 0; i < upNext.length; i++) {
      if (upNext[i].auto && !marked) {
        if (i > 0) out.push({ header: true, title: "Autoplay" })
        marked = true
      }
      out.push(upNext[i])
    }
    return out
  }
  property int serial: 0
  // Paging (2026-09-24). YouTube Music sends long lists a page at a time:
  // playlists 100 rows, library artists 25 then 50, filtered search 20, Home
  // 3 shelves. Before this only page one ever showed (25 of 453 library
  // artists, 100 of the 901 songs in "Library Songs"). moreToken is the next
  // page for the END of the list (its last section, or Home's section list),
  // so new rows only ever land at the bottom and row numbers above never move.
  property string moreToken: ""
  property string morePath: "/browse"
  property bool loadingMore: false
  // Home comes in five small slices and Quick picks is never in the first, so
  // Home fetches all of them right away instead of waiting for a scroll.
  property bool moreEager: false
  // Rows already listed, so a page that repeats one does not show it twice.
  property var rowKeys: ({})
  // Enough for a 900-song playlist and 450 library artists. Filtered
  // search never runs out of pages, so it stops sooner.
  readonly property int maxRows: searching ? 200 : 2000
  readonly property bool moreCapped: moreToken !== "" && rows.length >= maxRows
  // Search filters (Songs, Albums, ...) from YouTube Music's own chips. Their
  // params differ per query (checked 2026-09-24), so they come from this
  // query's unfiltered results and reset when the query changes.
  property var searchChips: []
  property string searchFilter: ""
  readonly property var searchFilterOptions: {
    var want = [["Songs", "Songs"], ["Albums", "Albums"], ["Artists", "Artists"], ["Community playlists", "Playlists"]]
    var out = [{ value: "", label: "All" }]
    for (var i = 0; i < want.length; i++)
      for (var j = 0; j < searchChips.length; j++)
        if (searchChips[j].label === want[i][0]) { out.push({ value: searchChips[j].params, label: want[i][1] }); break }
    return out.length > 1 ? out : []
  }
  readonly property bool searching: searchText.trim().length > 0
  readonly property var currentPage: pageStack.length > 0 ? pageStack[pageStack.length - 1] : null

  readonly property var libraryPages: [
    { value: "FEmusic_liked_playlists", label: "Playlists" },
    { value: "VLLM", label: "Liked songs" },
    { value: "FEmusic_liked_albums", label: "Albums" },
    { value: "FEmusic_library_corpus_track_artists", label: "Artists" },
    { value: "FEmusic_history", label: "Recent" }
  ]

  // Flatten sections into list rows: a header row, then item rows.
  readonly property var rows: {
    var out = []
    if (root.view === "lyrics" && !root.searching && !root.currentPage) return out
    var secs = root.view === "queue" && !root.searching && !root.currentPage
      ? [{ title: "", items: root.queueItems }] : root.sections
    for (var i = 0; i < secs.length; i++) {
      if (secs[i].title && secs.length > 1) out.push({ header: true, title: secs[i].title, more: secs[i].more || null })
      for (var j = 0; j < secs[i].items.length; j++) out.push(secs[i].items[j])
    }
    return out
  }

  // Row picked with the arrow keys (-1 = none); Enter opens it like a click.
  // A new list resets it (list.onModelChanged); a page appended below or a
  // queue reload keeps it while the row is still there.
  property int cursor: -1
  onRowsChanged: if (cursor >= rows.length || (cursor >= 0 && rows[cursor].header)) cursor = -1
  function moveCursor(step) {
    for (var i = cursor + step; i >= 0 && i < rows.length; i += step) {
      if (rows[i].header) continue
      cursor = i
      list.positionViewAtIndex(i, ListView.Contain)
      return
    }
  }

  // ------------------------------------------------------------ panel plumbing
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  function open() {
    controller.show()
    readAppShown()
    if (view === "queue") queueScrollToNow = true
    if (view === "lyrics" && !searching) loadLyrics()
    if (appUp) refresh()
    // Wake a moment later, not at once: Tab and the numbered panel hotkeys open
    // every panel they pass through, and each pass started the whole app
    // (about 1.1 GB) for five idle minutes.
    else if (!starting) openWake.restart()
  }
  function close() { controller.hide() }
  function toggle() { root.opened ? root.close() : root.open() }
  Timer { id: openWake; interval: 400; onTriggered: if (root.opened && !root.appUp) root.wake("") }
  readonly property bool openWakePending: openWake.running

  // Any visit to the panel counts as use, even one shorter than the 15 s idle
  // tick (a quick peek used to fall between two ticks). Reset on every copy:
  // the count that decides the quit is the first copy's, and a peek on another
  // monitor's panel left it running, and the app quit seconds after that
  // panel closed (offline test with two copies, 2026-09-24).
  onOpenedChanged: {
    var ps = peers()
    for (var i = 0; i < ps.length; i++) if (ps[i]) ps[i].idleSeconds = 0
    idleSeconds = 0
  }

  // One copy of this widget runs per monitor (Bar.qml builds a bar per
  // screen), each with its own socket and timers. The panel is open on only one
  // of them, so the idle quit asks every copy, and only the first copy quits
  // the app and writes the state file.
  function peers() {
    var ws = bar && typeof bar.moduleWidgets === "function" ? bar.moduleWidgets(moduleName) : []
    return ws && ws.length ? ws : [root]
  }
  function primary() {
    var ps = peers()
    return ps.indexOf(root) < 0 ? root : ps[0]
  }
  function isPrimary() { return primary() === root }
  function anyCopyBusy() {
    var ps = peers()
    for (var i = 0; i < ps.length; i++) {
      var p = ps[i]
      if (p && (p.opened || p.starting || p.openWakePending)) return true
    }
    return opened || starting || openWake.running
  }

  // ------------------------------------------------------------ REST
  // API token (security hardening, optional at runtime). The app's API server
  // answers any web page (CORS "*", no Origin check) while its auth is NONE.
  // When this file holds a token, every call sends it; no file means no
  // header, which still works under NONE. Mode 600 under ~/.local/state: never
  // in the plugin folder (a write there reloads the plugin) and never in the
  // backup.
  property string apiToken: ""
  // The file loads asynchronously, after the first probe has already gone out
  // without it. Under auth that probe is refused (the app accepts the socket,
  // then closes it with 1008), so a token that arrives while the app is not up
  // probes again at once instead of at the next 20 s tick.
  onApiTokenChanged: if (!appUp) probe()
  FileView {
    id: tokenFile
    path: root.stateDir + "/token"
    watchChanges: true
    printErrors: false
    onLoaded: root.apiToken = text().trim()
    onLoadFailed: root.apiToken = ""
    onFileChanged: reload()
  }

  function call(method, path, body, cb) {
    var x = new XMLHttpRequest()
    x.onreadystatechange = function() {
      if (x.readyState !== XMLHttpRequest.DONE) return
      if (!cb) return
      var data = null
      try { data = x.responseText ? JSON.parse(x.responseText) : null } catch (e) {}
      cb(x.status, data)
    }
    x.open(method, root.api + path)
    if (root.apiToken) x.setRequestHeader("Authorization", "Bearer " + root.apiToken)
    if (body !== undefined && body !== null) {
      x.setRequestHeader("Content-Type", "application/json")
      x.send(JSON.stringify(body))
    } else {
      x.send()
    }
  }
  function cmd(path, body) { call("POST", path, body === undefined ? null : body, null) }

  function hasLast() { return !!(lastSong && lastSong.videoId) }
  // Nothing of the user's is loaded in the player: the app is closed, or it holds
  // only YouTube Music's restored cue while a song is remembered, or it holds
  // nothing at all. Play, next and previous then start or resume instead: the
  // app's /play is playVideo(), which on a cue started the wrong song from
  // 0:00 and on an empty player did nothing.
  function nothingReal() { return !appUp || (!songReal && (hasLast() || !(song && song.title))) }

  // Whether the page's own player is playing (see Page.js state()).
  // "Buffering" (3) counts only while the video element itself is not paused:
  // fast play/pause presses left YouTube Music's player at 3 with the video
  // paused, and counting that as playing made every later press send /pause
  // to a paused player, so it never came back (reported 2026-09-24: fast
  // play/pause presses broke it; reproduced with 7 presses 0.15 s apart). A
  // single /play un-sticks it.
  function pagePlaying(v) {
    if (!v) return false
    if (v.state === 1) return true
    if (v.state === 3) return v.paused === false
    return v.state === null && v.paused === false && !v.ended
  }

  // Explicit pause/play, not /toggle-play: in testing (2026-09-24) one toggle a
  // second after another was ignored by the app. The player's real state is
  // read in the page before each command, because the socket's flag can be
  // stale (the app says "playing" for every new song and never reports a play
  // or pause at 0:00).
  //
  // Presses are merged. Each press only flips the wished-for state (ppTarget),
  // and the icon follows it at once; one command at a time goes to the app,
  // and 0.5 s after it the page is asked again and one more command is sent
  // only if the page and the wish still differ. Sending /play and /pause
  // back to back for every press is what jammed YouTube Music's player, and
  // presses read the page before the previous command had landed, so two
  // presses sent the same command and cancelled out. Now 7 quick presses end
  // playing and 8 end paused, with two or three commands sent.
  property int ppTarget: -1          // -1 none, 1 play, 0 pause
  property bool ppBusy: false
  property bool ppDirty: false
  property bool ppResent: false
  function playPause() {
    if (nothingReal()) { wake("play"); return }
    var cur = ppTarget >= 0 ? ppTarget === 1 : isPlaying
    ppTarget = cur ? 0 : 1
    isPlaying = ppTarget === 1
    if (ppBusy) { ppDirty = true; return }
    ppResent = false
    ppSend()
  }
  function ppSend() {
    ppBusy = true
    ppDirty = false
    page("window.__nicYtm.state()", function(v) {
      var want = root.ppTarget
      if (want < 0) { root.ppBusy = false; return }
      var playing = v ? root.pagePlaying(v) : !(want === 1)
      root.stateEpoch += 1
      if (want === 1 && !playing) {
        root.cmd("/play")
        // A play pressed here makes this song the user's, and gives the stall check
        // its grace before the first push.
        root.songReal = true
        root.lastPush = Date.now()
      } else if (want === 0 && playing) {
        root.pausedAt = Date.now()
        root.cmd("/pause")
      }
      root.isPlaying = want === 1
      ppSettle.restart()
    })
  }
  Timer {
    id: ppSettle
    interval: 500
    onTriggered: {
      // More presses came in meanwhile: check the page against the newest wish.
      if (root.ppDirty) { root.ppSend(); return }
      // Last look: the app sometimes ignores a command that comes right after
      // another one, so send once more if the page still differs.
      root.page("window.__nicYtm.state()", function(v) {
        if (root.ppDirty) { root.ppSend(); return }
        var want = root.ppTarget
        if (v && want >= 0 && root.pagePlaying(v) !== (want === 1) && !root.ppResent) {
          root.ppResent = true
          root.ppSend()
          return
        }
        root.ppBusy = false
        root.ppTarget = -1
        if (v) root.isPlaying = root.pagePlaying(v)
      })
    }
  }
  // With nothing of the user's loaded, next and previous resume the remembered
  // song instead (a middle click on a closed app should not skip a song never
  // heard).
  // Pause if something plays; never start, never wake the app. /pause is the
  // app's pauseVideo(), which does nothing on a paused or cued player.
  function pauseOnly() {
    if (!appUp) return
    stateEpoch += 1
    pausedAt = Date.now()
    isPlaying = false
    cmd("/pause")
  }
  function next() { if (nothingReal()) { wake("play"); return } expect(""); cmd("/next") }
  function previous() { if (nothingReal()) { wake("play"); return } expect(""); cmd("/previous") }

  // ------------------------------------------------------------ app lifecycle
  property bool starting: false
  property bool startFailed: false
  property string pendingAction: ""

  // Start the app in the background if it is not running. action "play"
  // resumes the remembered song once the page is ready.
  function wake(action) {
    if (action === "play") pendingAction = "play"
    if (appUp) { if (pendingAction) whenReady(doPending); return }
    if (starting) return
    starting = true
    startFailed = false
    probe()
    // Give an already-running app one probe before launching another copy.
    launchTimer.restart()
    startTimeout.restart()
  }
  Timer {
    id: launchTimer
    interval: 600
    onTriggered: if (!root.appUp) Quickshell.execDetached(["setsid", "-f", "youtube-music"])
  }
  Timer {
    id: startTimeout
    interval: 40000
    onTriggered: if (!root.appUp) { root.starting = false; root.startFailed = true; root.pendingAction = "" }
  }

  // The API socket opens before the page has finished loading, so wait for
  // the YouTube Music app element and player before touching the page.
  property int readyTries: 0
  property var readyCallbacks: []
  function whenReady(cb) {
    readyCallbacks = readyCallbacks.concat([cb])
    if (readyTries > 0) return
    readyTries = 1
    readyCheck()
  }
  function readyCheck() {
    page("window.__nicYtm.ready()", function(v) {
      if (v === "offline") root.noteOffline()
      else if (v === true) root.appOffline = false
      if (v === true || root.readyTries > 60 || !root.appUp) {
        var cbs = root.readyCallbacks
        root.readyCallbacks = []
        root.readyTries = 0
        if (v === true) { for (var i = 0; i < cbs.length; i++) cbs[i](); return }
        // Gave up (about 30 s), or the app went away. A play asked for now
        // must not fire on some later, unrelated start, where it would start
        // music out of nowhere. On pear's offline page the toast says that
        // instead. With the list empty, the list area already says it, so no
        // toast then: while it stays offline, each navigate back (every 10 s)
        // starts a new wait, and each wait would end in another toast.
        root.pendingAction = ""
        if (root.opened && root.appUp && !(root.appOffline && list.count === 0))
          root.toast(root.appOffline ? root.offlineText : "YouTube Music didn't finish loading.")
        return
      }
      root.readyTries += 1
      readyTimer.restart()
    })
  }
  Timer { id: readyTimer; interval: 500; onTriggered: root.readyCheck() }

  // Play what was asked for once the page is ready: the song that is already
  // the user's, or the remembered one, or (nothing remembered) Liked songs.
  function doPending() {
    var act = pendingAction
    pendingAction = ""
    if (act !== "play") return
    if (songReal && song && song.title) { cmd("/play"); lastPush = Date.now(); return }
    var ls = lastSong
    if (!ls || !ls.videoId) {
      // Which song Liked songs starts with is not known here, so any
      // VIDEO_CHANGED counts. Known gap: a restored cue's late VIDEO_CHANGED
      // can still show that cue as playing for a moment, until the first liked
      // song's own VIDEO_CHANGED replaces it (the dead-song playlist below has
      // the same gap). Nothing is remembered in this case, so no saved song is
      // at risk unless that second VIDEO_CHANGED never comes.
      expect("")
      page("window.__nicYtm.play(" + JSON.stringify({ watchPlaylistEndpoint: { playlistId: "LM" } }) + ")", function(v, err) {
        if (err || v === false) { root.unexpect(); root.toast(err || "The app is still loading. Try again in a moment.") }
      })
      return
    }
    // A removed or blocked song left the hidden player on an error screen, and
    // the bar kept offering it: every later play retried the same dead song.
    // Ask first (the app's own /player check, which starts nothing); a dead
    // song is dropped, and the rest of its playlist plays instead, unless that
    // playlist is an RDAMVM radio seeded by the dead song itself.
    page("window.__nicYtm.playable(" + JSON.stringify(ls.videoId) + ")", function(pv) {
      if (pv && pv.ok === false) {
        root.toast("“" + ls.title + "” isn't available any more.")
        root.forgetLast()
        if (ls.playlistId && !/^RDAMVM/.test(ls.playlistId)) {
          root.expect("")
          root.page("window.__nicYtm.play(" + JSON.stringify({ watchPlaylistEndpoint: { playlistId: ls.playlistId } }) + ")", function(v, err) {
            if (err || v === false) root.unexpect()
          })
        }
        return
      }
      var ep = { videoId: ls.videoId }
      if (ls.playlistId) ep.playlistId = ls.playlistId
      // Start at the saved second inside the endpoint itself. YouTube Music's
      // page honours watchEndpoint.startTimeSeconds (it seeks in place when
      // that song is already cued), so there is no seek race at VIDEO_CHANGED
      // and no leftover resume target to catch a later play of the same song.
      // Skipped in the first 5 s and within 10 s of the end, where it would
      // only roll into the next song.
      var at = Math.floor(Number(ls.elapsedSeconds || 0))
      var dur = Number(ls.songDuration || 0)
      if (at > 5 && (dur <= 0 || at < dur - 10)) {
        ep.startTimeSeconds = at
        // Fallback only: if the first push lands more than 5 s off within 20 s,
        // seek once (see POSITION_CHANGED).
        root.resumeTarget = { videoId: ls.videoId, at: at, until: Date.now() + 20000 }
      } else root.resumeTarget = null
      root.expect(ls.videoId)
      root.page("window.__nicYtm.play(" + JSON.stringify({ watchEndpoint: ep }) + ")", function(v, err) {
        if (err || v === false) {
          root.unexpect()
          root.resumeTarget = null
          root.toast("Couldn't resume: " + (err || "the app is still loading."))
        }
      })
    })
  }

  // Remember the song so the bar can show it and resume it after a quit. Only
  // a song that is really the user's, at the last position the app pushed.
  function saveLast() {
    if (!appUp || !songReal || !song || !song.title || !song.videoId) return
    var ls = {
      title: song.title, artist: song.artist || "", album: song.album || "",
      imageSrc: song.imageSrc || "", videoId: song.videoId, playlistId: song.playlistId || "",
      songDuration: Number(song.songDuration || 0), elapsedSeconds: Math.floor(reportedPosition)
    }
    lastSong = ls
    if (isPrimary()) lastFile.setText(JSON.stringify(ls, null, 2) + "\n")
  }
  // saveLast, but only once the page confirms its video is still this song.
  // A song picked in the app window itself (the widget did not start it)
  // pushes its time and play/pause events before its VIDEO_CHANGED arrives
  // (that waits for the cover download), so a pause right then saved the old
  // title with the new song's second: "Spirit @116" for Willing and Able at
  // 1:56 (live test, 2026-09-24). The VIDEO_CHANGED that follows saves the
  // right song instead. An unreachable page saves as before.
  function saveLastChecked() {
    var vid = song ? song.videoId : ""
    page("window.__nicYtm.state()", function(v) {
      if (!v || !v.videoId || (v.videoId === vid && root.song && root.song.videoId === vid)) root.saveLast()
    })
  }
  // Give every monitor's copy this remembered song (or null), and write it
  // once, through the first copy, which is the only one that writes the file.
  // For changes made by hand on one copy (a forget, a new resume point): the
  // other copies kept the old second, so a play from another monitor's bar
  // resumed there (offline test with two copies, 2026-09-24).
  function shareLast(ls) {
    var ps = peers()
    for (var i = 0; i < ps.length; i++) if (ps[i] && ps[i] !== root) ps[i].takeShared(ls)
    lastSong = ls
    primary().writeLast(ls ? JSON.stringify(ls, null, 2) + "\n" : "{}\n")
  }
  // Another copy changed the remembered song. Its seek bar shows the new second
  // too while the remembered song is what it shows.
  function takeShared(ls) {
    lastSong = ls
    if (ls && !showingLive) position = Number(ls.elapsedSeconds || 0)
  }
  function writeLast(t) { lastFile.setText(t) }
  // Drop the remembered song everywhere. "{}" is ignored on load, because it
  // has no title.
  function forgetLast() { shareLast(null) }
  function takeLast(t) {
    try {
      var v = JSON.parse(t)
      if (v && v.title) {
        root.lastSong = v
        if (!root.appUp) { root.position = Number(v.elapsedSeconds || 0); root.reportedPosition = root.position }
        return true
      }
    } catch (e) {}
    return false
  }
  FileView {
    id: lastFile
    path: root.stateDir + "/last.json"
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.takeLast(text())
    // Before 2026-09-24 the file sat at ~/.local/state/omarchy/nic-youtube-music-last.json
    // (see stateDir for why it moved). Read the old one once when the new one
    // is missing, and carry it over, so the remembered song survives the move.
    onLoadFailed: oldLastFile.path = Quickshell.env("HOME") + "/.local/state/omarchy/nic-youtube-music-last.json"
  }
  FileView {
    id: oldLastFile
    path: ""
    watchChanges: false
    printErrors: false
    onLoaded: if (root.takeLast(text()) && root.isPrimary()) lastFile.setText(text())
  }
  Timer {
    id: saveTimer
    interval: 15000
    repeat: true
    running: root.appUp && root.isPlaying && root.songReal
    onTriggered: root.saveLastChecked()
  }

  // Quit when idle. Counts only while paused, the panel is closed on every
  // monitor, and the app is not on screen.
  readonly property int idleLimit: (Number(setting("idleMinutes", 5)) || 5) * 60
  property int idleSeconds: 0
  // Whether the hidden "music" workspace (the app window) is on screen right
  // now, so the cover button can say "Hide app" instead of "Show app".
  // Kept live from Hyprland's activespecial event ("special:music,<monitor>",
  // or an empty name when hidden). Tracked per monitor: the event says what
  // one monitor shows, and hiding a special workspace on monitor B read as
  // "hidden" while the app was still up on monitor A (code review, 2026-09-24).
  property bool appShown: false
  property string activeClass: ""
  property var specialShown: ({})          // monitor name -> its special workspace
  function setSpecial(map) {
    specialShown = map
    var shown = false
    for (var k in map) if (map[k] === "special:music") shown = true
    appShown = shown
  }
  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "activespecial") {
        var d = String(event.data)
        var cut = d.indexOf(",")
        var m = Object.assign({}, root.specialShown)
        m[cut < 0 ? "" : d.slice(cut + 1)] = cut < 0 ? d : d.slice(0, cut)
        root.setSpecial(m)
      }
      // Started by hand (the launcher, or a terminal): look for its API now
      // instead of at the next 20 s probe. openwindow is
      // "ADDRESS,WORKSPACE,CLASS,TITLE"; the title may hold commas, the class not.
      else if (event.name === "activewindow") root.activeClass = String(event.data).split(",")[0]
      else if (event.name === "openwindow" && !root.appUp && String(event.data).split(",")[2] === root.appClass)
        root.probeSoon()
    }
  }
  // Ask Hyprland directly when the panel opens. Reading the cached
  // focusedMonitor.lastIpcObject gave the state from before the last toggle,
  // which swapped the Show/Hide label (reported 2026-09-24).
  function readAppShown() {
    if (!monitorsProc.running) monitorsProc.running = true
  }
  Process {
    id: monitorsProc
    command: ["hyprctl", "monitors", "-j"]
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var mons = JSON.parse(text)
          var m = {}
          for (var i = 0; i < mons.length; i++)
            m[mons[i].name] = mons[i].specialWorkspace ? String(mons[i].specialWorkspace.name || "") : ""
          root.setSpecial(m)
        } catch (e) {}
      }
    }
  }
  function appInFront() {
    // The focused window's class, kept from Hyprland's activewindow event.
    // Hyprland.activeToplevel.lastIpcObject is only filled for windows that
    // existed when the shell started, and this app is started later, on
    // demand, so its class read as "".
    if (activeClass === appClass) return true
    return root.appShown
  }
  Timer {
    id: idleTimer
    interval: 15000
    repeat: true
    running: root.appUp
    onTriggered: {
      var busy = root.isPlaying || root.anyCopyBusy() || root.appInFront()
      root.idleSeconds = busy ? 0 : root.idleSeconds + 15
      if (root.idleSeconds >= root.idleLimit && root.isPrimary()) { root.idleSeconds = 0; root.quitIfIdle() }
    }
  }
  // Last look before quitting. The play flag can be wrong the other way too:
  // the app never reports a play that starts at 0:00 (its renderer sends
  // play/pause only once currentTime rounds above 0), so a resume from the very
  // start (media key, or the app window) left the widget on "paused" while
  // music played. Never quit while the page's player plays. No answer means the
  // page is unreachable, and quitting is then right. The answer can take up to
  // 20 s on a hung page, so whatever happened meanwhile (a panel opened, play pressed,
  // play, brought the app forward) is checked again before quitting: that quit
  // still went ahead (offline test, 2026-09-24). A playing page goes
  // through applyPageState, which makes the song the user's only when the page's
  // video is that song.
  function quitIfIdle() {
    var ep = stateEpoch
    page("window.__nicYtm.state()", function(v) {
      // A play or pause happened while the answer was on its way: not idle.
      if (ep !== root.stateEpoch) { root.idleSeconds = 0; return }
      if (root.pagePlaying(v)) { root.applyPageState(v); root.idleSeconds = 0; return }
      if (root.isPlaying || root.anyCopyBusy() || root.appInFront()) { root.idleSeconds = 0; return }
      root.quitApp()
    })
  }
  function quitApp() {
    saveLast()
    var x = new XMLHttpRequest()
    x.onreadystatechange = function() {
      if (x.readyState !== XMLHttpRequest.DONE) return
      try {
        quitWs.url = JSON.parse(x.responseText).webSocketDebuggerUrl
        quitWs.active = true
      } catch (e) {}
    }
    x.open("GET", "http://127.0.0.1:9223/json/version")
    x.send()
  }
  WebSocket {
    id: quitWs
    active: false
    onStatusChanged: {
      if (quitWs.status === WebSocket.Open) quitWs.sendTextMessage(JSON.stringify({ id: 1, method: "Browser.close" }))
      else if (quitWs.status === WebSocket.Closed || quitWs.status === WebSocket.Error) quitWs.active = false
    }
  }
  // With nothing of the user's loaded, the seek bar moves the remembered song's
  // resume point instead (a /seek-to on an empty or cued player did nothing).
  function seekTo(sec) {
    root.position = sec
    if (showingLive) {
      root.reportedPosition = sec
      cmd("/seek-to", { seconds: Math.round(sec) })
      return
    }
    if (!hasLast()) return
    var ls = JSON.parse(JSON.stringify(lastSong))
    ls.elapsedSeconds = Math.round(sec)
    root.reportedPosition = ls.elapsedSeconds
    shareLast(ls)
  }
  // The app reports volume on another scale than it is set on: /volume 57
  // comes back as 26 in VOLUME_CHANGED and GET /volume (its player applies a
  // loudness curve). Taking that echo as the slider value made the knob drop
  // after every drag while the sound stayed where it was put (reported
  // 2026-09-24). root.volume stays in slider units: the echo of what we just
  // set keeps the exact position, echoes of values sent earlier in a drag
  // are ignored for a second, and any other change (the app window) is
  // turned back into slider units through the curve below. Measured
  // 2026-09-24 (sent -> reported); linear in between.
  readonly property var volCurve: [[0, 0], [5, 1], [10, 2], [15, 3], [20, 5], [25, 6], [30, 8], [35, 11],
    [40, 13], [45, 16], [50, 20], [55, 24], [60, 29], [65, 34], [70, 40], [75, 47], [80, 55], [85, 64],
    [90, 74], [95, 86], [100, 100]]
  function volCurveMap(x, from, to) {
    var c = volCurve
    for (var i = 1; i < c.length; i++) {
      if (x <= c[i][from]) {
        var a = c[i - 1], b = c[i], span = b[from] - a[from]
        return span > 0 ? a[to] + (x - a[from]) * (b[to] - a[to]) / span : b[to]
      }
    }
    return 100
  }
  property int volSent: -1
  property double volSentAt: 0
  function takeAppVolume(r) {
    if (volSent >= 0 && Math.abs(volCurveMap(volSent, 0, 1) - r) <= 1.5) { volume = volSent; return }
    if (Date.now() - volSentAt < 1000) return
    volSent = -1
    volume = Math.round(volCurveMap(r, 1, 0))
  }
  function setVolume(v) {
    root.volume = Math.round(v)
    root.volSent = root.volume
    root.volSentAt = Date.now()
    cmd("/volume", { volume: root.volume })
  }
  // At most one volume request per 150 ms while dragging, plus the final one
  // on release. Sending on every move posted about 30 requests per drag
  // (harness, 2026-09-24), and their late echoes could pull the knob back.
  Timer { id: volThrottle; interval: 150 }
  function toggleMute() { cmd("/toggle-mute") }
  function toggleShuffle() { cmd("/shuffle"); root.shuffle = !root.shuffle }
  function cycleRepeat() { cmd("/switch-repeat", { iteration: 1 }) }
  function like() { cmd("/like"); fetchLike() }
  function dislike() { cmd("/dislike"); fetchLike() }
  function fetchLike() {
    likeTimer.restart()
  }
  Timer {
    id: likeTimer
    interval: 400
    onTriggered: root.call("GET", "/like-state", null, function(s, d) {
      root.likeState = d && d.state ? d.state : "INDIFFERENT"
    })
  }
  function queueAdd(it, afterCurrent) {
    if (!it.videoId) return
    cmd("/queue", { videoId: it.videoId, insertPosition: afterCurrent ? "INSERT_AFTER_CURRENT_VIDEO" : "INSERT_AT_END" })
    toast((afterCurrent ? "Playing next: " : "Added to queue: ") + it.title)
    // Up next is on screen in every tab, not only Queue. The app adds the song
    // only after asking YouTube for it, so the queue poll is what finally
    // catches it; this just shows it sooner when the answer is quick.
    if (root.opened) queueTimer.restart()
  }
  // Queue rows are acted on inside the page by their queue id (Page.js
  // queueAct), never by a position remembered from the last load. Positions
  // go stale the moment anything is added, removed or shuffled, and the REST
  // /queue routes only take positions: a second quick remove hit the song
  // below the one clicked (checked offline against the live queue, 2026-09-24).
  // Used for queue rows and autoplay picks alike, in the Queue tab and Up next.
  function queueAct(op, it) {
    if (op === "jump") expect(it.videoId)
    page("window.__nicYtm.queueAct(" + JSON.stringify(op) + "," + Number(it.queueId) + ","
        + JSON.stringify(it.videoId || "") + "," + Number(it.queueIndex) + "," + (it.auto ? "true" : "false") + ")",
      function(v, err) {
        if (v !== true && op === "jump") root.unexpect()
        if (v === false) root.toast("That song is not in the queue any more.")
        else if (err) root.toast(err)
        root.loadQueue()
      })
  }

  // Both lists (Queue tab and Up next) come from ONE page snapshot, so they
  // always agree. The REST GET /queue sent every raw renderer (about 800 KB
  // for 50 songs), parsed here on the shell's UI thread, and knew nothing of
  // autoplay picks.
  function loadQueue() {
    queueSerial += 1
    var mine = queueSerial
    page("window.__nicYtm.queue(60)", function(v) {
      if (mine !== root.queueSerial || !v) return   // a newer load overtook this one
      // Keep both lists where they were: this runs on every song change and
      // every queue edit, and a new rows array put a list back at the top
      // (see keepY on the ListViews).
      var onQueue = root.view === "queue" && !root.searching && !root.currentPage
      var toNow = onQueue && root.queueScrollToNow
      if (onQueue && !toNow) list.keepY = list.contentY
      upList.keepY = upList.contentY
      root.queueItems = v.items || []
      root.upNext = v.upNext || []
      // See loadMore: a poll that changed only the autoplay picks or the
      // repeat mode can leave a list's rows equal, and keepY armed.
      list.keepY = -1
      upList.keepY = -1
      root.queueSig = v.sig || ""
      if (toNow) {
        root.queueScrollToNow = false
        // The Queue tab lists the whole queue, played songs first (like the
        // app). Open on the playing song, with one played song above it.
        list.forceLayout()
        for (var i = 0; i < root.rows.length; i++)
          if (root.rows[i].current) { list.positionViewAtIndex(Math.max(0, i - 1), ListView.Beginning); break }
      }
    })
  }
  Timer { id: queueTimer; interval: 350; onTriggered: root.loadQueue() }
  // The app's WebSocket has no queue event: autoplay picks arriving, radio
  // top-ups, shuffles, adds and edits made in the app window all change the
  // queue silently. While the panel is open, compare a small fingerprint every
  // 1.5 s and reload both lists only when it changed.
  Timer {
    id: queuePoll
    interval: 1500
    repeat: true
    running: root.opened && root.appUp
    onTriggered: root.page("window.__nicYtm.queueSig()", function(v) {
      if (typeof v === "string" && v !== root.queueSig) root.loadQueue()
    })
  }

  // ------------------------------------------------------------ live state socket
  readonly property string wsUrl: "ws://127.0.0.1:26538/api/v1/ws"
  WebSocket {
    id: live
    // url is set by probe(), not bound. The token file loads a moment after
    // the shell starts, and a bound url that changes on an open socket makes
    // it reconnect (QQmlWebSocket::setUrl reopens an active socket), which
    // runs the whole disconnect reset. Each probe takes the token as it is.
    active: false
    onStatusChanged: {
      if (live.status === WebSocket.Open) {
        // Not "up" yet. With the app's auth on and a missing or stale token,
        // the app accepts the socket and then closes it at once (1008,
        // api-server onOpen). Marking the app up here made every such
        // connect take the "app went away" path, and the retry timer's
        // triggeredOnStart probed again at once: a tight reconnect loop (a
        // fake server that closes like the app counted 281 connects in 3 s,
        // 2026-09-24; 1 with this change). The app sends PLAYER_INFO only once
        // auth has passed, so the first message marks it up (markUp, in
        // onTextMessageReceived).
      } else if (live.status === WebSocket.Closed || live.status === WebSocket.Error) {
        var wasUp = root.appUp
        if (wasUp) {
          root.saveLast()
          root.appUp = false
          root.isPlaying = false
          root.song = null
          root.songReal = false
          root.expectSong = false
          root.resumeTarget = null
          root.appOffline = false
          root.queueItems = []
          root.upNext = []
          root.queueSig = ""
          root.position = root.lastSong ? Number(root.lastSong.elapsedSeconds || 0) : 0
          root.reportedPosition = root.position
        }
        active = false
        // No retry.restart() here. This handler runs outside the timer's own
        // tick, and restart() re-arms triggeredOnStart, so every refused
        // connect queued the next one at once: about 44,000 connects a second
        // and a full CPU core whenever the app was closed (measured
        // 2026-09-24, 64 s of CPU in 90 s after an idle quit). The running
        // binding (!appUp) already starts the timer when the app goes away.
      }
    }
    onTextMessageReceived: function(message) {
      var m
      try { m = JSON.parse(message) } catch (e) { return }
      // Any message means auth passed (PLAYER_INFO is always the first).
      if (!root.appUp) root.markUp()
      var now = Date.now()
      if (m.type === "PLAYER_INFO") {
        // Sent once on connect. Its isPlaying comes from the app's isPaused,
        // which the app sets to false for every newly loaded song, cue or not.
        // Only a song already past 0:00 is taken as really played; the page
        // check 1.5 s later settles the rest.
        var pi = Number(m.position || 0)
        root.song = m.song || null
        root.songReal = pi > 0
        root.isPlaying = root.songReal && !!m.isPlaying
        if (root.songReal || !root.lastSong) root.position = pi
        if (root.songReal) root.reportedPosition = pi
        root.posPushPos = pi
        root.posPushAt = 0
        if (m.volume !== undefined) root.takeAppVolume(Number(m.volume))
        root.muted = !!m.muted
        if (m.repeat) root.repeatMode = m.repeat
        root.shuffle = !!m.shuffle
        root.lastPush = now
        confirmTimer.restart()
      } else if (m.type === "VIDEO_CHANGED") {
        // A new song counts as the user's when the last one was really playing (an
        // autoplay step; the app pauses at a song's end just before this) or
        // when the widget started it. Otherwise it is a cue until it plays.
        // "Started it" means the video the widget asked for, when it knows
        // which: the restored cue's own VIDEO_CHANGED can land after the
        // resume was asked for (it waits for the cue's data and cover, while
        // ready() only waits for the player), and it took the expectation and
        // showed the cue as playing, the "Meet Me Halfway" bug again
        // (offline test, 2026-09-24). A VIDEO_CHANGED for another
        // video leaves the wait for its own song; expectTimer ends it.
        var wasReal = root.songReal && (root.isPlaying || now - root.stoppedPlayingAt < 5000)
        var vid = m.song ? String(m.song.videoId || "") : ""
        var mine = root.expectSong && (root.expectVideo === "" || vid === root.expectVideo)
        root.songReal = wasReal || mine
        if (mine) root.expectSong = false
        root.song = m.song || null
        var rt = root.resumeTarget
        var resumed = !!rt && !!m.song && m.song.videoId === rt.videoId
        // VIDEO_CHANGED always says position 0, even for a resume that starts
        // at its saved second; show and keep that second instead.
        if (root.songReal || !root.lastSong) root.position = resumed ? rt.at : Number(m.position || 0)
        if (root.songReal) root.reportedPosition = root.position
        root.posPushPos = root.position
        root.posPushAt = 0
        // The app sends isPaused false for every new song; only a real one
        // may show as playing, and the page check below corrects it.
        if (m.song) root.isPlaying = root.songReal && !m.song.isPaused
        // A real song change is remembered at once (see saveLastChecked for
        // the mislabelled save this also corrects).
        if (root.songReal) root.saveLast()
        root.fetchLike()
        if (root.opened) queueTimer.restart()
        root.lastPush = now
        confirmTimer.restart()
      } else if (m.type === "PLAYER_STATE_CHANGED") {
        // Real play and pause events (only once past 0:00), and the app's
        // own last word when it quits (paused, at the real second).
        var ps = m.position !== undefined ? Number(m.position) : -1
        root.stateEpoch += 1
        if (!m.isPlaying) root.pausedAt = now
        if (ps > 0 && !root.incomingSong()) root.songReal = true
        // While presses are being merged the icon shows the wished-for state (ppTarget);
        // the settle check puts the page's own state back afterwards.
        root.isPlaying = root.ppTarget >= 0 ? root.ppTarget === 1 : (root.songReal && !!m.isPlaying)
        if (ps >= 0 && (root.songReal || !root.lastSong)) root.position = ps
        if (ps >= 0 && root.songReal) root.reportedPosition = ps
        root.lastPush = now
        if (!root.isPlaying) root.saveLastChecked()
        if (root.lyricsLive) root.syncLyricsClock()
      } else if (m.type === "POSITION_CHANGED") {
        var p = Number(m.position || 0)
        // Two pushes in a row that move forward by up to 2.5 s within 2.5 s
        // prove the song plays. This is the only sign of a play that started
        // at 0:00 (the app never reports one), which otherwise stayed "paused".
        var moving = p > root.posPushPos && p - root.posPushPos <= 2.5 && now - root.posPushAt < 2500
          && now - root.pausedAt > 3000
        root.posPushPos = p
        root.posPushAt = now
        root.lastPush = now
        // Past 0:00 means it played or was moved: the user's song now (unless the
        // push is for a song on its way, see incomingSong).
        if (p > 0 && !root.incomingSong()) root.songReal = true
        if (moving && root.ppTarget < 0) root.isPlaying = true
        if (root.songReal || !root.lastSong) root.position = p
        if (root.songReal) root.reportedPosition = p
        // The resume's one fallback seek, for when startTimeSeconds was not
        // honoured: only on the first push of that song, only within 20 s, and
        // only when more than 5 s off. Sent to the app directly, not through
        // seekTo(): when the cue already was the remembered song and the first
        // push said 0:00, the song was not the user's yet, so seekTo() only moved the
        // remembered second and the song played from the start (offline
        // test, 2026-09-24).
        var target = root.resumeTarget
        if (target && root.song && root.song.videoId === target.videoId) {
          root.resumeTarget = null
          if (now < target.until && Math.abs(p - target.at) > 5) {
            root.position = target.at
            root.reportedPosition = target.at
            root.cmd("/seek-to", { seconds: target.at })
          }
        } else if (target && now >= target.until) root.resumeTarget = null
      } else if (m.type === "VOLUME_CHANGED") {
        root.takeAppVolume(Number(m.volume))
        root.muted = !!m.muted
      } else if (m.type === "REPEAT_CHANGED") {
        root.repeatMode = m.repeat
      } else if (m.type === "SHUFFLE_CHANGED") {
        root.shuffle = !!m.shuffle
        // Shuffle reorders the queue itself (the playing song moves to the top).
        if (root.opened) queueTimer.restart()
      }
    }
  }
  // Reconnect quietly: every second while the app is starting (so play starts
  // as soon as its API is up), every 4 s while the panel is open, every 20 s
  // otherwise. A refused localhost connect costs next to nothing. When appUp
  // goes false, triggeredOnStart gives exactly one probe at once.
  Timer {
    id: retry
    interval: root.starting ? 1000 : (root.opened ? 4000 : 20000)
    running: !root.appUp
    repeat: true
    triggeredOnStart: true
    onTriggered: root.probe()
  }
  // The app's API answered (see the socket's Open branch for why not sooner).
  function markUp() {
    appUp = true
    starting = false
    startFailed = false
    idleSeconds = 0
    startTimeout.stop()
    handProbe.stop()
    fetchLike()
    whenReady(function() {
      root.doPending()
      if (root.opened) root.refresh()
    })
  }
  function probe() {
    // A token file written while the shell runs (nic-ytm-lock) is not always
    // seen by the watch, so look again on each probe while there is none.
    if (!apiToken) tokenFile.reload()
    if (live.status === WebSocket.Open || live.status === WebSocket.Connecting) return
    live.active = false
    live.url = root.wsUrl + (root.apiToken ? "?token=" + encodeURIComponent(root.apiToken) : "")
    live.active = true
  }
  // The app was started by hand: probe every second for 20 s, since its API
  // comes up a moment after its window.
  function probeSoon() {
    probe()
    handProbe.triesLeft = 20
    handProbe.restart()
  }
  Timer {
    id: handProbe
    // Not "left": that is the now-playing column's id, which wins the lookup.
    property int triesLeft: 0
    interval: 1000
    repeat: true
    onTriggered: {
      handProbe.triesLeft -= 1
      if (root.appUp || handProbe.triesLeft <= 0) handProbe.stop()
      else root.probe()
    }
  }
  // Smooth the seek bar between the app's once-a-second position pushes. Only
  // while the panel shows it and the pushes are fresh: without that it ran on
  // to the song's end in silence when the pushes stopped.
  Timer {
    id: smoothTimer
    interval: 250
    repeat: true
    running: root.isPlaying && root.appUp && root.songReal && root.opened
    onTriggered: if (Date.now() - root.lastPush < 2000 && (root.duration <= 0 || root.position < root.duration)) root.position += 0.25
  }

  // Ask the page what the player really does, and believe it. See the header
  // comment for why the app's own flag cannot be trusted.
  // No answer can also mean pear's offline page, which state() cannot read:
  // the stall check is often the first to meet it (see checkOffline).
  function checkPlayState() {
    if (!appUp) return
    var ep = stateEpoch
    page("window.__nicYtm.state()", function(v) {
      // Stale: a play or pause happened after this was asked (see stateEpoch).
      if (!root.appUp || ep !== root.stateEpoch) return
      root.applyPageState(v)
      if (!v) root.checkOffline()
    })
  }
  function applyPageState(v) {
    root.lastPush = Date.now()
    // The page may already hold the next video while song, from the app's
    // VIDEO_CHANGED, is still the last one; its time is not that song's. With
    // no song yet, nothing is known to match: a null song counted as a match
    // and made songReal true, which the cue's late VIDEO_CHANGED then
    // inherited (offline test, 2026-09-24).
    var same = !v || (!!root.song && (!v.videoId || v.videoId === root.song.videoId))
    if (root.pagePlaying(v)) {
      root.isPlaying = true
      if (!same) return
      // Whatever plays is the user's, whoever started it.
      var was = root.songReal
      root.songReal = true
      root.position = Number(v.t || 0)
      root.reportedPosition = root.position
      // Saved only when this check made the song the user's. While the pushes are
      // stopped the stall check lands here every 3 s, and saving each time
      // rewrote the state file every 3 s; saveTimer saves every 15 s anyway.
      if (!was) root.saveLast()
      return
    }
    // Not playing, or the page is unreachable: not playing.
    root.isPlaying = false
    if (!v || !root.songReal || !same) return
    // A resume still on its way keeps its second; 0 is only the load.
    var rt = root.resumeTarget
    if (rt && root.song && rt.videoId === root.song.videoId && Number(v.t || 0) < 1) return
    root.position = Number(v.t || 0)
    root.reportedPosition = root.position
  }
  // 1.5 s after PLAYER_INFO or VIDEO_CHANGED: the app may send the song
  // change up to 1.5 s after the load, and it has claimed "playing" for it.
  Timer { id: confirmTimer; interval: 1500; onTriggered: root.whenReady(root.checkPlayState) }
  // While "playing", the app pushes the position every second. When that
  // stops (a stalled stream, blocked autoplay, a dead renderer), ask the page.
  Timer {
    id: stallTimer
    interval: 3000
    repeat: true
    running: root.appUp && root.isPlaying
    onTriggered: if (Date.now() - root.lastPush >= 2500) root.checkPlayState()
  }

  // ------------------------------------------------------------ page bridge (CDP)
  property int cdpId: 0
  property var cdpPending: ({})
  // A call that never answers (a fetch stuck on a dead connection) left
  // "Loading…" up for good. Each call gets 20 s, then fails like a closed socket.
  property var cdpDeadline: ({})
  property var cdpQueue: []                // [{id, msg, offlineOk}] waiting for the socket
  property bool cdpLooking: false
  // pear swaps in its own offline page (assets/error.html) whenever a page
  // load fails (index.js did-fail-load, which does not even check for the main
  // frame). Its Retry reloads only the FOCUSED window, and ours sits hidden on
  // special:music, so the widget points the page back at YouTube Music itself.
  property bool appOffline: false
  property double lastPageRetry: 0
  readonly property string offlineText: "YouTube Music couldn't load. Check the internet connection."

  function cdpFailOne(id, err) {
    var cb = cdpPending[id]
    delete cdpPending[id]
    delete cdpDeadline[id]
    if (cb) cb(null, err)
  }
  function cdpFail(err) {
    var p = cdpPending
    cdpPending = ({})
    cdpDeadline = ({})
    // Drop the queued commands too. Their callbacks are told they failed, and
    // replaying them on the next connect would run a stale play.
    cdpQueue = []
    for (var k in p) p[k](null, err)
  }
  WebSocket {
    id: cdp
    active: false
    onStatusChanged: {
      if (cdp.status === WebSocket.Open) {
        var q = root.cdpQueue
        root.cdpQueue = []
        for (var i = 0; i < q.length; i++) cdp.sendTextMessage(q[i].msg)
      } else if (cdp.status === WebSocket.Closed || cdp.status === WebSocket.Error) {
        active = false
        root.cdpFail("The YouTube Music page is not reachable.")
      }
    }
    onTextMessageReceived: function(message) {
      var m
      try { m = JSON.parse(message) } catch (e) { return }
      var cb = root.cdpPending[m.id]
      if (!cb) return
      delete root.cdpPending[m.id]
      delete root.cdpDeadline[m.id]
      // Show a plain sentence, never a V8 stack trace (the description is
      // several lines of "TypeError … at <anonymous>:147"). The raw text goes
      // to the shell log.
      if (m.result && m.result.exceptionDetails) {
        console.warn("nic.youtube-music page error:", JSON.stringify(m.result.exceptionDetails.exception || m.result.exceptionDetails).slice(0, 2000))
        cb(null, "The YouTube Music app had a problem with that. Try again.")
      } else if (m.result && m.result.result) cb(m.result.result.value, "")
      else if (m.result && !m.error) cb(m.result, "")          // Page.navigate answers {frameId, ...}
      else {
        console.warn("nic.youtube-music page error:", JSON.stringify(m.error || m).slice(0, 2000))
        cb(null, "The YouTube Music page did not answer. Try again.", m.error ? String(m.error.message || "") : "")
      }
    }
  }
  Timer {
    id: cdpSweep
    interval: 5000
    repeat: true
    running: root.appUp
    onTriggered: {
      var now = Date.now()
      var late = []
      for (var k in root.cdpDeadline) if (root.cdpDeadline[k] < now) late.push(Number(k))
      if (!late.length) return
      root.cdpQueue = root.cdpQueue.filter(function(q) { return late.indexOf(q.id) < 0 })
      for (var i = 0; i < late.length; i++) root.cdpFailOne(late[i], "YouTube Music did not answer. Try again.")
    }
  }
  // Send one CDP command to the YouTube Music page. offlineOk marks the one
  // command that may go to pear's offline page instead (the navigate back).
  function cdpSend(method, params, cb, offlineOk) {
    root.cdpId += 1
    var id = root.cdpId
    root.cdpPending[id] = cb || function() {}
    root.cdpDeadline[id] = Date.now() + 20000
    var msg = JSON.stringify({ id: id, method: method, params: params })
    if (cdp.status === WebSocket.Open) { cdp.sendTextMessage(msg); return }
    root.cdpQueue = root.cdpQueue.concat([{ id: id, msg: msg, offlineOk: !!offlineOk }])
    if (cdp.status === WebSocket.Connecting || root.cdpLooking) return
    root.cdpLooking = true
    var x = new XMLHttpRequest()
    x.onreadystatechange = function() {
      if (x.readyState !== XMLHttpRequest.DONE) return
      root.cdpLooking = false
      var list = []
      try { list = JSON.parse(x.responseText) } catch (e) {}
      var target = null, offline = null
      for (var i = 0; i < list.length; i++) {
        if (list[i].type !== "page") continue
        if (String(list[i].url).indexOf("music.youtube.com") !== -1) target = list[i]
        else if (/\/assets\/error\.html$/.test(String(list[i].url))) offline = list[i]
      }
      if (target) {
        cdp.url = target.webSocketDebuggerUrl
        cdp.active = true
        return
      }
      if (offline) {
        root.appOffline = true
        var keep = root.cdpQueue.filter(function(q) { return q.offlineOk })
        var drop = root.cdpQueue.filter(function(q) { return !q.offlineOk })
        root.cdpQueue = keep
        for (var j = 0; j < drop.length; j++) root.cdpFailOne(drop[j].id, root.offlineText)
        if (keep.length) { cdp.url = offline.webSocketDebuggerUrl; cdp.active = true }
        else root.retryAppPage()
        return
      }
      root.cdpFail("The app is not showing YouTube Music (still signing in?)")
    }
    x.open("GET", root.cdpList)
    x.send()
  }
  function page(expr, cb, retried) {
    cb = root.pageAnswer(cb, expr, !!retried)
    // The length of SOURCE rides along: the page reinstalls its helper when it
    // changed (an edited Page.js), without an app restart. See Page.js.
    cdpSend("Runtime.evaluate", { expression: "window.__nicYtmLen=" + Page.SOURCE.length + ";\n" + Page.SOURCE + ";\n" + expr,
      awaitPromise: true, returnByValue: true }, cb, false)
  }
  // Every page answer passes here first. Page.js answers offlineText (the
  // same sentence, see safe() there) only on pear's offline page, so any list
  // load that meets it also starts the way back (noteOffline).
  function pageAnswer(cb, expr, retried) {
    return function(v, err, raw) {
      // Right after the app starts, the page swaps its JS context once more
      // after it looks ready, and a call that lands then fails with "Cannot
      // find default execution context" without having run at all (seen
      // 2026-09-24 18:07 and 18:51). A resume or play hit by it failed with a
      // toast. Such a call is safe to repeat, so it goes again once, 0.5 s later.
      if (!retried && raw && /Cannot find default execution context/i.test(raw)) {
        root.pageRetries = root.pageRetries.concat([{ expr: expr, cb: cb }])
        pageRetryLater.restart()
        return
      }
      if (v && v.error === root.offlineText) root.noteOffline()
      if (cb) cb(v, err)
    }
  }
  property var pageRetries: []
  Timer {
    id: pageRetryLater
    interval: 500
    onTriggered: {
      var q = root.pageRetries
      root.pageRetries = []
      for (var i = 0; i < q.length; i++) root.page(q[i].expr, q[i].cb, true)
    }
  }
  // pear's offline page, met mid-session. The CDP socket stays attached to the
  // app's page when pear loads error.html into it, so page() goes straight
  // there and the /json lookup that spots it never runs: the panel showed the
  // offline sentence, but nothing pointed the page back, and it stayed offline
  // until the idle quit (offline tests, 2026-09-24).
  function noteOffline() {
    appOffline = true
    retryAppPage()
  }
  function checkOffline() {
    page("window.__nicYtm.ready()", function(v) {
      if (v === "offline") root.noteOffline()
      else if (v === true) root.appOffline = false
    })
  }
  // Point the page back at YouTube Music: at most once every 10 s, and only
  // while someone is looking (panel open) or a play is waiting. The error page
  // is a file:// page, so CDP's Page.navigate works on it whatever has focus.
  function retryAppPage() {
    if (!appUp || !(opened || pendingAction !== "") || Date.now() - lastPageRetry < 10000) return
    lastPageRetry = Date.now()
    cdpSend("Page.navigate", { url: "https://music.youtube.com/" }, function(v, err) {
      if (err) return
      root.whenReady(function() {
        root.doPending()
        if (root.opened) root.refresh()
      })
    }, true)
  }
  Timer {
    id: pageRetryTimer
    interval: 10000
    repeat: true
    running: root.appUp && root.appOffline && (root.opened || root.pendingAction !== "")
    onTriggered: root.retryAppPage()
  }

  // Reads searchText itself, not the searching binding: clearing the search
  // calls this from onSearchTextChanged, where Qt 6.11 still hands back the
  // old value of a binding on searchText (the handler runs before the binding
  // updates). It saw "still searching", ran an empty search that did nothing,
  // and Home never came back (offline test through the keyboard, 2026-09-24;
  // the same trap as in World Radio's memory note).
  // ------------------------------------------------------------ lyrics
  // Asked for 2026-09-24: lyrics "as good as Apple Music does", and then for
  // them to follow each word. Word timing comes from KuGou (see kugouLookup),
  // timed lines from LRCLIB (lrclib.net, free and keyless; the app's own
  // synced-lyrics plugin uses it too). Each receives the song's title, artist
  // and length (LRCLIB the album too), nothing else. Without either, YouTube
  // Music's own plain lyrics (Musixmatch or LyricFind) show instead. Fetched
  // only while the Lyrics tab is on screen, and kept per song for this session.
  property var lyricLines: []          // [{t: seconds (-1 = plain), text, words?}]
  property bool lyricsSynced: false
  property bool lyricsWords: false     // the lines carry word timing
  property string lyricsSource: ""
  property string lyricsState: ""      // "", loading, ready, none, nosong
  property string lyricsFor: ""
  property var lyricsCache: ({})
  property int lyricsSerial: 0
  property int lyricIndex: -1
  property var lyricsXhrs: []
  readonly property string lyricsKey: hasSong && shownSong.videoId ? String(shownSong.videoId) : ""
  onLyricsKeyChanged: if (opened && view === "lyrics" && !searching && !currentPage) loadLyrics()

  function loadLyrics() {
    var ss = shownSong
    if (!hasSong || !ss.videoId) { lyricsFor = ""; lyricsState = "nosong"; lyricLines = []; lyricIndex = -1; return }
    var vid = String(ss.videoId)
    if (vid === lyricsFor && (lyricsState === "loading" || lyricsState === "ready" || lyricsState === "none")) return
    lyricsFor = vid
    lyricIndex = -1
    if (lyricsCache[vid]) { applyLyrics(lyricsCache[vid]); return }
    lyricsSerial += 1
    var mine = lyricsSerial
    lyricsState = "loading"
    lyricLines = []
    var done = function(res) {
      if (mine !== root.lyricsSerial) return
      var c = root.lyricsCache
      c[vid] = res
      root.lyricsCache = c
      root.applyLyrics(res)
    }
    // KuGou and LRCLIB are asked at the same time (KuGou's two steps take
    // about 1.3 s, LRCLIB about 0.2 s). KuGou's word timing wins; LRCLIB
    // lends it punctuation, checks its timing, and is the fallback.
    var got = {}
    var settle = function() {
      if (mine !== root.lyricsSerial || got.lr === undefined || got.kg === undefined) return
      var lr = got.lr, words = null
      try { words = got.kg ? root.polishKrc(got.kg, lr && lr.synced ? lr.lines : null) : null }
      catch (e) { console.warn("nic.youtube-music: KuGou lyrics unusable:", e) }
      if (words) { done({ synced: true, words: true, lines: words, source: "KuGou" }); return }
      if (lr && lr.synced) { done(lr); return }
      if (!root.appUp) { done(lr || { none: true }); return }
      root.page("window.__nicYtm.lyrics(" + JSON.stringify(vid) + ")", function(y) {
        if (y && y.text) done({ synced: false, lines: root.plainLines(y.text), source: y.source || "YouTube Music" })
        else done(lr || { none: true })
      })
    }
    lrclibLookup(ss, function(lr) { got.lr = lr || null; settle() })
    kugouLookup(ss, function(kg) { got.kg = kg || null; settle() })
  }
  function applyLyrics(res) {
    lyricLines = res && res.lines ? res.lines : []
    lyricsSynced = !!(res && res.synced)
    lyricsWords = !!(res && res.words)
    lyricsSource = res && res.source ? res.source : ""
    lyricsState = lyricLines.length ? "ready" : "none"
    lyricIndex = -1
    if (lyricsSynced) syncLyricsClock()
  }
  function plainLines(t) {
    var out = []
    var ls = String(t).split("\n")
    for (var i = 0; i < ls.length; i++) out.push({ t: -1, text: ls[i].trim() })
    return out
  }
  // LRC: "[mm:ss.xx] text", sometimes several stamps on one line. Empty lines
  // are instrumental breaks (shown as breathing dots), and so is the wait
  // before the first line.
  function parseLrc(t) {
    var out = []
    var ls = String(t).split("\n")
    for (var i = 0; i < ls.length; i++) {
      var line = ls[i]
      var stamps = []
      var m, re = /\[(\d+):(\d+(?:\.\d+)?)\]/g
      var last = 0
      while ((m = re.exec(line)) !== null) { stamps.push(Number(m[1]) * 60 + Number(m[2])); last = re.lastIndex }
      if (!stamps.length) continue
      var txt = line.slice(last).trim()
      for (var j = 0; j < stamps.length; j++) out.push({ t: stamps[j], text: txt })
    }
    out.sort(function(a, b) { return a.t - b.t })
    if (out.length && out[0].t > 3) out.unshift({ t: 0, text: "" })
    return out
  }
  // ---- word timing (KuGou) ----
  // Asked for 2026-09-24: make the lyrics follow each word. LRCLIB only times
  // whole lines, Musixmatch's free token is dead (all zeros) and Better
  // Lyrics' server wants a browser check. KuGou's lyrics service answers
  // without a key and times every word (tested: 8 of 8 songs from a real queue
  // and the charts). It receives the song's title, first artist and length.
  // Its lyrics come as base64 of a 4-byte "krc1" tag and then a zlib stream
  // XORed with a fixed 16-byte key, the format open lyrics tools read
  // (LyricsX, LDDC). There is no zlib in the shell's JS, so inflate() below
  // is a small port of zlib's puff.c. All of it runs only when a song's
  // lyrics are fetched, never at load (see Page.js on why that matters).
  function kugouLookup(ss, cb) {
    var enc = encodeURIComponent
    var title = String(ss.title || "")
    var clean = title.replace(/\s*[\(\[](feat\.?|ft\.?|with)[^\)\]]*[\)\]]/ig, "").trim()
    var first = String(ss.artist || "").split(/\s*(?:,|&| x | feat\.? | ft\.? )\s*/i)[0]
    var dur = Math.round(Number(ss.songDuration || 0))
    if (!clean || !first) { cb(null); return }
    lyricsGet("https://krcs.kugou.com/search?ver=1&man=yes&client=mobi&keyword=" + enc(first + " - " + clean)
      + "&duration=" + (dur * 1000) + "&hash=", function(d) {
        // Only a candidate with the same title and artist and a length within
        // 3 s: a wrong song's words are worse than LRCLIB's lines.
        var best = null, cs = d && d.candidates ? d.candidates : []
        for (var i = 0; i < cs.length; i++) {
          var c = cs[i]
          var off = dur > 0 ? Math.abs(Number(c.duration || 0) / 1000 - dur) : 0
          if (off > 3 || !c.id || !c.accesskey) continue
          if (!root.sameName(c.song, clean) || !root.sameName(c.singer, first)) continue
          if (!best || off < best.off) best = { off: off, c: c }
        }
        if (!best) { cb(null); return }
        root.lyricsGet("https://lyrics.kugou.com/download?ver=1&client=pc&fmt=krc&charset=utf8&id=" + enc(best.c.id)
          + "&accesskey=" + enc(best.c.accesskey), function(x) {
            var lines = null
            try {
              if (x && x.content) lines = root.parseKrc(root.krcText(x.content), clean, first)
            } catch (e) { console.warn("nic.youtube-music: KuGou lyrics unreadable:", e) }
            cb(lines)
          })
      })
  }
  // Loose name match: case, accents, spaces and punctuation ignored, either
  // one inside the other ("Too Sweet" and "Too Sweet (Live)" match).
  function nameKey(s) {
    return String(s || "").toLowerCase().normalize("NFD").replace(/[\u0300-\u036f]/g, "").replace(/[\s.,!?'"’‘“”()\[\]{}\-–—_:;&\/\\…~*+]+/g, "")
  }
  function sameName(a, b) {
    var x = nameKey(a), y = nameKey(b)
    return x !== "" && y !== "" && (x.indexOf(y) >= 0 || y.indexOf(x) >= 0)
  }
  function krcText(b64) {
    var key = [0x40, 0x47, 0x61, 0x77, 0x5e, 0x32, 0x74, 0x47, 0x51, 0x36, 0x31, 0x2d, 0xce, 0xd2, 0x6e, 0x69]
    var raw = base64Bytes(b64)
    if (raw.length < 8) return ""
    var z = new Uint8Array(raw.length - 4)
    for (var i = 0; i < z.length; i++) z[i] = raw[i + 4] ^ key[i % 16]
    return utf8Text(inflate(z, 2))   // 2: skip the zlib header
  }
  function base64Bytes(s) {
    var abc = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    var val = new Int16Array(128)
    val.fill(-1)
    for (var i = 0; i < 64; i++) val[abc.charCodeAt(i)] = i
    var out = new Uint8Array(Math.floor(s.length * 3 / 4) + 3), n = 0, acc = 0, bits = 0
    for (var j = 0; j < s.length; j++) {
      var c = s.charCodeAt(j), v = c < 128 ? val[c] : -1
      if (v < 0) continue
      acc = ((acc << 6) | v) & 0xffffff
      bits += 6
      if (bits >= 8) { bits -= 8; out[n++] = (acc >> bits) & 255 }
    }
    return out.subarray(0, n)
  }
  function utf8Text(b) {
    var parts = [], chunk = []
    for (var i = 0; i < b.length;) {
      var c = b[i++], cp
      if (c < 0x80) cp = c
      else if (c < 0xe0) cp = ((c & 0x1f) << 6) | (b[i++] & 0x3f)
      else if (c < 0xf0) { cp = ((c & 0x0f) << 12) | ((b[i] & 0x3f) << 6) | (b[i + 1] & 0x3f); i += 2 }
      else { cp = ((c & 0x07) << 18) | ((b[i] & 0x3f) << 12) | ((b[i + 1] & 0x3f) << 6) | (b[i + 2] & 0x3f); i += 3 }
      if (cp > 0xffff) { cp -= 0x10000; chunk.push(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff)) }
      else chunk.push(cp)
      if (chunk.length >= 4096) { parts.push(String.fromCharCode.apply(null, chunk)); chunk = [] }
    }
    parts.push(String.fromCharCode.apply(null, chunk))
    return parts.join("").replace(/^﻿/, "")
  }
  // Raw DEFLATE (RFC 1951) from byte pos of src, the way zlib's puff.c does
  // it: one bit at a time, slow but tiny, and a song's lyrics are about 20 KB.
  function inflate(src, pos) {
    var out = [], bitbuf = 0, bitcnt = 0
    var LBASE = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    var LEXT = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    var DBASE = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073,
      4097, 6145, 8193, 12289, 16385, 24577]
    var DEXT = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]
    var bits = function(n) {
      while (bitcnt < n) {
        if (pos >= src.length) throw new Error("inflate: data ends early")
        bitbuf |= src[pos++] << bitcnt
        bitcnt += 8
      }
      var v = bitbuf & ((1 << n) - 1)
      bitbuf >>>= n
      bitcnt -= n
      return v
    }
    // Canonical Huffman table from code lengths: how many codes of each
    // length, and the symbols in code order.
    var table = function(lengths) {
      var count = [], offs = [], symbol = []
      for (var l = 0; l < 16; l++) { count.push(0); offs.push(0) }
      for (var s = 0; s < lengths.length; s++) count[lengths[s]]++
      for (l = 1; l < 15; l++) offs[l + 1] = offs[l] + count[l]
      for (s = 0; s < lengths.length; s++) if (lengths[s]) symbol[offs[lengths[s]]++] = s
      return { count: count, symbol: symbol }
    }
    var decode = function(h) {
      var code = 0, first = 0, index = 0
      for (var len = 1; len < 16; len++) {
        code |= bits(1)
        var n = h.count[len]
        if (code - n < first) return h.symbol[index + (code - first)]
        index += n
        first = (first + n) << 1
        code <<= 1
      }
      throw new Error("inflate: bad code")
    }
    var codes = function(lencode, distcode) {
      for (;;) {
        var sym = decode(lencode)
        if (sym < 256) { out.push(sym); continue }
        if (sym === 256) return
        sym -= 257
        if (sym >= 29) throw new Error("inflate: bad length")
        var len = LBASE[sym] + bits(LEXT[sym])
        var ds = decode(distcode)
        if (ds >= 30) throw new Error("inflate: bad distance")
        var from = out.length - DBASE[ds] - bits(DEXT[ds])
        if (from < 0) throw new Error("inflate: distance too far")
        for (var k = 0; k < len; k++) out.push(out[from + k])
      }
    }
    var i, last
    do {
      last = bits(1)
      var type = bits(2)
      if (type === 0) {
        bitbuf = 0
        bitcnt = 0
        if (pos + 4 > src.length) throw new Error("inflate: data ends early")
        var n = src[pos] | (src[pos + 1] << 8)
        pos += 4
        if (pos + n > src.length) throw new Error("inflate: data ends early")
        for (i = 0; i < n; i++) out.push(src[pos++])
      } else if (type === 1) {
        var fl = [], fd = []
        for (i = 0; i < 288; i++) fl.push(i < 144 ? 8 : i < 256 ? 9 : i < 280 ? 7 : 8)
        for (i = 0; i < 30; i++) fd.push(5)
        codes(table(fl), table(fd))
      } else if (type === 2) {
        var nlen = bits(5) + 257, ndist = bits(5) + 1, ncode = bits(4) + 4
        var order = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]
        var lengths = []
        for (i = 0; i < 19; i++) lengths.push(0)
        for (i = 0; i < ncode; i++) lengths[order[i]] = bits(3)
        var lencode = table(lengths)
        lengths = []
        while (lengths.length < nlen + ndist) {
          var sym = decode(lencode)
          if (sym < 16) { lengths.push(sym); continue }
          var prev = 0, rep
          if (sym === 16) {
            if (!lengths.length) throw new Error("inflate: repeat with no length")
            prev = lengths[lengths.length - 1]
            rep = 3 + bits(2)
          } else rep = sym === 17 ? 3 + bits(3) : 11 + bits(7)
          if (lengths.length + rep > nlen + ndist) throw new Error("inflate: too many lengths")
          while (rep--) lengths.push(prev)
        }
        codes(table(lengths.slice(0, nlen)), table(lengths.slice(nlen)))
      } else throw new Error("inflate: bad block type")
    } while (!last)
    return out
  }
  // KRC: "[start,length]<offset,length,0>word<...>word", times in ms, the
  // offsets from the line's start. Returns lines like parseLrc's plus
  // words: [{t, e, text, gap, syl: [{t, e, n}]}], where a word may be built
  // from several timed syllables and gap means a space follows it. Chinese
  // and Japanese characters are each their own word, so lines wrap between
  // them. Returns null when the words are not really timed.
  function parseKrc(txt, title, artist) {
    var cjk = /[぀-ヿ㐀-䶿一-鿿豈-﫿]/
    var lines = [], flat = 0, many = 0
    var ls = String(txt).split("\n")
    for (var i = 0; i < ls.length; i++) {
      var m = /^\[(\d+),(\d+)\](.*)$/.exec(ls[i].trim())
      if (!m) continue
      var start = Number(m[1]), words = [], w, lens = []
      var re = /<(\d+),(\d+),-?\d+>([^<]*)/g
      while ((w = re.exec(m[3])) !== null) {
        var t0 = (start + Number(w[1])) / 1000, t1 = t0 + Number(w[2]) / 1000
        var s = w[3]
        lens.push(Number(w[2]))
        var prev = words.length ? words[words.length - 1] : null
        // A space on its own ends the word before it.
        if (!/\S/.test(s)) { if (prev && s.length) prev.gap = true; continue }
        var lead = /^\s/.test(s), trail = /\s$/.test(s)
        s = s.trim().replace(/\s+/g, " ")
        if (prev && !prev.gap && !lead && !cjk.test(prev.text) && !cjk.test(s)) {
          prev.text += s
          prev.syl.push({ t: t0, e: t1, n: s.length })
          prev.e = Math.max(prev.e, t1)
        } else words.push({ t: t0, e: t1, text: s, gap: false, syl: [{ t: t0, e: t1, n: s.length }] })
        if (trail) words[words.length - 1].gap = true
      }
      if (!words.length) continue
      words[words.length - 1].gap = false
      var text = ""
      for (var k = 0; k < words.length; k++) text += words[k].text + (words[k].gap ? " " : "")
      // Credits ("Lyrics by：…", 作词：…), KuGou's notices, and the
      // "Artist - Title" line songs often open with are not sung.
      if (/[:：]/.test(text) && (/(^|\s)(lyrics|lyricist|composed|composer|produced|producer|written|writer|arranged|arranger|music|words|mixed|mastered|vocals?|recorded)\b/i.test(text)
          || /[作词詞曲编編制混监監录錄]/.test(text))) continue
      if (/著作权|著作權|未经|未經|不得翻唱|酷狗|TME/.test(text)) continue
      if (!lines.length && / - /.test(text) && root.sameName(text, title) && root.sameName(text, artist)) continue
      var end = 0
      for (k = 0; k < words.length; k++) end = Math.max(end, words[k].e)
      // Every piece exactly as long as the next: spread evenly, not timed.
      if (lens.length >= 3) {
        many += 1
        if (Math.max.apply(null, lens) - Math.min.apply(null, lens) <= 1) flat += 1
      }
      lines.push({ t: words[0].t, e: end, text: text, words: words })
    }
    if (!lines.length || flat * 2 > many) return null
    lines.sort(function(a, b) { return a.t - b.t })
    // Breaks, as parseLrc has them: the wait before the first line, and a
    // silence of 3 s or more (counted from 0.6 s after a line's last word,
    // so a held note is not cut off by the dots).
    var out = []
    if (lines[0].t > 3) out.push({ t: 0, text: "" })
    for (i = 0; i < lines.length; i++) {
      out.push(lines[i])
      var next = lines[i + 1]
      if (next && next.t - (lines[i].e + 0.6) >= 3) out.push({ t: lines[i].e + 0.6, text: "" })
    }
    return out
  }
  // KuGou drops most punctuation and some capitals ("Oh I remember how you
  // were you were…"). Where a line has the same words as LRCLIB's version,
  // LRCLIB's spelling is shown with KuGou's timing ("Oh, I remember how you
  // were, you were…"): the whole line, or a run inside a longer LRCLIB line
  // when the two split lines differently. Whole-line matches also check the
  // timing: when the two disagree by more than 1.5 s, KuGou timed another
  // version of the song and is not used (null).
  function polishKrc(lines, lrc) {
    if (!lrc || !lrc.length) return lines
    var key = function(w) { return w.toLowerCase().replace(/[’‘`]/g, "'").replace(/[^a-z0-9'\u00c0-\u024f\u0400-\u04ff]/g, "") }
    // [{k: the word to compare, w: the word as shown}]; punctuation standing
    // on its own ("-") rides along with the word before it.
    var words = function(s) {
      var out = [], ws = String(s).trim().split(/\s+/)
      for (var i = 0; i < ws.length; i++) {
        var k = key(ws[i])
        if (k) out.push({ k: k, w: ws[i] })
        else if (out.length && ws[i]) out[out.length - 1].w += " " + ws[i]
      }
      return out
    }
    var ref = [], diffs = []
    for (var j = 0; j < lrc.length; j++) ref.push(words(lrc[j].text))
    for (var i = 0; i < lines.length; i++) {
      var L = lines[i]
      if (!L.words) continue
      var counts = [], mine = []
      for (var u = 0; u < L.words.length; u++) {
        var ws = words(L.words[u].text)
        counts.push(ws.length)
        for (var q = 0; q < ws.length; q++) mine.push(ws[q].k)
      }
      if (!mine.length) continue
      // Best candidate: every word the same (1), a run inside a longer line
      // (0.9, three words or more), or for a line of four or more at least
      // three words in four the same ("drivin'" and "driving" still pair).
      var best = null
      for (j = 0; j < lrc.length; j++) {
        var R = ref[j]
        if (!R.length || Math.abs(lrc[j].t - L.t) > 8) continue
        var score = 0, at = 0
        if (R.length === mine.length) {
          var same = 0
          for (q = 0; q < R.length; q++) if (R[q].k === mine[q]) same += 1
          score = same === R.length ? 1 : (R.length >= 4 && same * 4 >= R.length * 3 ? same / R.length * 0.85 : 0)
        } else if (mine.length >= 3 && R.length > mine.length) {
          for (var p = 0; p + mine.length <= R.length && !score; p++) {
            var ok = true
            for (q = 0; q < mine.length && ok; q++) ok = R[p + q].k === mine[q]
            if (ok) { score = 0.9; at = p }
          }
        }
        if (score && (!best || score > best.score
            || (score === best.score && Math.abs(lrc[j].t - L.t) < Math.abs(lrc[best.j].t - L.t))))
          best = { j: j, score: score, at: at }
      }
      if (!best) continue
      if (ref[best.j].length === mine.length) diffs.push(L.t - lrc[best.j].t)
      var shown = ref[best.j].slice(best.at, best.at + mine.length), n = 0, text = ""
      var capital = /^[A-Z]/.test(L.words[0].text)
      for (u = 0; u < L.words.length; u++) {
        if (counts[u]) {
          var parts = []
          for (q = 0; q < counts[u]; q++) parts.push(shown[n + q].w)
          var w = parts.join(" ")
          // A run taken from mid-line keeps KuGou's capital, and a line
          // ends without a comma, as the Music app shows it.
          if (n === 0 && capital) w = w.charAt(0).toUpperCase() + w.slice(1)
          n += counts[u]
          if (n === mine.length) w = w.replace(/,+$/, "")
          L.words[u].text = w
        }
        text += L.words[u].text + (L.words[u].gap ? " " : "")
      }
      L.text = text
    }
    if (diffs.length >= 3) {
      diffs.sort(function(a, b) { return a - b })
      if (Math.abs(diffs[diffs.length >> 1]) > 1.5) return null
    }
    return lines
  }
  // How much of a word is sung at time t, 0 to 1, syllable by syllable
  // (each syllable's share of the word is its share of the letters).
  function wordFill(w, t) {
    if (t <= w.t) return 0
    if (t >= w.e) return 1
    var total = 0, done = 0
    for (var i = 0; i < w.syl.length; i++) total += w.syl[i].n
    for (i = 0; i < w.syl.length; i++) {
      var s = w.syl[i]
      if (t >= s.e) { done += s.n; continue }
      if (t > s.t) done += s.n * (t - s.t) / Math.max(0.01, s.e - s.t)
      break
    }
    return total ? done / total : 1
  }
  function lyricsGet(url, cb) {
    var x = new XMLHttpRequest()
    root.lyricsXhrs = root.lyricsXhrs.concat([x])
    x.onreadystatechange = function() {
      if (x.readyState !== XMLHttpRequest.DONE) return
      root.lyricsXhrs = root.lyricsXhrs.filter(function(o) { return o !== x })
      if (!root.lyricsXhrs.length) lyricsTimeout.stop()
      var d = null
      if (x.status === 200) { try { d = JSON.parse(x.responseText) } catch (e) {} }
      cb(d)
    }
    x.open("GET", url)
    // LRCLIB asks clients to name themselves.
    if (url.indexOf("https://lrclib.net/") === 0)
      x.setRequestHeader("Lrclib-Client", "nic.youtube-music (Omarchy bar widget)")
    x.send()
    lyricsTimeout.restart()
  }
  // A lookup that hangs (a dead connection after a network change, see
  // ArtImage) is given up 8 s after the last one started, and the next
  // source is used.
  Timer {
    id: lyricsTimeout; interval: 8000
    onTriggered: { var xs = root.lyricsXhrs; for (var i = 0; i < xs.length; i++) xs[i].abort() }
  }
  function lrclibLookup(ss, cb) {
    var q = function(k, v) { return k + "=" + encodeURIComponent(v) }
    var title = String(ss.title || "")
    var artist = String(ss.artist || "")
    var dur = Math.round(Number(ss.songDuration || 0))
    var url = "https://lrclib.net/api/get?" + q("artist_name", artist) + "&" + q("track_name", title)
      + (ss.album ? "&" + q("album_name", ss.album) : "") + (dur > 0 ? "&" + q("duration", dur) : "")
    lyricsGet(url, function(d) {
      var plain = d && d.plainLyrics ? { synced: false, lines: root.plainLines(d.plainLyrics), source: "LRCLIB" } : null
      if (d && d.syncedLyrics) { cb({ synced: true, lines: root.parseLrc(d.syncedLyrics), source: "LRCLIB" }); return }
      // No exact match: search by a cleaned title and the first artist, and
      // take the closest length within 3 s that has timed lines.
      var clean = title.replace(/\s*[\(\[](feat\.?|ft\.?|with)[^\)\]]*[\)\]]/ig, "").trim()
      var first = artist.split(/\s*(?:,|&| x | feat\.? | ft\.? )\s*/i)[0]
      root.lyricsGet("https://lrclib.net/api/search?" + q("track_name", clean) + "&" + q("artist_name", first), function(list) {
        var best = null
        if (list && list.length) for (var i = 0; i < list.length; i++) {
          var e = list[i]
          if (!e.syncedLyrics) continue
          var off = dur > 0 ? Math.abs(Number(e.duration || 0) - dur) : 0
          if (off <= 3 && (!best || off < best.off)) best = { off: off, e: e }
        }
        if (best) cb({ synced: true, lines: root.parseLrc(best.e.syncedLyrics), source: "LRCLIB" })
        else cb(plain)
      })
    })
  }
  // The clock for timed lines. The app pushes whole seconds, too coarse for
  // lines changing on the beat, so the player's own currentTime is read once
  // a second (a tiny evaluate, not the whole Page.js) and run forward between
  // reads. Only while the Lyrics tab is on screen with timed lines.
  property var lyricsAnchor: ({ t: 0, at: 0, playing: false })
  readonly property bool lyricsLive: opened && view === "lyrics" && !searching && !currentPage
    && lyricsSynced && lyricsState === "ready" && showingLive
  function syncLyricsClock() {
    if (!appUp) return
    var sent = Date.now()
    cdpSend("Runtime.evaluate", { expression: "(function(){var v=document.querySelector('video');return v?[v.currentTime,v.paused]:null})()",
      returnByValue: true }, function(v) {
        if (!v || v.length !== 2) return
        // The reading is taken from halfway through the round trip. One that
        // agrees with the running clock within 40 ms leaves it alone: taking
        // every reading as it came made the word fill twitch each second by
        // the round trip's own jitter.
        var at = (sent + Date.now()) / 2, t = Number(v[0]), playing = !v[1]
        var a = root.lyricsAnchor
        var guess = a.playing ? a.t + (at - a.at) / 1000 : a.t
        if (playing && a.playing && Math.abs(t - guess) < 0.04) return
        root.lyricsAnchor = { t: t, at: at, playing: playing }
      }, false)
  }
  function lyricIndexAt(t) {
    var ls = lyricLines, lo = 0, hi = ls.length - 1, ans = -1
    while (lo <= hi) { var mid = (lo + hi) >> 1; if (ls[mid].t <= t) { ans = mid; lo = mid + 1 } else hi = mid - 1 }
    return ans
  }
  Timer {
    interval: 1000; repeat: true; triggeredOnStart: true
    running: root.lyricsLive
    onTriggered: root.syncLyricsClock()
  }
  // The clock's time, for the break dots that fill as a break goes by. Only
  // the break being sung reads it (a binding depends on it only while its
  // line is the sung one), so the other lines do not re-evaluate 20 times a
  // second.
  property real lyricsNow: 0
  function tickLyrics() {
    var a = lyricsAnchor
    var t = a.playing ? a.t + (Date.now() - a.at) / 1000 : a.t
    lyricsNow = t
    // A hair early, the way Apple Music lights a line as it starts.
    var i = lyricIndexAt(t + 0.2)
    if (i !== lyricIndex) lyricIndex = i
  }
  Timer {
    interval: 50; repeat: true
    running: root.lyricsLive && !wordFrames.running
    onTriggered: root.tickLyrics()
  }
  // With word timing the clock runs every frame while music plays, so a word
  // fills smoothly; 20 steps a second showed as steps. Only the sung line's
  // words read it.
  FrameAnimation {
    id: wordFrames
    running: root.lyricsLive && root.lyricsWords && root.lyricsAnchor.playing
    onTriggered: root.tickLyrics()
  }
  // Words light a touch ahead of the voice, as they do in Apple Music.
  readonly property real wordLead: 0.05
  // Tap a timed line: jump there.
  function seekLyric(i) {
    var l = lyricLines[i]
    if (!l || l.t < 0 || !showingLive) return
    seekTo(l.t)
    lyricsAnchor = { t: l.t, at: Date.now(), playing: lyricsAnchor.playing }
    lyricIndex = i
  }

  function refresh() {
    if (!appUp) return
    checkOffline()
    loadQueue()
    page("window.__nicYtm.signedIn()", function(v) { root.signedIn = v !== false })
    if (searchText.trim()) runSearch()
    else if (currentPage) loadBrowse(currentPage.browseId, currentPage.params)
    // Nothing to browse on the Queue tab. Drop any Home or Library load still
    // in flight and its error, so "The queue is empty." is not replaced by
    // another tab's message.
    else if (view === "queue") { serial += 1; loading = false; loadingMore = false; moreToken = ""; listError = "" }
    else if (view === "lyrics") { serial += 1; loading = false; loadingMore = false; moreToken = ""; listError = ""; loadLyrics() }
    else if (view === "library") loadBrowse(libraryPage, "")
    else loadBrowse("FEmusic_home", "")
  }

  function loadBrowse(browseId, params) {
    serial += 1
    var mine = serial
    loading = true
    loadingMore = false
    moreToken = ""
    moreEager = browseId === "FEmusic_home"
    listError = ""
    // Drop the last page's header, or the back bar shows the previous album's
    // title while this one loads (and keeps it if this one fails).
    pageHeader = null
    page("window.__nicYtm.browse(" + JSON.stringify(browseId) + "," + JSON.stringify(params || "") + ")", function(v, err) {
      if (mine !== root.serial) return
      root.loading = false
      // Page.js answers {error: "<sentence>"} on failure (never a raw "Object").
      if (!v || v.error) { root.listError = (v && v.error) || err || "Could not load this page."; root.setList([], "", "/browse"); return }
      root.pageHeader = v.header
      root.setList(v.sections || [], v.cont || "", "/browse")
      if (root.sections.length === 0) root.listError = root.signedIn ? "Nothing here yet" : "Sign in inside the YouTube Music app to see your library."
    })
  }

  function runSearch() {
    var q = searchText.trim()
    if (!q) return
    // serial moves only for a real search: bumping it before the empty check
    // dropped the Home load that the emptied search had just started, and the
    // list stayed dimmed.
    serial += 1
    var mine = serial
    var filter = searchFilter
    loading = true
    loadingMore = false
    moreToken = ""
    moreEager = false
    listError = ""
    page("window.__nicYtm.search(" + JSON.stringify(q) + "," + JSON.stringify(filter) + ")", function(v, err) {
      if (mine !== root.serial) return
      root.loading = false
      if (!v || v.error) {
        root.listError = (v && v.error) || err || "Search failed."
        root.setList([], "", "/search")
        root.openFirstPending = false
        return
      }
      // A filtered answer's chips carry other params, so keep the first set.
      if (!filter) root.searchChips = v.chips || []
      root.setList(v.sections || [], "", "/search")
      if (root.sections.length === 0) root.listError = "No results for “" + q + "”."
      // Enter was pressed before these results arrived (openFirstResult).
      var openNow = root.openFirstPending
      root.openFirstPending = false
      if (openNow && root.sections.length) root.openFirstResult()
    })
  }
  Timer { id: searchDebounce; interval: 350; onTriggered: root.runSearch() }
  // Only a change to the trimmed query counts: a trailing space re-ran the
  // same search, and a lone space reloaded the current tab. serial += 1 drops
  // a browse still in flight, and loading dims the old rows at once so they
  // don't read as results for the new query.
  property string lastQuery: ""
  onSearchTextChanged: {
    var q = searchText.trim()
    if (q === lastQuery) return
    lastQuery = q
    openFirstPending = false
    moreToken = ""
    searchFilter = ""
    searchChips = []
    if (q) { pageStack = []; serial += 1; loading = true; searchDebounce.restart() }
    else { searchDebounce.stop(); refresh() }
  }

  // Enter in the search box opens the top result. Until this query's rows
  // land the list still holds the old ones (Home, or the last query), so
  // Enter waits for them instead of opening a stale row.
  property bool openFirstPending: false
  function openFirstResult() {
    if (!searching) return
    if (searchDebounce.running) { searchDebounce.stop(); runSearch() }
    if (loading) { openFirstPending = true; return }
    for (var i = 0; i < rows.length; i++)
      if (!rows[i].header) { openItem(rows[i]); return }
  }

  // Esc steps back one level: out of an opened album, playlist or artist
  // (back to the search results when it came from them), then out of the
  // search, then closes. Pages come first: clearing the search while on a
  // page opened from it dropped the results and reloaded the page. Only
  // searchText is set; the field follows through its binding (the old
  // searchField.text = "" removed that binding, checked offline).
  function stepBack() {
    if (currentPage) goBack()
    else if (searching) searchText = ""
    else close()
  }

  function rowKey(it) { return it.kind + ":" + (it.setId || it.videoId || it.browseId || it.playlistId) + ":" + it.title }
  // Show a fresh list (page one) and note where its next page is.
  function setList(secs, pageCont, path) {
    var keys = {}
    for (var i = 0; i < secs.length; i++)
      for (var j = 0; j < secs[i].items.length; j++) keys[rowKey(secs[i].items[j])] = true
    rowKeys = keys
    var last = secs.length ? secs[secs.length - 1] : null
    moreToken = (last && last.cont) || pageCont || ""
    morePath = path
    sections = secs
    loadMoreSoon.restart()
  }
  // Fetch the next page once the list is within about a screen and a half of
  // its end, or right away when page one is too short to scroll (the
  // playlists grid sends only 4 tiles first). Home fetches every slice.
  function maybeLoadMore() {
    if (!moreToken || loadingMore || loading || !appUp || !opened || moreCapped) return
    if (view === "queue" && !searching && !currentPage) return
    var left = list.originY + list.contentHeight - list.contentY - list.height
    if (!moreEager && left > list.height * 1.5) return
    loadMore()
  }
  function loadMore() {
    var mine = serial
    var token = moreToken
    loadingMore = true
    page("window.__nicYtm.more(" + JSON.stringify(morePath) + "," + JSON.stringify(token) + ")", function(v, err) {
      // A newer list replaced this one (and reset loadingMore itself).
      if (mine !== root.serial) return
      root.loadingMore = false
      // Same list, but its paging was cleared meanwhile (Queue tab, new typing).
      if (token !== root.moreToken) return
      if (!v || v.error) { root.moreToken = ""; root.toast((v && v.error) || err || "Could not load more."); return }
      var keys = root.rowKeys
      // Album tracks come without art; page one got the cover in Page.js.
      var art = !root.searching && root.currentPage && root.pageHeader ? (root.pageHeader.thumb || "") : ""
      var fresh = function(items) {
        var out = []
        for (var i = 0; i < items.length; i++) {
          var k = root.rowKey(items[i])
          if (keys[k]) continue
          keys[k] = true
          if (!items[i].thumb && art) items[i].thumb = art
          out.push(items[i])
        }
        return out
      }
      var secs = root.sections.slice()
      var add = fresh(v.items || [])
      if (add.length) {
        if (!secs.length) secs.push({ title: "", items: [] })
        var last = secs[secs.length - 1]
        secs[secs.length - 1] = { title: last.title, items: last.items.concat(add), more: last.more }
      }
      // Home: whole new shelves.
      var more = v.sections || []
      for (var j = 0; j < more.length; j++) {
        var its = fresh(more[j].items)
        if (its.length) secs.push({ title: more[j].title, items: its, more: more[j].more })
      }
      root.moreToken = v.cont || ""
      // Keep the scroll position: the rows model is a plain array, so any
      // change rebuilds the list view (see keepY on the ListView). Disarmed
      // right after: onModelChanged runs inside the assignment, but Qt 6.11
      // skips it when the new array equals the old one (a page of rows
      // already listed), and a keepY left armed opened the next, unrelated
      // list scrolled down (offline test, 2026-09-24).
      list.keepY = list.contentY
      root.sections = secs
      list.keepY = -1
      loadMoreSoon.restart()
    })
  }
  onViewChanged: {
    pageStack = []
    moreToken = ""
    if (view === "queue") queueScrollToNow = true
    if (!searching) refresh()
  }
  onLibraryPageChanged: if (view === "library" && !searching && !currentPage) refresh()

  function openItem(it) {
    // A section header with a "Show all" link (artist pages, Home's Listen again).
    if (it.header) {
      if (it.more) openItem({ kind: "page", browseId: it.more.browseId, params: it.more.params, title: it.title })
      return
    }
    if (it.kind === "queue") { queueAct("jump", it); return }
    if (it.browseId && it.kind !== "song") {
      // Keep the list being left as it is (every page loaded so far and the
      // scroll position), so Back lands on the same row instead of page one.
      var back = { sections: sections, pageHeader: pageHeader, moreToken: moreToken, morePath: morePath,
        moreEager: moreEager, rowKeys: rowKeys, y: list.contentY, listError: listError }
      // Keep the tile's own play endpoint (album and playlist tiles carry one),
      // and drop the list being left. While the new page loaded, the Play
      // button used the old rows and started their first song, and the old
      // rows stayed clickable (harness, 2026-09-24).
      pageStack = pageStack.concat([{ browseId: it.browseId, params: it.params, title: it.title, play: it.play || null, back: back }])
      sections = []
      pageHeader = null
      loadBrowse(it.browseId, it.params)
      return
    }
    playItem(it)
  }
  function goBack() {
    var top = currentPage
    pageStack = pageStack.slice(0, pageStack.length - 1)
    var b = top ? top.back : null
    if (!b) {
      // No saved list (a page opened over IPC): reload, without the page's rows
      // clickable in the meantime.
      sections = []
      pageHeader = null
      refresh()
      return
    }
    serial += 1        // drop any page still loading for the page we left
    loading = false
    loadingMore = false
    listError = b.listError
    pageHeader = b.pageHeader
    rowKeys = b.rowKeys
    morePath = b.morePath
    moreToken = b.moreToken
    moreEager = b.moreEager
    list.keepY = b.y
    sections = b.sections
    list.keepY = -1        // see loadMore: not left armed when nothing changed
    // Home's slices were still streaming when the page opened.
    loadMoreSoon.restart()
  }
  function playItem(it) {
    if (it.kind === "queue") { queueAct("jump", it); return }
    var ep = it.play
    if (!ep && it.videoId) ep = { watchEndpoint: { videoId: it.videoId } }
    if (!ep && it.playlistId) ep = { watchPlaylistEndpoint: { playlistId: it.playlistId } }
    if (!ep && it.browseId && /^VL/.test(it.browseId)) ep = { watchPlaylistEndpoint: { playlistId: it.browseId.slice(2) } }
    if (!ep && it.browseId) {
      // Artist tiles carry no play button of their own: Page.js opens the page
      // and presses its Shuffle (a library artist: its "Shuffle all" row).
      expect("")
      page("window.__nicYtm.playPage(" + JSON.stringify(it.browseId) + "," + JSON.stringify(it.params || "") + ")", function(v, err) {
        if (!v || v.error) { root.unexpect(); root.toast((v && v.error) || err || "That can't be played directly.") }
      })
      return
    }
    if (!ep) { toast("That can't be played directly."); return }
    expect(ep.watchEndpoint ? ep.watchEndpoint.videoId : "")
    page("window.__nicYtm.play(" + JSON.stringify(ep) + ")", function(v, err) {
      // play() answers false while the page is mid-reload (no ytmusic-app yet).
      if (err || v === false) { root.unexpect(); root.toast(err || "The app is still loading. Try again in a moment.") }
    })
  }
  // The back bar's Play: the page's own big button first (artist Shuffle,
  // album or playlist Play), then the tile's own play, then the playlist
  // itself. The first playable row only once the page's rows are in; while it
  // loads, Page.js fetches the page and presses its button itself.
  function playPageAll() {
    var cp = currentPage
    if (!cp) return
    if (pageHeader && pageHeader.play) { playItem({ play: pageHeader.play }); return }
    if (cp.play) { playItem({ play: cp.play }); return }
    var b = cp.browseId
    if (/^VL/.test(b)) { playItem({ play: { watchPlaylistEndpoint: { playlistId: b.slice(2) } } }); return }
    if (loading) { playItem({ kind: "page", browseId: b, params: cp.params }); return }
    for (var i = 0; i < rows.length; i++) if (!rows[i].header && rows[i].play) { playItem(rows[i]); return }
  }

  // Bring the app window forward. Class match, focus only: never a close-type
  // dispatcher (see memory: never-kill-windows-by-dispatch).
  function showApp() {
    Quickshell.execDetached(["hyprctl", "dispatch", "hl.dsp.workspace.toggle_special(\"music\")"])
    close()
  }
  function startApp() {
    wake("")
  }

  property string toastText: ""
  function toast(t) { toastText = t; toastTimer.restart() }
  Timer { id: toastTimer; interval: 2600; onTriggered: root.toastText = "" }

  function fmt(sec) {
    sec = Math.max(0, Math.floor(sec || 0))
    var m = Math.floor(sec / 60)
    var s = sec % 60
    return m + ":" + (s < 10 ? "0" : "") + s
  }

  // ------------------------------------------------------------ IPC
  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function playPause(): void { root.playPause() }
    function next(): void { root.next() }
    function previous(): void { root.previous() }
    function wake(): void { root.wake("") }
    function quit(): void { root.quitApp() }
    // Pause only: never starts or wakes anything (World Radio calls this when
    // a station starts; see onIsPlayingChanged for the other direction).
    function pause(): void { root.pauseOnly() }
    // Test hooks: scroll the Up next list or the main list (pixels, clamped to
    // the content) to check the back-to-top button and that the next page loads.
    function scrollUpNext(px: int): void { upList.contentY = Math.max(upList.originY, Math.min(px, upList.originY + upList.contentHeight - upList.height)) }
    function scrollList(px: int): void { list.contentY = Math.max(list.originY, Math.min(px, list.originY + list.contentHeight - list.height)) }
    // Test hook: pick a search filter by its label (All, Songs, Albums, Artists, Playlists).
    function filter(label: string): void {
      var o = root.searchFilterOptions
      for (var i = 0; i < o.length; i++)
        if (o[i].label === label && o[i].value !== root.searchFilter) { root.searchFilter = o[i].value; root.runSearch() }
    }
    // Test hook: put the arrow-key cursor on row n (-1 clears it).
    function cursor(n: int): void {
      if (n >= 0 && n < root.rows.length && !root.rows[n].header) { root.cursor = n; list.positionViewAtIndex(n, ListView.Contain) }
      else root.cursor = -1
    }
    function search(q: string): void { root.open(); root.searchText = q }
    // With the view unchanged, onViewChanged never runs: clear a drilled page
    // and reload by hand, or "tab home" inside an album stayed in the album.
    // Unknown names are ignored ("tab foo" loaded Home under no selected tab).
    function tab(name: string): void {
      if (["home", "library", "queue", "lyrics"].indexOf(name) < 0) return
      root.open()
      root.searchText = ""
      var same = root.view === name
      root.pageStack = []
      root.view = name
      if (same) root.refresh()
    }
    function library(id: string): void {
      root.open()
      root.searchText = ""
      var same = root.view === "library" && root.libraryPage === id
      root.pageStack = []
      root.view = "library"
      root.libraryPage = id
      if (same) root.refresh()
    }
    function openRow(n: int): void { if (n >= 0 && n < root.rows.length) root.openItem(root.rows[n]) }
    // A Queue row jumps by queue id (playItem sends it through queueAct);
    // building a plain watchEndpoint replaced the whole queue with a radio.
    function playRow(n: int): void { if (n >= 0 && n < root.rows.length) root.playItem(root.rows[n]) }
    function back(): void { root.goBack() }
    function status(): string {
      return JSON.stringify({
        appUp: root.appUp, starting: root.starting, failed: root.startFailed, offline: root.appOffline,
        lastSong: root.lastSong ? root.lastSong.title + " @" + root.lastSong.elapsedSeconds : "",
        idle: root.idleSeconds, inFront: root.appInFront(), signedIn: root.signedIn,
        playing: root.isPlaying, songReal: root.songReal, title: root.title, artist: root.artist,
        album: root.album, position: Math.round(root.position), reportedPosition: Math.round(root.reportedPosition),
        duration: root.duration, volume: root.volume,
        muted: root.muted, repeat: root.repeatMode, shuffle: root.shuffle, like: root.likeState,
        view: root.view, library: root.libraryPage, search: root.searchText, loading: root.loading,
        error: root.listError, stack: root.pageStack.map(function(p) { return p.title }),
        rows: root.rows.slice(0, 12).map(function(r) { return r.header ? "## " + r.title : (r.kind + " | " + r.title + " | " + r.subtitle) }),
        rowCount: root.rows.length, more: root.moreToken !== "", loadingMore: root.loadingMore, capped: root.moreCapped,
        filters: root.searchFilterOptions.map(function(o) { return o.label + (o.value === root.searchFilter ? "*" : "") }),
        listY: Math.round(list.contentY), cursor: root.cursor,
        upNext: root.upNext.length, appShown: root.appShown, queue: root.queueItems.length, opened: root.opened,
        // Queue test hooks: the playing row and the first rows as "id title".
        queueNow: root.queueItems.findIndex(function(q) { return q.current }),
        queueHead: root.queueItems.slice(0, 8).map(function(q) { return q.queueId + " " + q.title + (q.current ? " *" : "") }),
        token: root.apiToken !== "",
        // Lyrics test hooks: where they came from, and the sung line.
        lyrics: { state: root.lyricsState, source: root.lyricsSource, synced: root.lyricsSynced,
          words: root.lyricsWords, lines: root.lyricLines.length, index: root.lyricIndex,
          now: Math.round(root.lyricsNow * 100) / 100,
          line: root.lyricIndex >= 0 && root.lyricLines[root.lyricIndex] ? root.lyricLines[root.lyricIndex].text : "" }
      })
    }
  }

  // ------------------------------------------------------------ bar
  visible: true
  implicitWidth: barRow.implicitWidth + Style.space(16)
  implicitHeight: bar ? bar.barSize : Style.bar.sizeHorizontal

  // The bar shows a tooltip only for a target that says it is hovered
  // (Bar.qml targetTooltipHovered), as WidgetButton does. This widget never
  // had it, so its tooltip never appeared.
  readonly property bool tooltipHovered: barMouse.containsMouse && !root.opened
  function barTip() {
    if (startFailed) return "YouTube Music didn't start. Click to try again."
    if (starting) return "Starting YouTube Music…"
    if (!hasSong) return appUp ? "YouTube Music. Click to open it." : "YouTube Music is closed. Click to start it."
    var who = title + (artist ? " by " + artist : "")
    if (isPlaying) return who
    return who + (appUp ? " (paused)" : " (paused, the app is closed)")
  }

  // One entry point for bar clicks. A left click arrives here from the bar's
  // own module pointer (which takes left clicks and calls triggerPress on the
  // widget under it); right and middle clicks come from barMouse below.
  //
  // Deliberately NOT registered as a bar click target (the way WidgetButton
  // does it). The registration would let a right or middle click work while
  // the panel is open (the panel's overlay only forwards clicks to registered
  // targets; without it those clicks just close the panel, as before the
  // audit). But with it registered, a right click on the icon did nothing in
  // live tests even with the panel closed, and without it the same clicks
  // play and pause at once (real clicks, 2026-09-24). It also adds to the
  // click-target churn at shell start, where Omarchy's Bar.qml deep-copies
  // its layout for every plugin; that is where the Qt garbage-collector crash
  // of 2026-09-24 surfaced (the trigger turned out to be Page.js, see there).
  function triggerPress(button) {
    if (bar) bar.hideTooltip(root)
    // Right click plays even with nothing remembered: play then starts Liked songs.
    if (button === Qt.RightButton) playPause()
    else if (button === Qt.MiddleButton) { if (hasSong) next() }
    else toggle()
  }
  // appShown starts false after a shell restart even if the app is on screen.
  Component.onCompleted: readAppShown()

  // One pulse for both waking signs: the bar while the app starts in the
  // background (a right click on a closed app gave no sign for 2-3 s), and the
  // panel's glyph. It runs only while starting, or during the panel's 400 ms
  // wait before a wake, never while nothing is happening.
  QtObject { id: pulse; property real value: 1 }
  SequentialAnimation {
    running: root.starting || (root.opened && openWake.running)
    loops: Animation.Infinite
    NumberAnimation { target: pulse; property: "value"; to: 0.35; duration: 700; easing.type: Easing.InOutSine }
    NumberAnimation { target: pulse; property: "value"; to: 1; duration: 700; easing.type: Easing.InOutSine }
    onRunningChanged: if (!running) pulse.value = 1
  }


  Row {
    id: barRow
    anchors.centerIn: parent
    spacing: Style.space(8)
    opacity: root.starting ? pulse.value : 1

    // Dim YouTube glyph while the app is closed or nothing is loaded.
    Text {
      visible: !root.hasSong
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.gYouTube
      color: root.appUp ? root.a(root.barFg, 0.8) : root.a(root.barFg, 0.45)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }

    // Three bars that step while music plays and settle when paused. Stepped
    // five times a second on purpose: a running NumberAnimation re-rendered
    // the whole bar every frame, 120 times a second on this panel, for a 13 px
    // icon (measured 2026-09-24 while playing: shell about 6.5% of a core,
    // render thread about 155 wakeups a second, 2.8% of the GPU; offline the
    // smooth version drew 188 frames in 3 s, the stepped one 15). A switched
    // off or locked screen draws no frames, so no idle check is needed.
    Item {
      id: eq
      visible: root.hasSong
      width: Style.space(13)
      height: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      property int step: 0
      readonly property bool dancing: root.isPlaying
      Timer {
        interval: 200
        repeat: true
        running: eq.dancing && eq.visible
        onTriggered: eq.step = (eq.step + 1) % 4
      }
      Repeater {
        model: [0.55, 1.0, 0.75]
        Rectangle {
          required property var modelData
          required property int index
          readonly property var levels: [0.35, modelData, 0.5, 0.25 + index * 0.1]
          width: Style.space(3)
          radius: width / 2
          x: index * Style.space(5)
          anchors.bottom: parent.bottom
          color: root.isPlaying ? Color.accent : root.a(root.barFg, 0.5)
          height: Math.max(width, eq.height * (eq.dancing ? levels[(eq.step + index) % 4] : (root.isPlaying ? modelData * 0.8 : 0.3)))
          Behavior on color { ColorAnimation { duration: 200 } }
        }
      }
    }

    Text {
      anchors.verticalCenter: parent.verticalCenter
      visible: root.showTitle && root.hasSong && !(root.bar && root.bar.vertical)
      width: Math.min(root.maxLabelWidth, implicitWidth)
      elide: Text.ElideRight
      textFormat: Text.PlainText
      text: root.title
      color: root.isPlaying ? root.barFg : root.a(root.barFg, 0.55)
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      Behavior on color { ColorAnimation { duration: 200 } }
    }
  }

  MouseArea {
    id: barMouse
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton | Qt.MiddleButton
    onClicked: function(mouse) { root.triggerPress(mouse.button) }
    onEntered: if (root.bar && !root.opened) root.bar.showTooltip(root, root.barTip())
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  // ------------------------------------------------------------ panel
  // Panel buttons carry their own tooltip, the first-party pattern (the clock
  // and agents panels): the bar's tooltip only serves items in the bar window
  // that report tooltipHovered, so bar.showTooltip never showed these. The
  // tooltip is made only while the button is hovered, because the list rows
  // hold four buttons each.
  component HoverTip: Loader {
    id: ht
    property string text: ""
    property bool shown: false
    anchors.fill: parent
    active: shown && text !== ""
    sourceComponent: PanelToolTip {
      visible: ht.shown
      text: ht.text
      fontFamily: root.fontFamily
    }
  }

  // Art that heals itself after a network change (reported 2026-09-24: a lot
  // of art was not showing up). All of the shell's image downloads to one
  // host share ONE connection (Qt's QNetworkAccessManager, HTTP/2). After the
  // laptop slept on one Wi-Fi network and woke on another, that connection to Google's
  // image servers was dead (5 KB stuck unsent, nothing received for minutes),
  // and Qt kept queueing every new cover on it with no timeout, so rows showed
  // grey boxes. The same 313 links all loaded in a fresh process. The shell's
  // network code cannot be reset from here, but Google serves the same images
  // under other host names, and a new host name means a new connection. So an
  // image that is still loading after 6 s, or fails, tries the next host.
  readonly property var artHosts: ({
    "yt3.googleusercontent.com": ["yt3.ggpht.com", "yt4.ggpht.com", "lh3.googleusercontent.com"],
    "yt3.ggpht.com": ["yt4.ggpht.com", "yt3.googleusercontent.com", "lh3.googleusercontent.com"],
    "lh3.googleusercontent.com": ["lh4.googleusercontent.com", "lh5.googleusercontent.com", "lh6.googleusercontent.com"],
    "i.ytimg.com": ["i1.ytimg.com", "i2.ytimg.com", "i3.ytimg.com"]
  })
  // The URL for try number `attempt` (0 = as given). Hosts without known
  // twins (www.gstatic.com) just ask again, which works once Qt has dropped
  // the dead connection.
  function artAt(url, attempt) {
    url = String(url || "")
    if (!attempt || url === "") return url
    var m = /^https:\/\/([^\/]+)(\/.*)$/.exec(url)
    var alts = m ? artHosts[m[1]] : null
    if (!alts) return url + (url.indexOf("?") < 0 ? "?" : "&") + "try=" + attempt
    return "https://" + alts[(attempt - 1) % alts.length] + m[2]
  }
  component ArtImage: Image {
    id: ai
    property string url: ""
    property int attempt: 0
    source: root.artAt(url, attempt)
    asynchronous: true
    onUrlChanged: attempt = 0
    onStatusChanged: if (status === Image.Error && attempt < 3) artRetry.restart()
    // A healthy load takes well under 2 s.
    Timer {
      interval: 6000
      running: ai.status === Image.Loading && ai.attempt < 3
      onTriggered: ai.attempt += 1
    }
    Timer { id: artRetry; interval: 1500; onTriggered: ai.attempt += 1 }
  }

  component IconBtn: Item {
    id: ib
    property string glyph: ""
    property bool on: false
    property bool can: true
    property real size: Style.font.iconLarge
    property string tip: ""
    signal activated()
    implicitWidth: Math.max(Style.space(30), t.implicitWidth + Style.space(8))
    implicitHeight: Style.space(30)
    opacity: can ? 1 : 0.3
    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: ibMouse.containsMouse && ib.can ? root.a(root.fg, 0.08) : "transparent"
      Behavior on color { ColorAnimation { duration: 120 } }
    }
    Text {
      id: t
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: ib.glyph
      color: ib.on ? Color.accent : (ibMouse.containsMouse ? root.fg : root.a(root.fg, 0.72))
      font.family: root.fontFamily
      font.pixelSize: ib.size
      scale: ibMouse.pressed ? 0.88 : 1
      Behavior on scale { NumberAnimation { duration: 90 } }
      Behavior on color { ColorAnimation { duration: 140 } }
    }
    MouseArea {
      id: ibMouse
      anchors.fill: parent
      hoverEnabled: true
      enabled: ib.can
      cursorShape: Qt.PointingHandCursor
      onClicked: ib.activated()
    }
    HoverTip { shown: ibMouse.containsMouse; text: ib.tip }
  }

  // Round "back to top" button that appears once a list is scrolled down. The
  // hit area stays full size and only the circle scales: with the MouseArea
  // inside the scaled circle, a press near the rim shrank out from under the
  // pointer and the click was lost (harness, 2026-09-24).
  component TopButton: Item {
    id: tb
    property Flickable view: null
    readonly property bool wanted: view && view.contentY > view.originY + Style.space(60)
    anchors.right: parent.right
    anchors.bottom: parent.bottom
    anchors.margins: Style.space(8)
    width: Style.space(34)
    height: width
    visible: opacity > 0
    opacity: wanted ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 160 } }
    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: Color.accent
      scale: tbMouse.pressed ? 0.9 : (tbMouse.containsMouse ? 1.06 : 1)
      Behavior on scale { NumberAnimation { duration: 100 } }
      Text {
        anchors.centerIn: parent
        textFormat: Text.PlainText
        text: root.gUp
        color: Color.popups.background
        font.family: root.fontFamily
        font.pixelSize: Style.font.icon
      }
    }
    NumberAnimation { id: tbAnim; target: tb.view; property: "contentY"; to: 0; duration: 260; easing.type: Easing.OutCubic }
    MouseArea {
      id: tbMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: { tb.view.cancelFlick(); tbAnim.to = tb.view.originY; tbAnim.restart() }
    }
    HoverTip { shown: tbMouse.containsMouse; text: "Back to top" }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keys
    contentWidth: panel.fittedContentWidth(Style.space(820))
    contentHeight: panel.fittedContentHeight(Style.space(640), Style.space(640))

    PanelKeyCatcher {
      id: keys
      anchors.fill: parent
      // While the search field has focus it owns the keyboard (its Keys
      // handler does Enter, Esc and Down). Otherwise keys the field passes on
      // reached this catcher too: Enter in the search box opened the first row
      // AND toggled play/pause (qmltestrunner, 2026-09-24: the field emits
      // accepted, then ignores Return, and the catcher sends activate).
      blocked: searchField.activeFocus
      property bool enterPressed: false
      onCloseRequested: root.stepBack()
      onReturnRequested: enterPressed = true
      // Enter arrives as returnRequested then activateRequested; Space as
      // activateRequested alone. Space is play/pause. Enter opens the row
      // the arrow keys picked and never touches playback.
      onActivateRequested: {
        if (enterPressed) {
          enterPressed = false
          if (root.cursor >= 0 && root.cursor < root.rows.length) root.openItem(root.rows[root.cursor])
          return
        }
        // Holding Space sends key repeats (about 25 a second), and each one
        // toggled playback. A press within 300 ms of the last is a repeat.
        if (spaceGuard.running) { spaceGuard.restart(); return }
        spaceGuard.restart()
        root.playPause()
      }
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      // Tab and Shift+Tab move to the next bar panel, like the built-in panels.
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) { if (t === "/") searchField.forceActiveFocus() }
      Timer { id: spaceGuard; interval: 300 }

      // Blurred cover behind everything, so each song tints the whole panel.
      Item {
        anchors.fill: parent
        anchors.margins: -(panel.padding - Math.max(1, Style.space(2)))
        clip: true
        visible: backdrop.status === Image.Ready && root.hasSong
        ArtImage {
          id: backdrop
          anchors.fill: parent
          url: root.artUrl
          fillMode: Image.PreserveAspectCrop
          asynchronous: true
          visible: false
        }
        MultiEffect {
          anchors.fill: parent
          source: backdrop
          blurEnabled: true
          blur: 1.0
          blurMax: 64
          saturation: 0.15
          // Keep a white cover from lifting the dark panel and washing out the
          // grey captions (about 3.1:1 on a near-white cover before).
          brightness: -0.35
          opacity: 0.2
        }
      }

      // ---------------- app waking up, closed, or failed to start ----------------
      Column {
        id: wakingCol
        anchors.centerIn: parent
        width: parent.width * 0.6
        spacing: Style.space(14)
        visible: !root.appUp
        // "Waking up" while starting and during the panel's short wait before a
        // wake, so opening the panel never flashes "closed". Otherwise the app
        // is closed (it quit or crashed while the panel was open; the retry
        // timer only probes, it never relaunches), or it failed to start.
        readonly property bool waking: root.starting || root.openWakePending
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          textFormat: Text.PlainText
          text: root.gYouTube
          color: Color.accent
          font.family: root.fontFamily
          font.pixelSize: Style.space(56)
          opacity: wakingCol.waking ? pulse.value : 1
        }
        Text {
          anchors.horizontalCenter: parent.horizontalCenter
          textFormat: Text.PlainText
          text: root.startFailed ? "YouTube Music didn't start"
            : (wakingCol.waking ? "Waking up YouTube Music…" : "YouTube Music is closed")
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignHCenter
          wrapMode: Text.Wrap
          textFormat: Text.PlainText
          text: root.startFailed ? "Try again. If it keeps failing, start the YouTube Music app from the launcher."
            : !wakingCol.waking ? "Start it again to keep listening."
            : (root.pendingAction === "play" && root.hasSong ? "Picking up " + root.title + " where you left off."
              : "It runs in the background and closes itself when you're done.")
          color: root.a(root.fg, 0.6)
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Button {
          id: startBtn
          visible: !wakingCol.waking
          anchors.horizontalCenter: parent.horizontalCenter
          text: root.startFailed ? "Try again" : "Start it"
          bordered: true
          onClicked: root.startApp()
        }
      }

      Row {
        anchors.fill: parent
        spacing: Style.space(22)
        visible: root.appUp

        // ---------------- now playing ----------------
        Column {
          id: left
          width: Style.space(270)
          height: parent.height
          spacing: Style.space(12)

          ClippingRectangle {
            width: parent.width
            height: width
            radius: Style.space(12)
            color: root.a(root.fg, 0.06)
            ArtImage {
              id: art
              anchors.fill: parent
              url: root.artUrl
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              visible: status === Image.Ready
            }
            Text {
              anchors.centerIn: parent
              visible: !art.visible
              textFormat: Text.PlainText
              text: root.gMusic
              color: root.a(root.fg, 0.35)
              font.family: root.fontFamily
              font.pixelSize: Style.space(64)
            }
            // Hover label. A solid pill on a dark scrim, so it reads on any
            // cover (a thin white label vanished on light covers).
            Item {
              anchors.fill: parent
              opacity: artMouse.containsMouse ? 1 : 0
              Behavior on opacity { NumberAnimation { duration: 140 } }
              Rectangle {
                anchors.fill: parent
                color: "black"
                opacity: 0.55
              }
              Rectangle {
                anchors.centerIn: parent
                width: pillText.implicitWidth + Style.space(28)
                height: pillText.implicitHeight + Style.space(16)
                radius: height / 2
                color: Color.popups.background
                border.width: Math.max(1, Style.space(2))
                border.color: Color.accent
                Text {
                  id: pillText
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: root.gOpen + (root.appShown ? "  Hide app" : "  Show app")
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
              }
            }
            MouseArea {
              id: artMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.showApp()
            }
          }

          Column {
            width: parent.width
            spacing: Style.space(3)
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: root.hasSong ? root.title : "Nothing playing"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.subtitle
              font.bold: true
              wrapMode: Text.Wrap
              maximumLineCount: 2
              elide: Text.ElideRight
            }
            Text {
              width: parent.width
              textFormat: Text.PlainText
              // Built from the parts that exist: an empty artist left a
              // leading "·" before the album.
              text: root.hasSong ? [root.artist, root.album].filter(function(s) { return s }).join("  ·  ") : "Pick something on the right."
              color: root.a(root.fg, 0.65)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              elide: Text.ElideRight
            }
          }

          // Seek bar
          Row {
            width: parent.width
            spacing: Style.space(8)
            opacity: root.duration > 0 ? 1 : 0.35
            Text {
              id: posT
              anchors.verticalCenter: parent.verticalCenter
              width: lenT.implicitWidth
              horizontalAlignment: Text.AlignRight
              textFormat: Text.PlainText
              text: root.fmt(seek.frac * root.duration)
              color: root.a(root.fg, 0.55)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.features: { "tnum": 1 }
            }
            Item {
              id: seek
              width: parent.width - posT.width - lenT.width - parent.spacing * 2
              height: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              property real dragFrac: -1
              readonly property bool hot: seekMouse.containsMouse || seekMouse.pressed
              readonly property real frac: dragFrac >= 0 ? dragFrac
                : (root.duration > 0 ? Math.max(0, Math.min(1, root.position / root.duration)) : 0)
              Rectangle {
                id: track
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                height: seek.hot ? Style.space(5) : Style.space(3)
                radius: height / 2
                color: root.a(root.fg, 0.14)
                Behavior on height { NumberAnimation { duration: 120 } }
              }
              Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(height, track.width * seek.frac)
                height: track.height
                radius: height / 2
                color: Color.accent
              }
              Rectangle {
                x: track.width * seek.frac - width / 2
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(11)
                height: width
                radius: width / 2
                color: root.fg
                opacity: seek.hot ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 120 } }
              }
              MouseArea {
                id: seekMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: root.duration > 0
                cursorShape: Qt.PointingHandCursor
                function fracAt(x) { return Math.max(0, Math.min(1, x / width)) }
                onPressed: function(m) { seek.dragFrac = fracAt(m.x) }
                onPositionChanged: function(m) { if (pressed) seek.dragFrac = fracAt(m.x) }
                onReleased: function(m) { root.seekTo(fracAt(m.x) * root.duration); seek.dragFrac = -1 }
              }
            }
            Text {
              id: lenT
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.fmt(root.duration)
              color: root.a(root.fg, 0.55)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.features: { "tnum": 1 }
            }
          }

          // Transport
          Item {
            width: parent.width
            height: Style.space(50)
            Row {
              anchors.centerIn: parent
              spacing: Style.space(10)
              IconBtn {
                anchors.verticalCenter: parent.verticalCenter
                glyph: root.gShuffle; size: Style.font.icon; on: root.shuffle; tip: "Shuffle"
                onActivated: root.toggleShuffle()
              }
              IconBtn {
                anchors.verticalCenter: parent.verticalCenter
                glyph: root.gPrev; can: root.hasSong; tip: "Previous"
                onActivated: root.previous()
              }
              // The hit area stays full size and only the circle scales (see
              // TopButton for why).
              Item {
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(48)
                height: width
                Rectangle {
                  anchors.fill: parent
                  radius: width / 2
                  color: Color.accent
                  opacity: root.hasSong ? 1 : 0.4
                  scale: playMouse.pressed ? 0.92 : (playMouse.containsMouse ? 1.05 : 1)
                  Behavior on scale { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }
                  Text {
                    anchors.centerIn: parent
                    anchors.horizontalCenterOffset: root.isPlaying ? 0 : Style.space(1)
                    textFormat: Text.PlainText
                    text: root.isPlaying ? root.gPause : root.gPlay
                    color: Color.popups.background
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.iconLarge
                  }
                }
                MouseArea {
                  id: playMouse
                  anchors.fill: parent
                  hoverEnabled: true
                  enabled: root.hasSong
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.playPause()
                }
                HoverTip { shown: playMouse.containsMouse; text: root.isPlaying ? "Pause" : "Play" }
              }
              IconBtn {
                anchors.verticalCenter: parent.verticalCenter
                glyph: root.gNext; can: root.hasSong; tip: "Next"
                onActivated: root.next()
              }
              IconBtn {
                anchors.verticalCenter: parent.verticalCenter
                glyph: root.repeatMode === "ONE" ? root.gRepeatOne : root.gRepeat
                size: Style.font.icon
                on: root.repeatMode !== "NONE"
                tip: root.repeatMode === "ONE" ? "Repeat one" : (root.repeatMode === "ALL" ? "Repeat all" : "Repeat off")
                onActivated: root.cycleRepeat()
              }
            }
          }

          // Like, dislike, volume. Like and dislike act on the song in the
          // player, so they wait until one of the user's is loaded (not the cue).
          Row {
            width: parent.width
            spacing: Style.space(4)
            IconBtn {
              anchors.verticalCenter: parent.verticalCenter
              glyph: root.likeState === "LIKE" ? root.gLikeOn : root.gLike
              size: Style.font.icon; on: root.likeState === "LIKE"; can: root.songLive; tip: "Like"
              onActivated: root.like()
            }
            IconBtn {
              anchors.verticalCenter: parent.verticalCenter
              glyph: root.likeState === "DISLIKE" ? root.gDislikeOn : root.gDislike
              size: Style.font.icon; on: root.likeState === "DISLIKE"; can: root.songLive; tip: "Dislike"
              onActivated: root.dislike()
            }
            Item { width: Style.space(8); height: 1 }
            IconBtn {
              id: muteBtn
              anchors.verticalCenter: parent.verticalCenter
              glyph: root.muted || root.volume === 0 ? root.gMute : root.gVolume
              size: Style.font.icon; tip: root.muted ? "Unmute" : "Mute"
              onActivated: root.toggleMute()
            }
            PanelSlider {
              id: volSlider
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - x
              bar: root.bar
              minimum: 0
              maximum: 100
              step: 1
              integer: true
              value: root.muted ? 0 : root.volume
              fillColor: Color.accent
              onMoved: function(v) {
                root.volume = Math.round(v)
                if (!volThrottle.running) { root.setVolume(v); volThrottle.start() }
              }
              onReleased: function(v) { volThrottle.stop(); root.setVolume(v) }
            }
          }

          // Up next: the rest of the queue, then autoplay picks. Scrolls; click a
          // song to jump to it.
          Column {
            width: parent.width
            height: left.height - y
            spacing: Style.space(2)
            visible: root.upNext.length > 0
            Text {
              id: upHeader
              x: Style.space(4)
              height: Style.space(22)
              verticalAlignment: Text.AlignVCenter
              textFormat: Text.PlainText
              // Written in sentence case with a capital after the "·" (it draws
              // in capitals anyway), so the source reads right too.
              text: root.upNext.length && root.upNext[0].auto ? "Up next · Autoplay" : "Up next"
              color: root.a(root.fg, 0.55)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.capitalization: Font.AllUppercase
              font.letterSpacing: 1
            }
            Item {
              width: parent.width
              height: parent.height - upHeader.height - parent.spacing
              ListView {
                id: upList
                anchors.fill: parent
                clip: true
                model: root.upNextRows
                boundsBehavior: Flickable.StopAtBounds
                // A queue reload must not throw the list back to the top (a
                // new array resets a ListView, checked offline with Qt 6.11).
                property real keepY: -1
                onModelChanged: {
                  if (keepY < 0) return
                  var y = keepY
                  keepY = -1
                  forceLayout()
                  contentY = Math.max(originY, Math.min(y, originY + contentHeight - height))
                }
                delegate: Item {
                  id: nextRow
                  required property var modelData
                  width: upList.width
                  height: modelData.header ? Style.space(26) : Style.space(44)
                  Text {
                    visible: !!nextRow.modelData.header
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Style.space(3)
                    x: Style.space(4)
                    textFormat: Text.PlainText
                    text: nextRow.modelData.title || ""
                    color: root.a(root.fg, 0.45)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                    font.capitalization: Font.AllUppercase
                    font.letterSpacing: 1
                  }
                  Rectangle {
                    visible: !nextRow.modelData.header
                    anchors.fill: parent
                    radius: Style.space(8)
                    color: nextMouse.containsMouse ? root.a(root.fg, 0.07) : "transparent"
                    Behavior on color { ColorAnimation { duration: 100 } }
                  }
                  Row {
                    visible: !nextRow.modelData.header
                    anchors.fill: parent
                    anchors.leftMargin: Style.space(4)
                    anchors.rightMargin: Style.space(6)
                    spacing: Style.space(10)
                    ClippingRectangle {
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(34)
                      height: width
                      radius: Style.space(5)
                      color: root.a(root.fg, 0.08)
                      ArtImage {
                        anchors.fill: parent
                        url: nextRow.modelData.header ? "" : (nextRow.modelData.thumb || "")
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        sourceSize.width: Style.space(68)
                        sourceSize.height: Style.space(68)
                      }
                    }
                    Column {
                      anchors.verticalCenter: parent.verticalCenter
                      width: parent.width - Style.space(34) - nextDur.width - parent.spacing * 2
                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: nextRow.modelData.title || ""
                        color: root.fg
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                      Text {
                        width: parent.width
                        textFormat: Text.PlainText
                        text: nextRow.modelData.subtitle || ""
                        color: root.a(root.fg, 0.5)
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        elide: Text.ElideRight
                      }
                    }
                    Text {
                      id: nextDur
                      anchors.verticalCenter: parent.verticalCenter
                      textFormat: Text.PlainText
                      text: nextRow.modelData.duration || ""
                      color: root.a(root.fg, 0.45)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.features: { "tnum": 1 }
                    }
                  }
                  MouseArea {
                    id: nextMouse
                    visible: !nextRow.modelData.header
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    // A click leaves the search field, like on the web, so Space
                    // is play/pause again. Queue rows and autoplay picks both go
                    // by queue id (Page.js queueAct).
                    onClicked: { keys.forceActiveFocus(); root.queueAct("jump", nextRow.modelData) }
                  }
                }
              }
              TopButton { view: upList }
            }
          }
        }

        // ---------------- browse ----------------
        Column {
          id: right
          width: parent.width - left.width - parent.spacing
          height: parent.height
          spacing: Style.space(10)

          TextField {
            id: searchField
            width: parent.width
            placeholderText: "Search songs, albums, artists and playlists (press /)"
            font.family: root.fontFamily
            text: root.searchText
            onTextChanged: root.searchText = text
            // Enter, Esc, Down and Tab are handled here and stop here
            // (keys.blocked keeps the catcher out while this field has focus).
            // Each one hands focus back to the catcher, so Space is play/pause
            // again instead of typing a space into the search. Tab and
            // Shift+Tab switch panels as they do from the catcher: the field
            // ignores Tab and the panel has no other Tab stop, so Tab did
            // nothing here (qmltestrunner, 2026-09-24).
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Tab || event.key === Qt.Key_Backtab) {
                keys.forceActiveFocus()
                root.switchPanel((event.modifiers & Qt.ShiftModifier) || event.key === Qt.Key_Backtab ? -1 : 1)
                event.accepted = true
              } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                keys.forceActiveFocus()
                root.openFirstResult()
                event.accepted = true
              } else if (event.key === Qt.Key_Escape) {
                keys.forceActiveFocus()
                if (root.searching || root.currentPage) root.stepBack()
                event.accepted = true
              } else if (event.key === Qt.Key_Down) {
                keys.forceActiveFocus()
                root.moveCursor(1)
                event.accepted = true
              }
            }
          }

          // Tabs, or a back bar when inside an album / playlist / artist.
          Item {
            width: parent.width
            height: Style.space(32)

            ButtonGroup {
              id: tabs
              visible: !root.searching && !root.currentPage
              anchors.verticalCenter: parent.verticalCenter
              options: [
                { value: "home", label: "Home" },
                { value: "library", label: "Library" },
                { value: "queue", label: "Queue" },
                { value: "lyrics", label: "Lyrics" }
              ]
              value: root.view
              focusable: false
              foreground: root.fg
              fontFamily: root.fontFamily
              fontSize: Style.font.caption
              spacing: Style.space(6)
              onChanged: function(v) { root.view = v }
            }

            Text {
              visible: root.searching && !root.currentPage
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.gSearch + "  Results for “" + root.searchText.trim() + "”   (Esc clears)"
              color: root.a(root.fg, 0.6)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }

            Row {
              visible: !!root.currentPage
              anchors.fill: parent
              spacing: Style.space(8)
              IconBtn {
                anchors.verticalCenter: parent.verticalCenter
                glyph: root.gBack; size: Style.font.icon; tip: "Back (Esc)"
                onActivated: root.goBack()
              }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - Style.space(30) - playAll.width - Style.space(16)
                textFormat: Text.PlainText
                text: root.currentPage ? ((root.pageHeader && root.pageHeader.title) || root.currentPage.title) : ""
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                elide: Text.ElideRight
              }
              Button {
                id: playAll
                anchors.verticalCenter: parent.verticalCenter
                text: root.gPlay + " Play"
                fontSize: Style.font.caption
                bordered: true
                onClicked: root.playPageAll()
              }
            }
          }

          ButtonGroup {
            id: libTabs
            visible: root.view === "library" && !root.searching && !root.currentPage
            options: root.libraryPages
            value: root.libraryPage
            focusable: false
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            spacing: Style.space(4)
            onChanged: function(v) { root.libraryPage = v }
          }

          // Search filters. "All" is YouTube Music's mixed results, which
          // have no next page; a filter pages on (20 at a time).
          ButtonGroup {
            id: filterTabs
            visible: root.searching && !root.currentPage && root.searchFilterOptions.length > 0
            options: root.searchFilterOptions
            value: root.searchFilter
            focusable: false
            foreground: root.fg
            fontFamily: root.fontFamily
            fontSize: Style.font.caption
            spacing: Style.space(4)
            onChanged: function(v) { if (v !== root.searchFilter) { root.searchFilter = v; root.runSearch() } }
          }

          Item {
            width: parent.width
            height: parent.height - y

            Text {
              anchors.centerIn: parent
              width: parent.width - Style.space(40)
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
              textFormat: Text.PlainText
              visible: list.count === 0 && !(root.view === "lyrics" && !root.searching && !root.currentPage)
              // The offline sentence also when nothing was loaded to fail: the
              // panel opened while the app came up on pear's offline page, and
              // the list stayed blank (offline test, 2026-09-24).
              text: root.loading ? "Loading…"
                : root.appOffline ? root.offlineText
                : (root.listError || (root.view === "queue" && !root.searching && !root.currentPage ? "The queue is empty." : ""))
              color: root.a(root.fg, 0.55)
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            ListView {
              id: list
              anchors.fill: parent
              clip: true
              model: root.rows
              spacing: Style.space(2)
              boundsBehavior: Flickable.StopAtBounds
              opacity: root.loading ? 0.5 : 1
              Behavior on opacity { NumberAnimation { duration: 120 } }
              // A new list starts at the top. A next page, a queue reload or
              // Back must not move it: the rows model is a plain JS array, so
              // every change rebuilds the view, and keepY carries the position
              // across. forceLayout first: without it the list landed a row off
              // when header rows (30) and song rows (52) are mixed (tested
              // offline with qml6, 2026-09-24).
              property real keepY: -1
              onModelChanged: {
                if (keepY < 0) { root.cursor = -1; positionViewAtBeginning(); return }
                var y = keepY
                keepY = -1
                forceLayout()
                // Clamped, for a Queue tab that just lost its last row.
                contentY = Math.max(originY, Math.min(y, originY + contentHeight - height))
              }
              // Later, not inside the scroll: starting a load shows the
              // "Loading more…" footer, which moves contentY again inside this
              // same handler, and Qt logged a binding loop on the footer's
              // height every few seconds while scrolling (live, 2026-09-24).
              onContentYChanged: loadMoreSoon.restart()
              onHeightChanged: loadMoreSoon.restart()
              // A plain zero-delay Timer rather than Qt.callLater, so nothing
              // is queued from inside the list's own geometry change (these
              // run while the list is built at shell start).
              Timer { id: loadMoreSoon; interval: 0; onTriggered: root.maybeLoadMore() }
              footer: Item {
                width: list.width
                height: root.loadingMore || root.moreCapped ? Style.space(40) : 0
                Text {
                  anchors.centerIn: parent
                  visible: parent.height > 0
                  textFormat: Text.PlainText
                  text: root.loadingMore ? "Loading more…" : "Showing the first " + root.rows.length + " here. The app has the rest."
                  color: root.a(root.fg, 0.5)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              delegate: Item {
                id: rowItem
                required property var modelData
                required property int index
                readonly property var it: modelData
                readonly property bool isHeader: !!it.header
                readonly property bool isCurrent: it.kind === "queue" ? !!it.current
                  : (!!it.videoId && !!root.shownSong && it.videoId === root.shownSong.videoId)
                width: list.width
                height: isHeader ? Style.space(30) : Style.space(52)

                Text {
                  visible: rowItem.isHeader
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: Style.space(4)
                  x: Style.space(4)
                  width: parent.width - x - (showAll.visible ? showAll.width : 0) - Style.space(16)
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: rowItem.it.title || ""
                  color: root.a(root.fg, 0.55)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  font.capitalization: Font.AllUppercase
                  font.letterSpacing: 1
                }

                // "Show all" on shelves that have a full page of their own
                // (artist pages: Top songs, Albums, Singles, Videos). A shelf
                // there shows 5 or 10; this opens all of it in place.
                Text {
                  id: showAll
                  visible: rowItem.isHeader && !!rowItem.it.more
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.bottom: parent.bottom
                  anchors.bottomMargin: Style.space(4)
                  textFormat: Text.PlainText
                  text: "Show all"
                  color: showAllMouse.containsMouse ? Color.accent : root.a(root.fg, 0.55)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  MouseArea {
                    id: showAllMouse
                    anchors.fill: parent
                    enabled: parent.visible
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { keys.forceActiveFocus(); root.openItem(rowItem.it) }
                  }
                }

                Rectangle {
                  visible: !rowItem.isHeader
                  anchors.fill: parent
                  radius: Style.space(8)
                  // The arrow-key pick gets the kit's hover-cursor look (fill
                  // plus a faint border), like the built-in panels.
                  readonly property bool picked: root.cursor === rowItem.index
                  color: rowItem.isCurrent ? root.a(Color.accent, 0.16)
                    : (rowMouse.containsMouse || picked ? root.a(root.fg, 0.07) : "transparent")
                  border.width: picked ? 1 : 0
                  border.color: root.a(root.fg, 0.25)
                  Behavior on color { ColorAnimation { duration: 100 } }
                }

                MouseArea {
                  id: rowMouse
                  visible: !rowItem.isHeader
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  // A click leaves the search field, like on the web, so Space
                  // is play/pause again.
                  onClicked: { keys.forceActiveFocus(); root.openItem(rowItem.it) }
                }

                Row {
                  visible: !rowItem.isHeader
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(6)
                  anchors.rightMargin: Style.space(8)
                  spacing: Style.space(10)

                  ClippingRectangle {
                    anchors.verticalCenter: parent.verticalCenter
                    // Songs already played (Queue tab) are dimmed, so a song
                    // that comes round again does not read as a duplicate. Art
                    // and text only: the hover buttons stay at full strength.
                    opacity: rowItem.it.played ? 0.5 : 1
                    width: Style.space(42)
                    height: width
                    radius: rowItem.it.kind === "artist" ? width / 2 : Style.space(6)
                    color: root.a(root.fg, 0.08)
                    ArtImage {
                      anchors.fill: parent
                      url: rowItem.isHeader ? "" : (rowItem.it.thumb || "")
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                      sourceSize.width: Style.space(84)
                      sourceSize.height: Style.space(84)
                    }
                  }

                  Column {
                    anchors.verticalCenter: parent.verticalCenter
                    opacity: rowItem.it.played ? 0.5 : 1
                    width: parent.width - Style.space(42) - actions.width - dur.width - parent.spacing * 3
                    spacing: Style.space(2)
                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: rowItem.it.title || ""
                      color: rowItem.isCurrent ? Color.accent : root.fg
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.bodySmall
                      font.bold: rowItem.isCurrent
                      elide: Text.ElideRight
                    }
                    Text {
                      width: parent.width
                      textFormat: Text.PlainText
                      text: rowItem.it.subtitle || ""
                      visible: text !== ""
                      color: root.a(root.fg, 0.55)
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      elide: Text.ElideRight
                    }
                  }

                  Text {
                    id: dur
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: rowMouse.containsMouse || actionsHover.hovered ? "" : (rowItem.it.duration || "")
                    // Fits h:mm:ss ("1:02:03" is 59 px in MartianMono at
                    // base-size 14); 40 was sized for m:ss only and long mixes
                    // ran into the title.
                    width: Style.space(52)
                    horizontalAlignment: Text.AlignRight
                    color: root.a(root.fg, 0.45)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.features: { "tnum": 1 }
                  }

                  // Hover actions: play now, play next, add to queue / remove.
                  Row {
                    id: actions
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 0
                    opacity: rowMouse.containsMouse || actionsHover.hovered ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 100 } }
                    HoverHandler { id: actionsHover }
                    IconBtn {
                      // Albums, playlists, artists and podcasts, whenever
                      // playItem can start them: their own play endpoint, a
                      // playlist, or a page for Page.js playPage to press play
                      // on (artist tiles have no endpoint of their own and only
                      // showed "That can't be played directly").
                      visible: (rowItem.it.kind === "album" || rowItem.it.kind === "playlist"
                          || rowItem.it.kind === "artist" || rowItem.it.kind === "podcast")
                        && (!!rowItem.it.play || !!rowItem.it.playlistId || !!rowItem.it.browseId)
                      glyph: root.gPlay; size: Style.font.icon; tip: "Play"
                      onActivated: root.playItem(rowItem.it)
                    }
                    IconBtn {
                      visible: !!rowItem.it.videoId && rowItem.it.kind !== "queue"
                      glyph: root.gPlayNext; size: Style.font.icon; tip: "Play next"
                      onActivated: root.queueAdd(rowItem.it, true)
                    }
                    IconBtn {
                      visible: !!rowItem.it.videoId && rowItem.it.kind !== "queue"
                      glyph: root.gQueueAdd; size: Style.font.icon; tip: "Add to queue"
                      onActivated: root.queueAdd(rowItem.it, false)
                    }
                    IconBtn {
                      visible: rowItem.it.kind === "queue" && !rowItem.isCurrent
                      glyph: root.gClose; size: Style.font.icon; tip: "Remove from queue"
                      onActivated: root.queueAct("remove", rowItem.it)
                    }
                  }
                }
              }
            }
            TopButton { view: list }

            // ---------------- lyrics ----------------
            // Apple Music's way (asked for 2026-09-24): big bold lines, the
            // sung line bright and a touch larger, the rest faded back and
            // softly blurred; the list glides to keep the sung line a third
            // of the way down; breathing dots in instrumental breaks; tap a
            // line to jump there; scrolling by hand pauses the follow for a
            // few seconds. Songs without timed lyrics show YouTube Music's
            // plain text in the same type.
            //
            // Built only while the Lyrics tab is open (a Loader): the shell
            // crashes in Qt 6.11's JS garbage collector when what plugins build
            // at shell start shifts its timing (see Page.js), and with the
            // lyrics view built eagerly 1 of 12 test starts crashed.
            Loader {
              anchors.fill: parent
              active: root.view === "lyrics" && !root.searching && !root.currentPage
              sourceComponent: lyricsComponent
            }
            Component {
              id: lyricsComponent
            Item {
              id: lyricsView
              anchors.fill: parent
              readonly property int lineSize: Math.round(Style.font.display * 0.85)
              // Words are laid out one by one, so the space between them is
              // added by hand.
              TextMetrics { id: spaceMetrics; font.family: root.fontFamily; font.pixelSize: lyricsView.lineSize; font.bold: true; text: " " }
              property bool follow: true
              Timer { id: lyricsFollowBack; interval: 3500; onTriggered: { lyricsView.follow = true; lyricsView.glideTo(root.lyricIndex) } }
              // Where the sung line sits: a third of the way down.
              function glideTo(i) {
                if (!follow || i < 0 || !lyricsList.count) return
                var it = lyricsList.itemAtIndex(i)
                if (!it) { lyricsList.positionViewAtIndex(i, ListView.Center); return }
                var target = it.y - lyricsList.height * 0.3 + it.height / 2
                target = Math.max(lyricsList.originY, Math.min(target, lyricsList.originY + lyricsList.contentHeight - lyricsList.height))
                lyricsGlide.to = target
                lyricsGlide.restart()
              }
              Connections {
                target: root
                function onLyricIndexChanged() { lyricsView.glideTo(root.lyricIndex) }
                function onLyricLinesChanged() { lyricsList.contentY = lyricsList.originY; lyricsView.follow = true }
              }

              Text {
                anchors.centerIn: parent
                width: parent.width - Style.space(40)
                visible: root.lyricsState !== "ready"
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.Wrap
                textFormat: Text.PlainText
                text: root.lyricsState === "loading" ? "Loading lyrics…"
                  : root.lyricsState === "none" ? "No lyrics for this song."
                  : "Play a song to see its lyrics."
                color: root.a(root.fg, 0.55)
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }

              ListView {
                id: lyricsList
                anchors.fill: parent
                visible: root.lyricsState === "ready"
                clip: true
                model: root.lyricLines
                spacing: Style.space(14)
                cacheBuffer: 6000
                boundsBehavior: Flickable.StopAtBounds
                // Room above the first line and below the last, so each can
                // reach the one-third mark.
                header: Item { width: 1; height: lyricsList.height * 0.3 }
                footer: Item {
                  width: lyricsList.width
                  height: lyricsList.height * 0.6
                  Text {
                    x: Style.space(4)
                    y: Style.space(18)
                    visible: root.lyricsSource !== ""
                    textFormat: Text.PlainText
                    text: root.lyricsSource === "LRCLIB" ? "Timed lyrics from LRCLIB"
                      : root.lyricsSource === "KuGou" ? "Word-timed lyrics from KuGou" : root.lyricsSource
                    color: root.a(root.fg, 0.4)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
                NumberAnimation { id: lyricsGlide; target: lyricsList; property: "contentY"; duration: 650; easing.type: Easing.OutCubic }
                onMovementStarted: { lyricsGlide.stop(); lyricsView.follow = false; lyricsFollowBack.restart() }
                onMovementEnded: lyricsFollowBack.restart()

                // Soft top and bottom edges, like the Music app. Threshold 0.5
                // with spread 1 maps the mask's alpha straight through; the
                // first 0.0 left the mask with no effect at all (measured
                // offline 2026-09-24: every pixel stayed fully visible).
                layer.enabled: true
                layer.effect: MultiEffect {
                  maskEnabled: true
                  maskSource: lyricsFade
                  maskThresholdMin: 0.5
                  maskSpreadAtMin: 1.0
                }

                delegate: Item {
                  id: lyr
                  required property var modelData
                  required property int index
                  readonly property bool timed: root.lyricsSynced
                  readonly property bool sung: timed && root.lyricIndex === index
                  readonly property int dist: timed && root.lyricIndex >= 0 ? Math.abs(index - root.lyricIndex) : 0
                  readonly property bool gap: modelData.text === ""
                  // A break (an empty timed line) of 3 s or more is a row of three
                  // dots that stays in the list like a line, faint when not sung
                  // and tappable to jump back to it (asked for 2026-09-24). A
                  // shorter gap is only spacing, as in the Music app.
                  readonly property real endT: index + 1 < root.lyricLines.length ? root.lyricLines[index + 1].t : root.duration
                  readonly property bool pause: gap && timed && endT - modelData.t >= 3
                  // How far through the break the song is (0 to 1), only while
                  // it is the sung one; the same 0.2 s lead as the lines.
                  readonly property real prog: sung && pause
                    ? Math.max(0, Math.min(1, (root.lyricsNow + 0.2 - modelData.t) / Math.max(0.1, endT - modelData.t))) : 0
                  // Same fading as a line that is not being sung.
                  readonly property real restOpacity: !lyricsView.follow ? 0.5
                    : (lyrMouse.containsMouse ? 0.45 : (root.lyricIndex < 0 ? 0.4 : 0.14))
                  width: lyricsList.width
                  height: gap ? (pause ? Style.space(44) : Style.space(timed ? 4 : 8)) : lineBox.height
                  Behavior on height { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }

                  // Word by word (asked for 2026-09-24; when KuGou has the song):
                  // on the sung line each word fills from faint to bright as it
                  // is sung, with a soft leading edge, and rises a hair; the
                  // line settles back when it is done. Other lines look as
                  // they always did.
                  readonly property bool wordy: !gap && !!modelData.words
                  // The sung line's words still to come: brighter than the
                  // other lines, well below a sung word.
                  property real restWord: sung ? 0.35 : 1
                  Behavior on restWord { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
                  property real lift: sung ? 1 : 0
                  Behavior on lift { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }

                  Item {
                    id: lineBox
                    visible: !lyr.gap
                    width: parent.width - Style.space(24)
                    x: Style.space(4)
                    height: lyr.wordy ? wordFlow.height : lineText.implicitHeight
                    transformOrigin: Item.Left
                    // Lines not being sung sit far back (0.14; asked for even less
                    // of them than the first 0.3, 2026-09-24), come up to 0.5
                    // while scrolling by hand to read ahead, and to 0.45 under
                    // the pointer. Before the first line all show at 0.4.
                    opacity: !lyr.timed ? 0.92 : (lyr.sung ? 1 : (!lyricsView.follow ? 0.5
                      : (lyrMouse.containsMouse ? 0.45 : (root.lyricIndex < 0 ? 0.4 : 0.14))))
                    scale: lyr.sung ? 1.0 : 0.97
                    Behavior on opacity { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
                    Behavior on scale { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
                    // Lines away from the sung one go slightly soft; sharp again
                    // while scrolling by hand, to read ahead.
                    layer.enabled: lyr.timed && lyricsView.follow && lyr.dist >= 2
                    layer.effect: MultiEffect { blurEnabled: true; blur: Math.min(1, (lyr.dist - 1) * 0.35); blurMax: 14 }

                    Text {
                      id: lineText
                      visible: !lyr.wordy
                      width: parent.width
                      textFormat: Text.PlainText
                      wrapMode: Text.Wrap
                      text: lyr.wordy ? "" : lyr.modelData.text
                      color: root.fg
                      font.family: root.fontFamily
                      font.pixelSize: lyricsView.lineSize
                      font.bold: true
                      lineHeight: 1.08
                    }

                    Flow {
                      id: wordFlow
                      visible: lyr.wordy
                      width: parent.width
                      Repeater {
                        model: lyr.wordy ? lyr.modelData.words : 0
                        Item {
                          id: wd
                          required property var modelData
                          // 0 to 1: how much of the word is sung. Only the sung
                          // line reads the clock; lines passed stay full, lines
                          // to come stay empty.
                          readonly property real fill: lyr.sung ? root.wordFill(modelData, root.lyricsNow + root.wordLead)
                            : (lyr.index < root.lyricIndex ? 1 : 0)
                          readonly property real rise: -lyricsView.lineSize * 0.06 * Math.min(1, fill * 2) * lyr.lift
                          width: wordBase.implicitWidth + (modelData.gap ? spaceMetrics.advanceWidth : 0)
                          height: wordBase.implicitHeight
                          Text {
                            id: wordBase
                            y: wd.rise
                            textFormat: Text.PlainText
                            text: wd.modelData.text
                            color: root.fg
                            opacity: lyr.restWord
                            font.family: root.fontFamily
                            font.pixelSize: lyricsView.lineSize
                            font.bold: true
                            lineHeight: 1.08
                          }
                          // The bright copy, built only while it shows: on the
                          // sung line, and on the line just passed until its
                          // words are back to full (so it never dips).
                          Loader {
                            active: wd.fill > 0 && (lyr.sung || lyr.restWord < 0.999)
                            y: wd.rise
                            sourceComponent: Item {
                              width: wordBase.implicitWidth
                              height: wordBase.implicitHeight
                              readonly property real soft: Math.min(width * 0.6, lyricsView.lineSize * 0.7)
                              Text {
                                id: wordLit
                                anchors.fill: parent
                                textFormat: Text.PlainText
                                text: wd.modelData.text
                                color: root.fg
                                font.family: root.fontFamily
                                font.pixelSize: lyricsView.lineSize
                                font.bold: true
                                lineHeight: 1.08
                                // Mid-word, a soft-edged mask; whole, just the text.
                                layer.enabled: wd.fill < 1
                                // 0.5 with spread 1 maps the mask's alpha straight
                                // through; 0.0 with spread 1 shows everything
                                // (measured offline, Qt 6.11).
                                layer.effect: MultiEffect {
                                  maskEnabled: true
                                  maskSource: wordMask
                                  maskThresholdMin: 0.5
                                  maskSpreadAtMin: 1.0
                                }
                              }
                              Item {
                                id: wordMask
                                anchors.fill: parent
                                visible: false
                                layer.enabled: true
                                readonly property real edge: wd.fill * (width + parent.soft) - parent.soft
                                Rectangle { width: Math.max(0, wordMask.edge); height: parent.height; color: "white" }
                                Rectangle {
                                  x: wordMask.edge
                                  width: parent.parent.soft
                                  height: parent.height
                                  gradient: Gradient {
                                    orientation: Gradient.Horizontal
                                    GradientStop { position: 0.0; color: "white" }
                                    GradientStop { position: 1.0; color: "transparent" }
                                  }
                                }
                              }
                            }
                          }
                        }
                      }
                    }
                  }

                  // The break's dots, the Music app's way: they do not loop. Each
                  // fills in turn across the break (the first over its first
                  // third, and so on), so the last lights as the next line
                  // comes; the group breathes gently meanwhile, and shrinks
                  // away over the last tenth of the break.
                  Row {
                    id: dots
                    visible: lyr.pause
                    x: Style.space(6)
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(10)
                    transformOrigin: Item.Left
                    readonly property real endFade: lyr.prog > 0.9 ? Math.max(0, 1 - (lyr.prog - 0.9) / 0.1) : 1
                    property real breath: 1
                    SequentialAnimation on breath {
                      running: lyr.sung && lyr.pause && root.isPlaying
                      loops: Animation.Infinite
                      NumberAnimation { to: 1.08; duration: 1300; easing.type: Easing.InOutSine }
                      NumberAnimation { to: 1.0; duration: 1300; easing.type: Easing.InOutSine }
                    }
                    opacity: lyr.sung ? dots.endFade : lyr.restOpacity
                    scale: lyr.sung ? dots.breath * (0.55 + 0.45 * dots.endFade) : 0.97
                    Behavior on opacity { NumberAnimation { duration: 380; easing.type: Easing.OutCubic } }
                    Repeater {
                      model: 3
                      Rectangle {
                        required property int index
                        // 0 to 1: how full this dot is. A break not being sung
                        // shows all three alike (faint, via the row).
                        readonly property real fill: lyr.sung ? Math.max(0, Math.min(1, lyr.prog * 3 - index)) : 1
                        width: Style.space(12); height: width; radius: width / 2
                        color: root.fg
                        opacity: 0.28 + 0.72 * fill
                        scale: 0.82 + 0.18 * fill
                      }
                    }
                  }

                  MouseArea {
                    id: lyrMouse
                    anchors.fill: parent
                    enabled: lyr.timed && (!lyr.gap || lyr.pause)
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: { lyricsView.follow = true; lyricsFollowBack.stop(); root.seekLyric(lyr.index) }
                  }
                }
              }
              // Mask for the soft edges: clear at the very top and bottom.
              Item {
                id: lyricsFade
                anchors.fill: lyricsList
                visible: false
                layer.enabled: true
                Rectangle {
                  anchors.fill: parent
                  gradient: Gradient {
                    GradientStop { position: 0.0; color: "transparent" }
                    GradientStop { position: 0.14; color: "white" }
                    GradientStop { position: 0.82; color: "white" }
                    GradientStop { position: 1.0; color: "transparent" }
                  }
                }
              }
            }
            }
          }
        }
      }

      // Small confirmation toast at the bottom. Capped to the panel's width
      // with an ellipsis: a 100-character title plus "Added to queue: " was
      // about 975 px against about 921 px of panel (measured offline).
      Rectangle {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: Style.space(4)
        visible: opacity > 0
        opacity: root.toastText !== "" ? 1 : 0
        Behavior on opacity { NumberAnimation { duration: 160 } }
        width: toastT.width + Style.space(24)
        height: toastT.implicitHeight + Style.space(12)
        radius: height / 2
        color: Color.popups.background
        border.width: 1
        border.color: root.a(Color.accent, 0.6)
        Text {
          id: toastT
          anchors.centerIn: parent
          width: Math.min(implicitWidth, Math.max(0, keys.width - Style.space(64)))
          elide: Text.ElideRight
          textFormat: Text.PlainText
          text: root.toastText
          color: root.fg
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
