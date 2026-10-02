import QtQuick
import QtTest
import YtmTest
import "../.."

// The API token is sent to 127.0.0.1:26538 only once that port is known to
// belong to a program of this user. While the app is closed the widget
// probes without the token; when something answers there, `ss` names the
// owner of the listening socket, and only a listener owned by this user gets
// the token. Another user's, root's or no listener: no token, ever.
TestCase {
  id: tc
  name: "PortOwner"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }
  readonly property string tokenPath: "/nonexistent/home/.local/state/omarchy/nic-youtube-music/token"
  readonly property string token: "fake-token-for-tests"

  function make(ssOut) {
    Harness.reset()
    Harness.files[tokenPath] = token
    Harness.procResponder = function(cmd) {
      return JSON.stringify(cmd).indexOf("ss -ltnHe") >= 0 ? { out: ssOut } : null
    }
    var w = createTemporaryObject(widgetComp, tc)
    tryCompare(w, "tokenChecked", true, 1000)
    wait(50)
    return w
  }
  function withToken() { return Harness.sockets.filter(function(s) { return s.url.indexOf("token=") >= 0 }) }
  function last() { return Harness.sockets[Harness.sockets.length - 1].ws }
  // Something listens and closes the token-less socket (an app with auth on).
  function answerAndClose() { var ws = last(); ws.open(); ws.drop() }
  function listener(uidPart) { return "LISTEN 0 511 127.0.0.1:26538 0.0.0.0:* " + uidPart + " ino:1 sk:1 cgroup:/user.slice <->\n" }

  function test_no_token_before_the_check() {
    var w = make("1000\n" + listener("uid:1000"))
    verify(Harness.sockets.length >= 1)
    compare(withToken().length, 0, "the token went out before anyone checked who listens")
  }
  function test_own_listener_gets_the_token() {
    var w = make("1000\n" + listener("uid:1000"))
    answerAndClose()
    tryVerify(function() { return withToken().length === 1 }, 2000)
    verify(withToken()[0].url.indexOf("token=" + token) >= 0)
    compare(Harness.procsMatching("ss -ltnHe").length, 1)
  }
  function test_other_users_listener_gets_nothing() {
    var owners = [listener("uid:1001"), listener(""), "", listener("uid:1000") + listener("uid:1002")]
    for (var i = 0; i < owners.length; i++) {
      var w = make("1000\n" + owners[i])
      answerAndClose()
      tryVerify(function() { return Harness.procsMatching("ss -ltnHe").length === 1 }, 2000)
      wait(300)
      w.probe()
      compare(withToken().length, 0, "case " + i)
      w.destroy()
    }
  }
  function test_trust_ends_when_the_app_goes() {
    var w = make("1000\n" + listener("uid:1000"))
    answerAndClose()
    tryVerify(function() { return withToken().length === 1 }, 2000)
    var ws = last()
    ws.open()
    ws.push({ type: "PLAYER_INFO", song: null, position: 0 })
    compare(w.appUp, true)
    ws.drop()
    compare(w.appUp, false)
    var n = Harness.sockets.length
    w.probe()
    verify(Harness.sockets.length > n)
    compare(last().url.toString().indexOf("token="), -1)
  }
}
