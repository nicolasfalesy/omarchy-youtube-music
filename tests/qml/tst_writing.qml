import QtQuick
import QtTest
import YtmTest
import "../.."

// What the panel says: full sentences, nothing untrue, nothing that reads
// wrong in the situation it shows in.
TestCase {
  id: tc
  name: "Writing"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }
  readonly property string tokenPath: "/nonexistent/home/.local/state/omarchy/nic-youtube-music/token"
  function init() { Harness.reset() }

  function test_empty_page_is_a_sentence() {
    Harness.cdpResponder = function(method, params, expr) {
      if (method !== "Runtime.evaluate") return {}
      if (expr.indexOf("browse(") >= 0) return { header: null, sections: [] }
      if (expr.indexOf("ready()") >= 0 || expr.indexOf("signedIn()") >= 0) return true
      if (expr.indexOf("queue(") >= 0) return { items: [], upNext: [], sig: "" }
      return null
    }
    var w = createTemporaryObject(widgetComp, tc)
    w.appUp = true
    w.open()
    tryCompare(w, "listError", "Nothing here yet.", 2000)
  }
  // "Start it again to keep listening." read wrong right after a first
  // install, when nothing was ever listened to.
  function test_closed_screen_after_first_install() {
    Harness.files[tokenPath] = "fake-token-for-tests"
    var w = createTemporaryObject(widgetComp, tc)
    tryCompare(w, "tokenChecked", true, 1000)
    verify(w.closedHint.indexOf("again") < 0, w.closedHint)
    w.markUp()
    var ws = Harness.sockets[Harness.sockets.length - 1].ws
    ws.open(); ws.drop()
    compare(w.appUp, false)
    compare(w.closedHint, "Start it again to keep listening.")
  }
  // The install note never breaks a package name at its hyphen
  // ("(pear-" / "desktop)" across two lines).
  function test_names_do_not_break_at_hyphens() {
    var w = createTemporaryObject(widgetComp, tc)
    var t = w.installText
    var bad = []
    for (var width = 160; width <= 640; width += 3) {
      probe.width = width
      probe.text = t
      for (var y = 1; y < probe.contentHeight; y += probe.lineH) {
        var at = probe.positionAt(0, y)
        if (at > 0 && t.charAt(at - 1) === "-" ) bad.push(width + ":" + t.slice(Math.max(0, at - 6), at + 6))
        if (at > 1 && t.charAt(at - 1) === "⁠" && t.charAt(at - 2) === "-") bad.push(width + ":" + t.slice(Math.max(0, at - 6), at + 6))
      }
    }
    compare(bad.length, 0, "broke after a hyphen: " + bad.slice(0, 3).join(" | "))
  }
  function test_setup_note_says_what_it_changes() {
    var w = createTemporaryObject(widgetComp, tc)
    var t = w.setupText
    verify(t.indexOf("doesn't touch anything else") < 0)
    verify(/resume/i.test(t), "resume-on-start is not mentioned")
    verify(t.indexOf("youtube-music-flags.conf") >= 0, "the flags file is not mentioned")
  }
  // TextEdit lays text out like Text and can say where each line starts.
  TextEdit {
    id: probe
    readOnly: true
    textFormat: TextEdit.PlainText
    wrapMode: TextEdit.Wrap
    font.pixelSize: 13
    readonly property real lineH: fm.height
    FontMetrics { id: fm; font: probe.font }
  }
}
