import QtQuick

// Stub of Omarchy's key dispatcher: the same keys to the same signals, so a
// test can press real keys at the panel.
Item {
  id: root
  property bool blocked: false
  signal moveRequested(int dx, int dy)
  signal activateRequested()
  signal returnRequested()
  signal closeRequested()
  signal deleteRequested()
  signal tabRequested(int direction)
  signal textKey(string text)
  focus: true
  Keys.priority: Keys.BeforeItem
  Keys.onPressed: function(event) {
    if (blocked) return
    var k = event.key, t = event.text
    if (k === Qt.Key_Escape) closeRequested()
    else if (k === Qt.Key_Tab || k === Qt.Key_Backtab) tabRequested(k === Qt.Key_Backtab ? -1 : 1)
    else if (k === Qt.Key_Down || t === "j") moveRequested(0, 1)
    else if (k === Qt.Key_Up || t === "k") moveRequested(0, -1)
    else if (k === Qt.Key_Right || t === "l") moveRequested(1, 0)
    else if (k === Qt.Key_Left || t === "h") moveRequested(-1, 0)
    else if (k === Qt.Key_Return || k === Qt.Key_Enter) { returnRequested(); activateRequested() }
    else if (k === Qt.Key_Space) activateRequested()
    else { if (t && t.length === 1) textKey(t); return }
    event.accepted = true
  }
}
