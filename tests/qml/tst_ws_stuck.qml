import QtQuick
import QtTest
import YtmTest
import "../.."

// A probe socket that never gets past Connecting (something took the TCP
// connection and never answered the WebSocket handshake) blocked every later
// probe for good, since probe() returns while one is connecting. After
// connectTimeoutMs (10 s) it is dropped and the next probe tries again.
TestCase {
  id: tc
  name: "WsStuck"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }
  function init() { Harness.reset() }

  function test_stuck_connect_is_reset() {
    var w = createTemporaryObject(widgetComp, tc)
    wait(50)
    var n = Harness.sockets.length
    verify(n >= 1)
    // Shortened for the test; without the setting it waits the real 10 s.
    var short = w.connectTimeoutMs !== undefined
    if (short) w.connectTimeoutMs = 300
    w.probe()
    compare(Harness.sockets.length, n, "a second probe while the first is still connecting")
    wait(short ? 400 : 10500)
    w.probe()
    compare(Harness.sockets.length, n + 1, "the stuck socket blocked the probe")
  }
  function test_fresh_connect_is_left_alone() {
    var w = createTemporaryObject(widgetComp, tc)
    wait(50)
    var n = Harness.sockets.length
    w.probe(); w.probe()
    compare(Harness.sockets.length, n)
  }
}
