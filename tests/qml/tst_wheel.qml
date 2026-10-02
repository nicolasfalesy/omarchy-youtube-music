import QtQuick
import QtTest
import YtmTest
import "../.."

// Scrolling on the bar skips songs: up = previous, down = next. One step per
// 120 units (a mouse notch); after a skip nothing more until the wheel has
// been still for about 300 ms, so one trackpad flick is one skip. Only with
// one of the user's songs loaded: a scroll never starts the app or music.
TestCase {
  id: tc
  name: "Wheel"
  width: 900; height: 700
  visible: true
  when: windowShown
  Component { id: widgetComp; Widget {} }
  readonly property string api: "http://127.0.0.1:26599/api/v1"
  function init() { Harness.reset(); post("/reset") }

  function post(path) {
    var x = new XMLHttpRequest(), done = false
    x.onreadystatechange = function() { if (x.readyState === XMLHttpRequest.DONE) done = true }
    x.open("POST", api + path); x.send()
    tryVerify(function() { return done }, 2000)
  }
  function posts() {
    var x = new XMLHttpRequest(), r = null
    x.onreadystatechange = function() { if (x.readyState === XMLHttpRequest.DONE) r = JSON.parse(x.responseText).posts }
    x.open("GET", api + "/stats"); x.send()
    tryVerify(function() { return r !== null }, 2000)
    return r
  }
  function live() {
    var w = createTemporaryObject(widgetComp, tc, { api: api })
    w.song = { title: "Fake Song", artist: "Test Artist", videoId: "abcDEF_12-x", songDuration: 200 }
    w.appUp = true
    w.songReal = true
    return w
  }
  function test_notch_down_is_next() {
    var w = live()
    mouseWheel(w, 5, 5, 0, -120)
    wait(200)
    compare(posts()["/api/v1/next"], 1)
    compare(posts()["/api/v1/previous"], undefined)
  }
  function test_notch_up_is_previous() {
    var w = live()
    mouseWheel(w, 5, 5, 0, 120)
    wait(200)
    compare(posts()["/api/v1/previous"], 1)
  }
  function test_flick_is_one_skip() {
    var w = live()
    for (var i = 0; i < 40; i++) { mouseWheel(w, 5, 5, 0, -30); wait(10) }
    wait(200)
    compare(posts()["/api/v1/next"], 1)
    // Still again, then another notch: another skip.
    wait(400)
    mouseWheel(w, 5, 5, 0, -120)
    wait(200)
    compare(posts()["/api/v1/next"], 2)
  }
  function test_nothing_loaded_does_nothing() {
    var w = createTemporaryObject(widgetComp, tc, { api: api })
    mouseWheel(w, 5, 5, 0, -120)
    wait(300)
    compare(w.starting, false)
    compare(posts()["/api/v1/next"], undefined)
    compare(Harness.procsMatching("cdp-bridge").length, 0)
  }
}
