import QtQuick
import QtTest
import YtmTest
import "../.."

// The round play button with nothing loaded and nothing remembered starts
// Liked songs, as a right click on the bar and the play key do. It was
// disabled and dimmed then.
TestCase {
  id: tc
  name: "PlayButton"
  width: 900; height: 700
  visible: true
  when: windowShown
  Component { id: widgetComp; Widget {} }
  function init() { Harness.reset() }

  function test_starts_liked_songs() {
    Harness.cdpResponder = function(method, params, expr) {
      if (method !== "Runtime.evaluate") return {}
      if (expr.indexOf("ready()") >= 0) return true
      if (expr.indexOf("play(") >= 0) return true
      if (expr.indexOf("queue(") >= 0) return { items: [], upNext: [], sig: "" }
      if (expr.indexOf("signedIn()") >= 0) return true
      return null
    }
    var w = createTemporaryObject(widgetComp, tc)
    w.appUp = true
    w.open()
    compare(w.hasSong, false)
    var b = findChild(w, "roundPlay")
    verify(b !== null)
    verify(b.enabled, "the play button is disabled with nothing loaded")
    // Let the panel's own loads go out first, then a real pointer click.
    tryVerify(function() { return Harness.cdpSent.some(function(m) { return String(m.params && m.params.expression).indexOf("browse(") >= 0 }) }, 2000)
    mouseMove(b)
    wait(100)
    mouseClick(b)
    tryVerify(function() {
      return Harness.cdpSent.some(function(m) {
        return m.method === "Runtime.evaluate" && String(m.params.expression).indexOf('"playlistId":"LM"') >= 0
      })
    }, 3000, "Liked songs never started")
  }
}
