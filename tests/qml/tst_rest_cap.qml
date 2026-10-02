import QtQuick
import QtTest
import YtmTest
import "../.."

// The REST calls to the app read and parsed the whole answer on the UI
// thread, with no limit, and one that never ended never came back. Past
// 4 MiB the call is now aborted (just after the handler, never inside it:
// that crashes Qt 6.11) and the caller gets an error, like for a call that
// failed. (A stand-in API from data/fakeapi.py, in the tests' own network
// namespace.)
TestCase {
  id: tc
  name: "RestCap"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }
  function init() { Harness.reset() }

  function get(w, path) {
    var r = { done: false, status: -1, data: null, calls: 0 }
    w.call("GET", path, null, function(s, d) { r.calls += 1; r.done = true; r.status = s; r.data = d })
    tryVerify(function() { return r.done }, 8000, "the call never came back")
    wait(100)
    return r
  }
  function stats(w) {
    var r = { done: false, data: null }
    var x = new XMLHttpRequest()
    x.onreadystatechange = function() { if (x.readyState === XMLHttpRequest.DONE) { r.done = true; r.data = JSON.parse(x.responseText) } }
    x.open("GET", "http://127.0.0.1:26599/api/v1/stats")
    x.send()
    tryVerify(function() { return r.done }, 3000)
    return r.data
  }
  function test_small_answer_is_read() {
    var w = createTemporaryObject(widgetComp, tc, { api: "http://127.0.0.1:26599/api/v1" })
    var r = get(w, "/like-state")
    compare(r.status, 200)
    compare(r.data.state, "LIKE")
  }
  // A call still on its way when the widget goes (a shell reload, a monitor
  // unplugged) ends quietly instead of throwing on the destroyed widget.
  function test_answer_after_the_widget_is_gone() {
    var w = widgetComp.createObject(tc, { api: "http://127.0.0.1:26599/api/v1" })
    failOnWarning(/TypeError/)
    var called = false
    w.call("GET", "/slow", null, function() { called = true })
    w.destroy()
    wait(700)
    compare(called, false)
  }
  // An answer that never ends: without the cap the call never came back.
  // It must stop early, while the answer still arrives.
  function test_endless_answer_is_cut_off() {
    var w = createTemporaryObject(widgetComp, tc, { api: "http://127.0.0.1:26599/api/v1" })
    var t0 = Date.now()
    var r = get(w, "/endless")
    compare(r.calls, 1)
    compare(r.data, null)
    verify(r.status !== 200, "an endless answer was taken as a good one")
    verify(Date.now() - t0 < 4000)
    wait(300)
    var st = stats(w)
    verify(!st.hugeDone && st.hugeSent < 32 * 1024 * 1024, "the answer was read on and on: " + st.hugeSent + " bytes")
  }
  // A 64 MiB answer of a fixed size: not taken either.
  function test_huge_answer_is_not_taken() {
    var w = createTemporaryObject(widgetComp, tc, { api: "http://127.0.0.1:26599/api/v1" })
    var r = get(w, "/huge")
    compare(r.calls, 1)
    compare(r.data, null)
    verify(r.status !== 200, "a 64 MiB answer was taken as a good one")
  }
}
