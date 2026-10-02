import QtQuick
import QtTest
import YtmTest
import "../.."

// Left and Right in the panel seek back and forward 10 seconds (they did
// nothing). Not while typing in the search field, where they move the text
// cursor.
TestCase {
  id: tc
  name: "SeekKeys"
  width: 900; height: 700
  visible: true
  when: windowShown
  Component { id: widgetComp; Widget {} }
  readonly property string api: "http://127.0.0.1:26599/api/v1"
  function init() { Harness.reset(); post("/reset") }
  function post(path) {
    var x = new XMLHttpRequest(), done = false
    x.onreadystatechange = function() { if (x.readyState === XMLHttpRequest.DONE) done = true }
    x.open("POST", api + path); x.send()
    tryVerify(function() { return done }, 2000)
  }
  function seeks() {
    var x = new XMLHttpRequest(), r = null
    x.onreadystatechange = function() { if (x.readyState === XMLHttpRequest.DONE) r = JSON.parse(x.responseText).posts }
    x.open("GET", api + "/stats"); x.send()
    tryVerify(function() { return r !== null }, 2000)
    return r["/api/v1/seek-to"] || 0
  }
  function live() {
    var w = createTemporaryObject(widgetComp, tc, { api: api })
    w.lastSong = null
    w.song = { title: "Fake Song", artist: "Test Artist", videoId: "abcDEF_12-x", songDuration: 200 }
    w.appUp = true
    w.songReal = true
    w.position = 50
    w.open()
    var k = findChild(w, "keyCatcher")
    k.forceActiveFocus()
    return w
  }
  function test_right_and_left_seek() {
    var w = live()
    wait(200)
    var before = seeks()
    keyClick(Qt.Key_Right)
    compare(w.position, 60)
    keyClick(Qt.Key_Left)
    keyClick(Qt.Key_Left)
    compare(w.position, 40)
    wait(200)
    compare(seeks() - before, 3)
  }
  function test_clamped_to_the_song() {
    var w = live()
    w.position = 4
    keyClick(Qt.Key_Left)
    compare(w.position, 0)
    w.position = 195
    keyClick(Qt.Key_Right)
    verify(w.position < 200 && w.position >= 195, "position " + w.position)
  }
  function test_not_while_searching() {
    var w = live()
    wait(200)
    var before = seeks()
    findChild(w, "searchField").forceActiveFocus()
    keyClick(Qt.Key_Right)
    compare(w.position, 50)
    wait(200)
    compare(seeks(), before)
  }
}
