import QtQuick
import QtTest
import YtmTest
import "../.."

// One player at a time: when YouTube Music starts playing, World Radio is
// stopped (over its IPC, only while it plays). That check spawned sh,
// omarchy-shell and jq on every start of playback, autoplay steps included
// (the app pauses for a moment at each song's end). It now runs only when the
// radio can be on: a start after a real stop, or after an outside pause (the
// radio pauses this widget whenever a station starts).
TestCase {
  id: tc
  name: "OnePlayer"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }
  function init() { Harness.reset() }
  function checks() { return Harness.detachedMatching("nic.world-radio").length }
  function make() { var w = createTemporaryObject(widgetComp, tc); w.appUp = true; return w }

  // Order 1: the radio plays, then YouTube Music starts.
  function test_start_checks_the_radio() {
    var w = make()
    w.isPlaying = true
    compare(checks(), 1)
  }
  function test_autoplay_step_does_not() {
    var w = make()
    w.isPlaying = true
    w.isPlaying = false      // the song ends
    w.isPlaying = true       // the next one starts
    compare(checks(), 1)
  }
  // Order 2: YouTube Music plays, a station starts (it pauses this widget
  // through the pause IPC), then YouTube Music is started again at once.
  function test_station_started_meanwhile() {
    var w = make()
    w.isPlaying = true
    w.pauseOnly()
    compare(w.isPlaying, false)
    w.isPlaying = true
    compare(checks(), 2)
  }
  function test_after_a_real_stop() {
    var w = make()
    w.isPlaying = true
    w.isPlaying = false
    w.stoppedPlayingAt = Date.now() - 6000
    w.isPlaying = true
    compare(checks(), 2)
  }
}
