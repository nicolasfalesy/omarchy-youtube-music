import QtQuick
import QtTest
import YtmTest
import "../.."

// Lyrics are kept per song for the session, but at most 50 songs (oldest out),
// and "no lyrics" is kept only when the services really said so (an answer, or
// HTTP 404 and the like). A failed fetch (no network, a timeout, a server
// error) is not remembered, so the song is looked up again next time.
TestCase {
  id: tc
  name: "LyricsCache"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }
  function init() { Harness.reset() }

  // How each lyrics fetch ends: "none" = every service answers "not found",
  // "down" = curl cannot connect, "503" = a server error.
  function respond(mode) {
    Harness.procResponder = function(cmd) {
      if (cmd[0] !== "curl") return null
      var url = cmd[cmd.length - 1]
      if (mode === "down") return { code: 7, err: "curl: (7) Failed to connect\n000\n" }
      if (mode === "503") return { code: 22, err: "curl: (22) The requested URL returned error: 503\n503\n" }
      if (url.indexOf("lrclib.net/api/get") >= 0) return { code: 22, err: "curl: (22) The requested URL returned error: 404\n404\n" }
      if (url.indexOf("lrclib.net/api/search") >= 0) return { out: "[]", err: "200\n" }
      if (url.indexOf("krcs.kugou.com") >= 0) return { out: JSON.stringify({ candidates: [] }), err: "200\n" }
      return { code: 22, err: "404\n" }
    }
  }
  function song(i) { return { title: "Fake Song " + i, artist: "Test Artist", videoId: "vid" + i, songDuration: 180 } }
  function lookUp(w, i) {
    w.lastSong = song(i)
    w.loadLyrics()
    tryCompare(w, "lyricsState", "none", 3000)
  }
  function curls() { return Harness.procsMatching("curl").length }

  function test_real_not_found_is_kept() {
    var w = createTemporaryObject(widgetComp, tc)
    respond("none")
    lookUp(w, 1); lookUp(w, 2)
    var n = curls()
    lookUp(w, 1)
    compare(curls(), n, "a song already known to have no lyrics was fetched again")
  }
  function test_network_failure_is_not_kept() {
    var w = createTemporaryObject(widgetComp, tc)
    respond("down")
    lookUp(w, 1); lookUp(w, 2)
    var n = curls()
    lookUp(w, 1)
    verify(curls() > n, "a song that failed for lack of network was never looked up again")
  }
  function test_server_error_is_not_kept() {
    var w = createTemporaryObject(widgetComp, tc)
    respond("503")
    lookUp(w, 1); lookUp(w, 2)
    var n = curls()
    lookUp(w, 1)
    verify(curls() > n)
  }
  function test_at_most_50_songs() {
    var w = createTemporaryObject(widgetComp, tc)
    respond("none")
    for (var i = 1; i <= 60; i++) lookUp(w, i)
    compare(Object.keys(w.lyricsCache).length, 50)
    verify(w.lyricsCache["vid1"] === undefined)
    verify(w.lyricsCache["vid60"] !== undefined)
  }
}
