import QtQuick
import QtTest
import YtmTest
import "../.."

// last.json (the remembered song) is read on every shell start. Only the
// shape saveLast() writes may come back out of it: a size cap, plain strings
// cut to 1000 characters, YouTube-shaped ids, sane numbers, and cover art only
// from Google's image hosts. Anything else is "nothing remembered".
TestCase {
  id: tc
  name: "LastFile"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }

  readonly property string dir: "/nonexistent/home/.local/state/omarchy/nic-youtube-music"
  readonly property string legacy: "/nonexistent/home/.local/state/omarchy/nic-youtube-music-last.json"
  function good() {
    return { title: "Fake Song", artist: "Test Artist", album: "Test Album",
      imageSrc: "https://lh3.googleusercontent.com/fake=w544-h544", videoId: "abcDEF_12-x",
      playlistId: "RDAMVMabcDEF_12-x", songDuration: 200, elapsedSeconds: 63 }
  }
  function load(obj) {
    Harness.reset()
    Harness.files[dir + "/last.json"] = typeof obj === "string" ? obj : JSON.stringify(obj)
    var w = createTemporaryObject(widgetComp, tc)
    wait(30)
    return w
  }

  function test_good_file() {
    var w = load(good())
    verify(w.lastSong !== null)
    compare(w.lastSong.title, "Fake Song")
    compare(w.lastSong.videoId, "abcDEF_12-x")
    compare(w.lastSong.playlistId, "RDAMVMabcDEF_12-x")
    compare(w.lastSong.imageSrc, "https://lh3.googleusercontent.com/fake=w544-h544")
    compare(w.position, 63)
  }
  function test_too_big_is_ignored() {
    var o = good(); o.title = new Array(70 * 1024).join("x")
    var w = load(o)
    compare(w.lastSong, null)
  }
  function test_long_strings_are_cut() {
    var o = good(); o.title = new Array(5001).join("t"); o.artist = new Array(3001).join("a"); o.album = new Array(2001).join("b")
    var w = load(o)
    compare(w.lastSong.title.length, 1000)
    compare(w.lastSong.artist.length, 1000)
    compare(w.lastSong.album.length, 1000)
  }
  function test_non_string_title_is_ignored() {
    var o = good(); o.title = { nested: true }
    compare(load(o).lastSong, null)
  }
  function test_bad_video_id_is_ignored() {
    var o = good(); o.videoId = "abc/../x"
    compare(load(o).lastSong, null)
    o = good(); o.videoId = new Array(66).join("a")
    compare(load(o).lastSong, null)
  }
  function test_bad_playlist_id_is_dropped() {
    var o = good(); o.playlistId = "PL<script>"
    var w = load(o)
    compare(w.lastSong.title, "Fake Song")
    compare(w.lastSong.playlistId, "")
  }
  function test_numbers_are_clamped() {
    var o = good(); o.elapsedSeconds = 1e308; o.songDuration = "abc"
    var w = load(o)
    compare(w.lastSong.elapsedSeconds, 86400)
    compare(w.lastSong.songDuration, 0)
    o = good(); o.elapsedSeconds = -40; o.songDuration = Infinity
    w = load(o)
    compare(w.lastSong.elapsedSeconds, 0)
    compare(w.lastSong.songDuration, 0)
  }
  function test_art_only_from_google_image_hosts() {
    var bad = ["file:///etc/hostname", "http://lh3.googleusercontent.com/x", "https://example.com/x.png",
      "https://lh3.googleusercontent.com@example.com/x", "https://lh3.googleusercontent.com:8443/x", "data:image/png;base64,AAAA"]
    for (var i = 0; i < bad.length; i++) {
      var o = good(); o.imageSrc = bad[i]
      compare(load(o).lastSong.imageSrc, "", bad[i])
    }
    var ok = ["https://i.ytimg.com/vi/abc/mqdefault.jpg", "https://yt3.ggpht.com/x", "https://www.gstatic.com/x.png"]
    for (i = 0; i < ok.length; i++) {
      o = good(); o.imageSrc = ok[i]
      compare(load(o).lastSong.imageSrc, ok[i])
    }
  }
}
