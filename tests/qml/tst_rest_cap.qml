import QtQuick
import QtTest
import YtmTest
import "../.."

// The REST calls to the app parsed the whole answer on the UI thread, with no
// limit. An answer past 4 MiB is now never parsed, and the caller gets an
// error, like for a call that failed. (A stand-in API from data/fakeapi.py,
// in the tests' own network namespace.)
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
  // A 64 MiB answer: read (the transfer cannot be stopped safely, see
  // call() in Widget.qml) but never parsed, and reported as a failure.
  function test_huge_answer_is_not_taken() {
    var w = createTemporaryObject(widgetComp, tc, { api: "http://127.0.0.1:26599/api/v1" })
    var r = get(w, "/huge")
    compare(r.calls, 1)
    compare(r.data, null)
    verify(r.status !== 200, "a 64 MiB answer was taken as a good one")
  }
}
