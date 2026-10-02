import QtQuick
import QtTest
import YtmTest
import "../.."

// The app turns the widget's token down (its settings were reset, or another
// setup minted a new one): it accepts each socket that carries the token and
// closes it at once (1008). That must say "Run Set up again" straight away,
// not "didn't start" after 40 s, and the app the widget started for nothing
// is quit again. An app started by hand is left alone.
TestCase {
  id: tc
  name: "TokenRejected"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }
  readonly property string tokenPath: "/nonexistent/home/.local/state/omarchy/nic-youtube-music/token"

  function make() {
    Harness.reset()
    Harness.files[tokenPath] = "fake-token-for-tests"
    Harness.procResponder = function(cmd) {
      var c = JSON.stringify(cmd)
      if (c.indexOf("ss -ltnHe") >= 0) return { out: "1000\nLISTEN 0 511 127.0.0.1:26538 0.0.0.0:* uid:1000 <->\n" }
      if (c.indexOf("cdp-bridge") >= 0) return null      // the bridge keeps running
      return null
    }
    Harness.cdpResponder = function(method) { return {} }
    var w = createTemporaryObject(widgetComp, tc)
    tryCompare(w, "tokenChecked", true, 1000)
    return w
  }
  function last() { return Harness.sockets[Harness.sockets.length - 1] }
  // The app answers every probe by accepting it and closing it again.
  function refuseAll(w, ms) {
    var until = Date.now() + ms, seen = 0
    while (Date.now() < until) {
      if (Harness.sockets.length > seen) {
        seen = Harness.sockets.length
        var s = last()
        s.ws.open(); s.ws.drop()
      }
      wait(50)
    }
  }
  function closes() { return Harness.cdpSent.filter(function(m) { return m.method === "Browser.close" }).length }

  function test_rejected_after_wake() {
    var w = make()
    w.open()
    w.wake("")
    refuseAll(w, 4000)
    compare(w.tokenRejected, true)
    compare(w.starting, false)
    compare(w.startFailed, false)
    compare(w.setupScreen, true)
    verify(closes() >= 1, "the app the widget started was left running")
  }
  function test_hand_started_app_is_left_alone() {
    var w = make()
    // No wake: the app was started some other way (its window opening makes
    // the widget probe every second for 20 s) and refuses the token.
    w.probeSoon()
    refuseAll(w, 4000)
    compare(w.tokenRejected, true)
    compare(closes(), 0)
  }
  function test_new_token_clears_it() {
    var w = make()
    w.probeSoon()
    refuseAll(w, 4000)
    compare(w.tokenRejected, true)
    Harness.files[tokenPath] = "another-fake-token"
    w.probe()
    tryCompare(w, "tokenRejected", false, 2000)
  }
}
