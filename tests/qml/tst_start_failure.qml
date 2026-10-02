import QtQuick
import QtTest
import YtmTest
import "../.."

// The widget starts the app through tools/cdp-bridge. A bridge that stops at
// once with an error (no python3, a broken runtime folder, a second bridge
// racing it) must show "didn't start" right away, not after the 40 s start
// timeout. A bridge that keeps running is left alone, in its own session.
TestCase {
  id: tc
  name: "StartFailure"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }
  readonly property string tokenPath: "/nonexistent/home/.local/state/omarchy/nic-youtube-music/token"
  function make() {
    Harness.reset()
    Harness.files[tokenPath] = "fake-token-for-tests"
    var w = createTemporaryObject(widgetComp, tc)
    tryCompare(w, "tokenChecked", true, 1000)
    return w
  }
  function launches() {
    return Harness.procsMatching("cdp-bridge").length + Harness.detachedMatching("cdp-bridge").length
  }

  function test_early_error_shows_at_once() {
    var w = make()
    Harness.procResponder = function(cmd) { return JSON.stringify(cmd).indexOf("cdp-bridge") >= 0 ? { code: 1 } : null }
    w.open()
    w.wake("")
    compare(w.starting, true)
    tryCompare(w, "startFailed", true, 3000)
    compare(w.starting, false)
    compare(launches(), 1)
  }
  function test_bridge_that_keeps_running_is_fine() {
    var w = make()
    // The launcher watches the bridge for a few seconds, then lets it be.
    Harness.procResponder = function(cmd) { return JSON.stringify(cmd).indexOf("cdp-bridge") >= 0 ? { code: 0, delay: 200 } : null }
    w.wake("")
    tryVerify(function() { return launches() === 1 }, 2000)
    wait(500)
    compare(w.startFailed, false)
    compare(w.starting, true)
    // It runs in a session of its own, so a shell restart does not take the app down.
    var cmd = Harness.procsMatching("cdp-bridge")[0].command
    verify(JSON.stringify(cmd).indexOf("setsid") >= 0)
  }
}
