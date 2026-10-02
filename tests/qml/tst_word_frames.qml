import QtQuick
import QtTest
import YtmTest
import "../.."

// Word-by-word lyrics move the clock on every frame while a word fills. On a
// 144 or 165 Hz monitor that re-ran the sung line's bindings 144 to 165
// times a second; about 60 is enough for a smooth fill. wordFrameDue(dt)
// decides, frame by frame, whether this one moves the clock.
TestCase {
  id: tc
  name: "WordFrames"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }
  function init() { Harness.reset() }

  function ticksPerSecond(w, hz) {
    var n = 0
    for (var i = 0; i < hz; i++) if (w.wordFrameDue(1 / hz)) n++
    return n
  }
  function test_capped_near_60() {
    var w = createTemporaryObject(widgetComp, tc)
    var r144 = ticksPerSecond(w, 144), r165 = ticksPerSecond(w, 165), r120 = ticksPerSecond(w, 120), r60 = ticksPerSecond(w, 60)
    verify(r144 >= 45 && r144 <= 61, "144 Hz gave " + r144)
    verify(r165 >= 45 && r165 <= 61, "165 Hz gave " + r165)
    verify(r120 >= 55 && r120 <= 61, "120 Hz gave " + r120)
    verify(r60 >= 59 && r60 <= 60, "60 Hz gave " + r60)
  }
}
