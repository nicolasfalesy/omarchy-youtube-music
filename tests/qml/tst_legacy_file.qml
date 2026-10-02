import QtQuick
import QtTest
import YtmTest
import "../.."

// Before 2026-09-24 the remembered song lived in
// ~/.local/state/omarchy/nic-youtube-music-last.json. It is still read once
// when last.json is missing, and carried over; once the new file is safely
// written, the old one is removed, so it is never read (or left) again.
TestCase {
  id: tc
  name: "LegacyFile"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }
  readonly property string lastPath: "/nonexistent/home/.local/state/omarchy/nic-youtube-music/last.json"
  readonly property string legacy: "/nonexistent/home/.local/state/omarchy/nic-youtube-music-last.json"
  function old() {
    return JSON.stringify({ title: "Fake Song", artist: "Test Artist", album: "", imageSrc: "", videoId: "abcDEF_12-x",
      playlistId: "", songDuration: 200, elapsedSeconds: 42 })
  }
  function init() { Harness.reset() }
  function removals() { return Harness.detached.filter(function(a) { return a[0] === "rm" }) }

  function test_migrated_then_removed() {
    Harness.files[legacy] = old()
    var w = createTemporaryObject(widgetComp, tc)
    tryVerify(function() { return Harness.files[lastPath] !== undefined }, 1000)
    compare(JSON.parse(Harness.files[lastPath]).title, "Fake Song")
    compare(w.lastSong.elapsedSeconds, 42)
    tryVerify(function() { return removals().length === 1 }, 1000)
    compare(removals()[0], ["rm", "-f", "--", legacy])
  }
  function test_kept_when_the_write_fails() {
    Harness.files[legacy] = old()
    Harness.failWrites = true
    var w = createTemporaryObject(widgetComp, tc)
    wait(200)
    compare(removals().length, 0)
  }
  function test_left_alone_when_last_json_exists() {
    Harness.files[legacy] = old()
    Harness.files[lastPath] = old()
    var w = createTemporaryObject(widgetComp, tc)
    wait(200)
    compare(removals().length, 0)
  }
}
