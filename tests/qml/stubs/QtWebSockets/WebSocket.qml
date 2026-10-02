import QtQuick
import YtmTest

// Stub WebSocket: becoming active is recorded with its URL; a test opens,
// feeds and closes it by hand (open(), push(), drop()).
QtObject {
  id: ws
  enum Status { Connecting, Open, Closing, Closed, Error }
  property url url
  property bool active: false
  property int status: WebSocket.Closed
  signal textMessageReceived(string message)
  onActiveChanged: if (active) {
    status = WebSocket.Connecting
    Harness.sockets = Harness.sockets.concat([{ ws: ws, url: String(url) }])
  }
  function open() { status = WebSocket.Open }
  function push(obj) { textMessageReceived(JSON.stringify(obj)) }
  function drop() { status = WebSocket.Closed }
  function sendTextMessage(t) {}
}
