import QtQuick
import QtTest
import YtmTest
import "../.."

// Messages the widget raises while no panel is open (a play from the bar or a
// media key on an app that is not set up, a song that is gone, a start that
// failed) were drawn in the closed panel's toast, so nobody saw them. With no
// panel open they are a plain desktop notification now: notify-send with the
// app name "YouTube Music", "--" before the text, the text as one argument,
// no markup. With the panel open the in-panel toast shows, as before.
TestCase {
  id: tc
  name: "Notify"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }
  readonly property string tokenPath: "/nonexistent/home/.local/state/omarchy/nic-youtube-music/token"
  function init() { Harness.reset() }
  function notes() { return Harness.detached.filter(function(a) { return a[0] === "notify-send" }) }

  function test_closed_panel_notifies() {
    var w = createTemporaryObject(widgetComp, tc)
    tryCompare(w, "tokenChecked", true, 1000)
    w.wake("play")
    compare(notes().length, 1)
    compare(notes()[0], ["notify-send", "--app-name=YouTube Music", "--", "YouTube Music isn't set up yet. Open the panel to set it up."])
  }
  function test_open_panel_uses_the_toast() {
    var w = createTemporaryObject(widgetComp, tc)
    tryCompare(w, "tokenChecked", true, 1000)
    w.open()
    w.wake("play")
    compare(notes().length, 0)
    compare(w.toastText, "YouTube Music isn't set up yet. Open the panel to set it up.")
  }
  function test_failed_start_notifies() {
    Harness.files[tokenPath] = "fake-token-for-tests"
    Harness.procResponder = function(cmd) { return JSON.stringify(cmd).indexOf("cdp-bridge") >= 0 ? { code: 1 } : null }
    var w = createTemporaryObject(widgetComp, tc)
    tryCompare(w, "tokenChecked", true, 1000)
    w.wake("play")
    tryCompare(w, "startFailed", true, 3000)
    compare(notes().length, 1)
    verify(notes()[0][3].indexOf("didn't start") >= 0)
  }
  function test_text_is_one_plain_argument() {
    var w = createTemporaryObject(widgetComp, tc)
    w.toastFor("-u critical <b>“Fake & Song”</b>", 3000)
    compare(notes().length, 1)
    compare(notes()[0].length, 4)
    compare(notes()[0][2], "--")
    compare(notes()[0][3], "-u critical <b>“Fake & Song”</b>")
  }
}
