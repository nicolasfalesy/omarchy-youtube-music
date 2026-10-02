import QtQuick
import QtTest
import YtmTest
import "../.."

// The REST calls to the app read the whole answer into the shell, with no
// limit. An answer past 4 MiB is now cut off: the request is aborted and the
// caller gets an error, like for a call that failed. (A stand-in API from
// data/fakeapi.py, in the tests' own network namespace.)
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
  // An answer that never ends: without the cap the call never came back.
  function test_endless_answer_is_cut_off() {
    var w = createTemporaryObject(widgetComp, tc, { api: "http://127.0.0.1:26599/api/v1" })
    var r = get(w, "/endless")
    compare(r.calls, 1)
    compare(r.data, null)
    verify(r.status !== 200, "an endless answer was taken as a good one")
    wait(300)
    var st = stats(w)
    verify(!st.hugeDone && st.hugeSent < 64 * 1024 * 1024, "the answer was read on and on: " + st.hugeSent + " bytes")
  }
}
