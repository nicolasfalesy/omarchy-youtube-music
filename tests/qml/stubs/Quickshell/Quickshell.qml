pragma Singleton
import QtQuick
import YtmTest

// Stub of Quickshell's global: env() reads the harness, execDetached() is
// only recorded. Nothing is ever started.
QtObject {
  function env(name) { var v = Harness.env[name]; return v === undefined ? "" : v }
  function execDetached(argv) { Harness.detached = Harness.detached.concat([argv]) }
}
