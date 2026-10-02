import QtQuick
import QtTest
import YtmTest
import "../.."

// When the list area shows an error (the page did not answer, the app is on
// its offline page), there is a "Try again" button that loads it again.
// Empty results and "sign in" are not errors and get no button.
TestCase {
  id: tc
  name: "TryAgain"
  width: 900; height: 700
  visible: true
  when: windowShown
  Component { id: widgetComp; Widget {} }
  function init() { Harness.reset() }

  function browses() {
    return Harness.cdpSent.filter(function(m) { return m.method === "Runtime.evaluate" && String(m.params.expression).indexOf("__nicYtm.browse(") >= 0 }).length
  }
  function make(answer) {
    Harness.cdpResponder = function(method, params, expr) {
      if (method !== "Runtime.evaluate") return {}
      if (expr.indexOf("browse(") >= 0) return answer()
      if (expr.indexOf("ready()") >= 0) return true
      if (expr.indexOf("signedIn()") >= 0) return true
      if (expr.indexOf("queue(") >= 0) return { items: [], upNext: [], sig: "" }
      return null
    }
    var w = createTemporaryObject(widgetComp, tc)
    w.appUp = true
    w.open()
    return w
  }
  function test_error_has_try_again() {
    var fail = true
    var w = make(function() { return fail ? { error: "YouTube Music did not answer. Try again." } : { sections: [{ title: "", items: [{ kind: "song", title: "Fake Song", videoId: "abcDEF_12-x" }] }] } })
    tryCompare(w, "listError", "YouTube Music did not answer. Try again.", 3000)
    var b = Harness.button(w, "Try again")
    verify(b !== null, "no Try again button under the error")
    var n = browses()
    fail = false
    mouseClick(b)
    tryVerify(function() { return browses() > n }, 2000)
    tryCompare(w, "listError", "", 3000)
    verify(Harness.button(w, "Try again") === null)
  }
  function test_empty_page_has_no_button() {
    var w = make(function() { return { sections: [] } })
    tryVerify(function() { return w.listError !== "" }, 3000)
    verify(Harness.button(w, "Try again") === null)
  }
}
