import QtQuick
import YtmTest

// Stub Process: running = true reports to the harness, which may answer it
// (Harness.procResponder) or leave it running. Never starts anything.
QtObject {
  id: p
  property var command: []
  property var environment: ({})
  property bool running: false
  property QtObject stdout: null
  property QtObject stderr: null
  signal started()
  signal exited(int exitCode, int exitStatus)
  onRunningChanged: if (running) { started(); Harness.procStarted(p) }
}
