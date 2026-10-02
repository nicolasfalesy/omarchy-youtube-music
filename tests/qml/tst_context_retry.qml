import QtQuick
import QtTest
import YtmTest
import "../.."

// Right after the app starts, a page call can fail with "Cannot find default
// execution context" and is retried once. That first failure is expected and
// is not logged; only a retry that fails as well is.
TestCase {
  id: tc
  name: "ContextRetry"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }
  function init() { Harness.reset() }

  function run(w, failures) {
    var n = 0, res = { done: false, v: null }
    Harness.cdpResponder = function(method, params, expr) {
      if (method !== "Runtime.evaluate") return {}
      n += 1
      return n <= failures ? { cdpError: "Cannot find default execution context" } : "answer"
    }
    w.page("window.__nicYtm.ready()", function(v) { res.done = true; res.v = v })
    tryVerify(function() { return res.done }, 3000)
    return res
  }
  function test_first_failure_is_quiet() {
    var w = createTemporaryObject(widgetComp, tc)
    failOnWarning(/Cannot find default execution context/)
    compare(run(w, 1).v, "answer")
  }
  function test_second_failure_is_logged() {
    var w = createTemporaryObject(widgetComp, tc)
    ignoreWarning(/page error: .*Cannot find default execution context/)
    compare(run(w, 2).v, null)
  }
}
