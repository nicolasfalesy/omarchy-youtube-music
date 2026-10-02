import QtQuick
import QtTest
import YtmTest
import "../.."

// helper 11: does port trust end when the app goes away BEFORE it ever said
// PLAYER_INFO (quit/crash during start, or the token-refusal quit)?
TestCase {
  id: tc
  name: "C11Trust"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }
  readonly property string tokenPath: "/nonexistent/home/.local/state/omarchy/nic-youtube-music/token"
  function make() {
    Harness.reset()
    Harness.files[tokenPath] = "fake-token-A"
    Harness.procResponder = function(cmd) {
      return JSON.stringify(cmd).indexOf("ss -ltnHe") >= 0 ? { out: "1000\nLISTEN 0 511 127.0.0.1:26538 0.0.0.0:* uid:1000 ino:1 sk:1 <->\n" } : null
    }
    var w = createTemporaryObject(widgetComp, tc)
    tryCompare(w, "tokenChecked", true, 1000)
    wait(50)
    return w
  }
  function last() { return Harness.sockets[Harness.sockets.length - 1].ws }
  function lastUrl() { return String(Harness.sockets[Harness.sockets.length - 1].url) }
  // A: the app answered (owner check passed), then went away before PLAYER_INFO:
  // the tokened probe gets connection refused (never opens).
  function test_a_app_gone_before_up() {
    var w = make()
    var ws = last(); ws.open(); ws.drop()
    tryVerify(function() { return lastUrl().indexOf("token=") >= 0 }, 2000)
    last().drop()                 // refused: nothing listens any more
    compare(w.appUp, false)
    // later: some other listener took the port; owner never re-checked
    var nss = Harness.procsMatching("ss -ltnHe").length
    w.probe()
    compare(Harness.procsMatching("ss -ltnHe").length, nss, "no new owner check before the probe")
    compare(lastUrl().indexOf("token="), -1, "token sent to an unchecked listener (portTrusted=" + w.portTrusted + ")")
  }
  // B: token refused twice -> tokenRejected; then a new token is written
  // (Set up again) while the port owner is no longer checked.
  function test_b_new_token_after_refusal() {
    var w = make()
    var ws = last(); ws.open(); ws.drop()
    tryVerify(function() { return lastUrl().indexOf("token=") >= 0 }, 2000)
    last().open(); last().drop()
    // The refused, token-carrying close ends the trust (with the fix, the
    // second refusal that set tokenRejected never gets a token to refuse).
    compare(w.portTrusted, false)
    w.apiToken = "fake-token-B"
    w.probe()
    compare(lastUrl().indexOf("token="), -1, "new token sent with no owner check (portTrusted=" + w.portTrusted + ")")
  }
}
