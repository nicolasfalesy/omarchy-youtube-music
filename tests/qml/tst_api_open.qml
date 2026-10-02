import QtQuick
import QtTest
import YtmTest
import "../.."

// An app whose API answers without the token is open to any program. The
// warning pointed at running tools/setup in a terminal; it now offers the
// panel's own Set up, as a button in the toast.
TestCase {
  id: tc
  name: "ApiOpen"
  width: 900; height: 700
  visible: true
  when: windowShown
  Component { id: widgetComp; Widget {} }
  function init() { Harness.reset() }

  function test_warning_offers_set_up() {
    var w = createTemporaryObject(widgetComp, tc)
    w.appUp = true
    w.apiOpen = true
    w.open()
    verify(w.toastText !== "")
    verify(w.toastText.indexOf("tools/setup") < 0, "still points at a terminal step: " + w.toastText)
    // The toast fades in.
    tryVerify(function() { return Harness.button(w, "Set up") !== null }, 1000, "no Set up button in the toast")
    var b = Harness.button(w, "Set up")
    wait(250)
    mouseMove(b); wait(50)
    mouseClick(b)
    tryVerify(function() { return Harness.procsMatching("tools/setup").length === 1 }, 2000)
  }
}
