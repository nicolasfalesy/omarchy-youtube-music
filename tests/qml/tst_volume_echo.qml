import QtQuick
import QtTest
import YtmTest
import "../.."

// The app reports volume on a loudness curve (sent 57, reported 26), so the
// widget maps reports back through that curve. Upstream pear-desktop PR #4672
// makes the app report the value it was given; an echo equal to what the
// widget last sent must then be taken as it is, not curved a second time.
TestCase {
  id: tc
  name: "VolumeEcho"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }
  function init() { Harness.reset() }

  function test_echo_of_the_sent_value() {
    var w = createTemporaryObject(widgetComp, tc)
    w.setVolume(57)
    w.volSentAt = Date.now() - 2000      // a late echo, past the 1 s window
    w.takeAppVolume(57)
    compare(w.volume, 57)
  }
  function test_curved_echo_still_works() {
    var w = createTemporaryObject(widgetComp, tc)
    w.setVolume(57)
    w.takeAppVolume(26)                  // the app as it is today
    compare(w.volume, 57)
  }
  function test_change_in_the_app_window() {
    var w = createTemporaryObject(widgetComp, tc)
    w.volSent = -1
    w.takeAppVolume(20)
    compare(w.volume, 50)
  }
}
