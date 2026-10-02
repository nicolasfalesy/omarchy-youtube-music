import QtQuick
import QtTest
import YtmTest
import "../.."
import "data/krc.js" as Krc

// KuGou's word-timed lyrics arrive as a zlib stream the widget inflates on
// the shell's UI thread. The answer itself is capped at 2 MiB by curl, but a
// stream that small can ask for gigabytes once inflated. inflate() must stop
// once the output passes 1 MiB (real lyrics are about 20 KB), and the lookup
// must then fall back to LRCLIB like any unreadable answer.
TestCase {
  id: tc
  name: "LyricsInflate"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }

  function init() { Harness.reset() }

  function test_small_payload_still_reads() {
    var w = createTemporaryObject(widgetComp, tc)
    var lines = w.parseKrc(w.krcText(Krc.small), "Test Song", "Nobody")
    verify(lines !== null)
    compare(lines.length, 3)
    compare(lines[0].text, "Hello there world")
    compare(lines[0].words.length, 3)
  }

  function test_bomb_is_refused() {
    var w = createTemporaryObject(widgetComp, tc)
    var threw = ""
    var t0 = Date.now()
    var out = null
    try { out = w.krcText(Krc.bomb) } catch (e) { threw = String(e) }
    verify(threw.indexOf("over 1 MiB") >= 0, "inflate kept going: " + (out ? out.length + " chars" : threw))
    verify(Date.now() - t0 < 2000)
  }

  function test_bomb_lookup_falls_back() {
    var w = createTemporaryObject(widgetComp, tc)
    // A KuGou download that is a bomb: kugouLookup's callback gets null.
    var got = "unset"
    Harness.procResponder = function(cmd) {
      var url = cmd[cmd.length - 1]
      if (url.indexOf("krcs.kugou.com/search") >= 0)
        return { out: JSON.stringify({ candidates: [{ id: "1", accesskey: "k", song: "Test Song", singer: "Nobody", duration: 200000 }] }) }
      if (url.indexOf("lyrics.kugou.com/download") >= 0) return { out: JSON.stringify({ content: Krc.bomb }) }
      return null
    }
    w.kugouLookup({ title: "Test Song", artist: "Nobody", songDuration: 200 }, function(r) { got = r })
    tryVerify(function() { return got !== "unset" }, 5000)
    compare(got, null)
  }
}
