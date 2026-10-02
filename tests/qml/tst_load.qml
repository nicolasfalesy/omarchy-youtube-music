import QtQuick
import QtTest
import YtmTest
import "../.."

// The widget loads with nothing set up and no app: no errors, the bar shows
// the closed state, and the only things it reaches for are stubs (this also
// proves the stub modules, not the real Quickshell ones, were loaded).
TestCase {
  id: tc
  name: "Load"
  width: 900; height: 700
  when: windowShown

  Component { id: widgetComp; Widget {} }

  function test_load() {
    Harness.reset()
    var w = createTemporaryObject(widgetComp, tc)
    verify(w !== null)
    wait(50)
    compare(w.appUp, false)
    compare(w.hasSong, false)
    compare(w.barTip(), "YouTube Music is closed. Click to start it.")
    // firstRunInit (1.5 s): the install check and the window rule.
    tryVerify(function() { return Harness.procsMatching("YouTube Music/youtube-music").length === 1 }, 3000)
    verify(Harness.detachedMatching("nic-youtube-music").length === 1)
    // The probe went to the stub socket, without a token (none is set up).
    verify(Harness.sockets.length >= 1)
    compare(Harness.sockets[0].url, "ws://127.0.0.1:26538/api/v1/ws")
  }
}
