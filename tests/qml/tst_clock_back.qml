import QtQuick
import QtTest
import YtmTest
import "../.."

// When the wall clock steps back (NTP after a sleep, a manual change), every
// time the widget stored is suddenly in the future and "now - then" goes
// negative. A negative age must count as stale, never as "just now": the seek
// bar must not run on, a stall must still be checked, a page call must still
// time out, the volume must follow the app, the offline page must still be
// retried, and two position pushes must not read as "playing".
TestCase {
  id: tc
  name: "ClockBack"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }
  readonly property double hour: 3600000
  function init() { Harness.reset() }

  function playing(w) {
    w.lastSong = null
    w.song = { title: "Fake Song", artist: "Test Artist", videoId: "abcDEF_12-x", songDuration: 200 }
    w.appUp = true
    w.songReal = true
    w.isPlaying = true
    w.position = 10
  }
  function test_age_of_a_future_time_is_infinite() {
    var w = createTemporaryObject(widgetComp, tc)
    compare(w.ageMs(Date.now() + hour), Infinity)
    verify(w.ageMs(Date.now() - 500) >= 500)
  }
  function test_seek_bar_does_not_run_on() {
    var w = createTemporaryObject(widgetComp, tc)
    playing(w)
    w.open()
    w.lastPush = Date.now() + hour
    wait(800)
    compare(w.position, 10)
  }
  function test_stall_is_still_checked() {
    var w = createTemporaryObject(widgetComp, tc)
    Harness.cdpResponder = function(method, params, expr) { return method === "Runtime.evaluate" ? null : {} }
    playing(w)
    w.lastPush = Date.now() + hour
    tryVerify(function() {
      return Harness.cdpSent.some(function(m) { return m.method === "Runtime.evaluate" && String(m.params.expression).indexOf("__nicYtm.state()") >= 0 })
    }, 4500, "the stall check never asked the page")
  }
  function test_page_call_still_times_out() {
    var w = createTemporaryObject(widgetComp, tc)
    Harness.cdpResponder = function(method) { return method === "Runtime.evaluate" ? undefined : {} }   // never answers
    w.appUp = true
    var res = { done: false, err: "" }
    w.page("window.__nicYtm.ready()", function(v, err) { res.done = true; res.err = err })
    tryVerify(function() { return Object.keys(w.cdpDeadline).length === 1 }, 1000)
    var d = w.cdpDeadline
    for (var k in d) d[k] = Date.now() + hour
    w.cdpDeadline = d
    tryVerify(function() { return res.done }, 6500, "a page call never timed out after the clock stepped back")
    verify(res.err !== "")
  }
  function test_volume_follows_the_app() {
    var w = createTemporaryObject(widgetComp, tc)
    w.volSent = -1
    w.volSentAt = Date.now() + hour
    w.takeAppVolume(20)
    compare(w.volume, 50)
  }
  function test_offline_page_is_still_retried() {
    var w = createTemporaryObject(widgetComp, tc)
    Harness.cdpResponder = function(method) { return {} }
    w.appUp = true
    w.open()
    w.lastPageRetry = Date.now() + hour
    w.retryAppPage()
    tryVerify(function() { return Harness.cdpSent.some(function(m) { return m.method === "Page.navigate" }) }, 2000)
  }
  function test_two_pushes_do_not_read_as_playing() {
    var w = createTemporaryObject(widgetComp, tc)
    wait(30)
    var ws = Harness.sockets[Harness.sockets.length - 1].ws
    ws.open()
    ws.push({ type: "PLAYER_INFO", song: { title: "Fake Song", videoId: "abcDEF_12-x", songDuration: 200 }, position: 30, isPlaying: false })
    compare(w.appUp, true)
    compare(w.isPlaying, false)
    w.posPushPos = 30
    w.posPushAt = Date.now() + hour
    ws.push({ type: "POSITION_CHANGED", position: 31 })
    compare(w.isPlaying, false)
  }
}
