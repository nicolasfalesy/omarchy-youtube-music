import QtQuick
import QtTest
import YtmTest
import Quickshell.Services.UPower
import "../.."

// The idle quit: after idleMinutes paused (default 5), never sooner than a
// minute whatever the setting says, and after 2 minutes on battery.
TestCase {
  id: tc
  name: "Idle"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }
  function init() { Harness.reset(); UPower.onBattery = false }
  function cleanup() { UPower.onBattery = false }

  function limitFor(v) {
    var w = createTemporaryObject(widgetComp, tc, v === undefined ? {} : { settings: { idleMinutes: v } })
    return w.idleLimit
  }
  function test_setting_is_clamped() {
    compare(limitFor(undefined), 300)
    compare(limitFor(7), 420)
    compare(limitFor(0.01), 60)
    compare(limitFor(-3), 60)
    compare(limitFor("abc"), 300)
  }
}
