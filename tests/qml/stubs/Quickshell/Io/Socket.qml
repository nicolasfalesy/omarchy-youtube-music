import QtQuick
import YtmTest

// Stub of the bridge's Unix socket. With no Harness.cdpResponder there is no
// bridge: a connect fails with error(). Otherwise it connects, and every line
// written is answered by Harness.cdpLine().
QtObject {
  id: s
  property string path: ""
  property bool connected: false
  property QtObject parser: null
  signal error(int error)
  signal connectionStateChanged()
  property bool _up: false
  onConnectedChanged: {
    if (connected && !_up) {
      if (!Harness.cdpResponder) { Qt.callLater(function() { s.connected = false; s.error(0) }); return }
      _up = true
      Qt.callLater(function() { s.connectionStateChanged() })
    } else if (!connected && _up) {
      _up = false
      connectionStateChanged()
    }
  }
  function write(t) {
    var lines = String(t).split("\n")
    for (var i = 0; i < lines.length; i++) if (lines[i] !== "") Harness.cdpLine(s, lines[i])
  }
  function flush() {}
}
