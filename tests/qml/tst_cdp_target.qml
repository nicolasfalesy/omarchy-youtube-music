import QtQuick
import QtTest
import YtmTest
import "../.."

// The widget attaches only to the app's own YouTube Music page: the URL's
// host must be exactly music.youtube.com over https. A Google sign-in or
// consent page whose continue= parameter names music.youtube.com, or a
// look-alike host, is not it.
TestCase {
  id: tc
  name: "CdpTarget"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }
  function init() { Harness.reset() }

  function attachedTo() {
    var a = Harness.cdpSent.filter(function(m) { return m.method === "Target.attachToTarget" })
    return a.map(function(m) { return m.params.targetId })
  }
  function ask(w) {
    var res = { done: false, v: null, err: "" }
    Harness.cdpResponder = function(method, params, expr) { return method === "Runtime.evaluate" ? "page-answer" : {} }
    w.page("window.__nicYtm.ready()", function(v, err) { res.done = true; res.v = v; res.err = err })
    tryVerify(function() { return res.done }, 3000)
    return res
  }

  function test_lookalikes_are_not_attached() {
    var w = createTemporaryObject(widgetComp, tc)
    Harness.cdpTargets = [
      { type: "page", url: "https://accounts.google.com/ServiceLogin?continue=https%3A%2F%2Fmusic.youtube.com%2F&x=music.youtube.com", targetId: "SIGNIN" },
      { type: "page", url: "https://consent.youtube.com/m?continue=https://music.youtube.com/", targetId: "CONSENT" },
      { type: "page", url: "https://music.youtube.com.example.net/", targetId: "LOOKALIKE" },
      { type: "page", url: "http://music.youtube.com/", targetId: "PLAIN" }
    ]
    var r = ask(w)
    compare(attachedTo().length, 0)
    compare(r.v, null)
    verify(r.err !== "")
  }
  function test_the_real_page_is_attached() {
    var w = createTemporaryObject(widgetComp, tc)
    Harness.cdpTargets = [
      { type: "page", url: "https://accounts.google.com/x?continue=https://music.youtube.com/", targetId: "SIGNIN" },
      { type: "page", url: "https://music.youtube.com/watch?v=abc", targetId: "MUSIC" }
    ]
    var r = ask(w)
    compare(attachedTo(), ["MUSIC"])
    compare(r.v, "page-answer")
  }
}
