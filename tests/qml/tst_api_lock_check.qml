import QtQuick
import QtTest
import YtmTest
import "../.."

// When the app comes up, the widget asks its API once WITHOUT the token, to
// see whether it is still open to every program. That answer can arrive
// after the widget is gone (a shell reload, a monitor unplugged); it must
// then end quietly, and it must still never carry the token.
TestCase {
  id: tc
  name: "ApiLockCheck"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }
  function init() { Harness.reset() }

  function test_answer_after_the_widget_is_gone() {
    var w = widgetComp.createObject(tc, { api: "http://127.0.0.1:26599/api/v1/slow-prefix" })
    failOnWarning(/TypeError/)
    w.checkApiLock()
    w.destroy()
    wait(700)
  }
  function test_open_api_is_noticed() {
    var w = createTemporaryObject(widgetComp, tc, { api: "http://127.0.0.1:26599/api/v1" })
    w.checkApiLock()
    tryCompare(w, "apiOpen", true, 2000)
  }
}
