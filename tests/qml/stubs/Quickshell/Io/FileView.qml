import QtQuick
import YtmTest

// Stub FileView over the harness's virtual files. Loads (or fails) a moment
// after the path is set or reload() is called, like the real one.
QtObject {
  id: f
  property string path: ""
  property bool watchChanges: false
  property bool atomicWrites: false
  property bool printErrors: true
  property string _text: ""
  signal loaded()
  signal loadFailed(int error)
  signal saved()
  signal saveFailed(int error)
  signal fileChanged()
  function text() { return _text }
  function reload() { Qt.callLater(f._load) }
  function _load() {
    if (path === "") return
    var v = Harness.files[path]
    if (v === undefined) { _text = ""; loadFailed(1); return }
    _text = v
    loaded()
  }
  function setText(t) {
    if (Harness.failWrites) { Qt.callLater(function() { f.saveFailed(2) }); return }
    var m = Harness.files
    m[path] = String(t)
    Harness.files = m
    Harness.writes = Harness.writes.concat([{ path: path, text: String(t) }])
    _text = String(t)
    Qt.callLater(function() { f.saved() })
  }
  onPathChanged: Qt.callLater(f._load)
}
