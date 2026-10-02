import QtQuick
import QtTest
import YtmTest
import "../.."

// Home and the Library pages are kept for 10 minutes: opening the panel
// again or coming back to a tab shows the kept list at once, with no
// "Loading…" and no fetch. Older than that, the kept list still shows at
// once and a fresh copy loads quietly behind it. Albums, playlists and
// artists opened from a list, and searches, always load.
TestCase {
  id: tc
  name: "BrowseCache"
  width: 900; height: 700
  visible: true
  when: windowShown
  Component { id: widgetComp; Widget {} }
  function init() { Harness.reset() }

  property int version: 1
  function make() {
    version = 1
    Harness.cdpResponder = function(method, params, expr) {
      if (method !== "Runtime.evaluate") return {}
      if (expr.indexOf("browse(") >= 0) {
        var id = /browse\("([^"]+)"/.exec(expr)[1]
        return { header: null, sections: [{ title: "", items: [{ kind: "song", title: id + " v" + tc.version, videoId: "abcDEF_12-x" }] }] }
      }
      if (expr.indexOf("ready()") >= 0 || expr.indexOf("signedIn()") >= 0) return true
      if (expr.indexOf("queue(") >= 0) return { items: [], upNext: [], sig: "" }
      return null
    }
    var w = createTemporaryObject(widgetComp, tc)
    w.appUp = true
    return w
  }
  function browses(id) {
    return Harness.cdpSent.filter(function(m) {
      return m.method === "Runtime.evaluate" && String(m.params.expression).indexOf('__nicYtm.browse("' + id + '"') >= 0
    }).length
  }
  function firstTitle(w) { for (var i = 0; i < w.rows.length; i++) if (!w.rows[i].header) return w.rows[i].title; return "" }

  function test_home_is_reused() {
    var w = make()
    w.open()
    tryCompare(w, "loading", false, 2000)
    tryVerify(function() { return firstTitle(w) === "FEmusic_home v1" }, 2000)
    compare(browses("FEmusic_home"), 1)
    w.close()
    w.open()
    compare(w.loading, false)
    compare(firstTitle(w), "FEmusic_home v1")
    wait(300)
    compare(browses("FEmusic_home"), 1, "Home was fetched again within 10 minutes")
  }
  function test_library_tab_is_reused() {
    var w = make()
    w.open()
    w.view = "library"
    w.libraryPage = "VLLM"
    tryVerify(function() { return firstTitle(w) === "VLLM v1" }, 2000)
    w.view = "home"
    tryVerify(function() { return firstTitle(w) === "FEmusic_home v1" }, 2000)
    w.view = "library"
    compare(w.loading, false)
    compare(firstTitle(w), "VLLM v1")
    wait(300)
    compare(browses("VLLM"), 1)
  }
  function test_old_list_shows_then_refreshes_quietly() {
    var w = make()
    w.open()
    tryVerify(function() { return firstTitle(w) === "FEmusic_home v1" }, 2000)
    w.close()
    w.ageBrowseCache(11 * 60 * 1000)
    version = 2
    var spinner = 0
    w.loadingChanged.connect(function() { if (w.loading) spinner++ })
    w.open()
    compare(firstTitle(w), "FEmusic_home v1")
    tryVerify(function() { return firstTitle(w) === "FEmusic_home v2" }, 2000)
    compare(spinner, 0, "a spinner showed although a list was kept")
    compare(browses("FEmusic_home"), 2)
  }
  function test_opened_pages_always_load() {
    var w = make()
    w.open()
    tryVerify(function() { return firstTitle(w) === "FEmusic_home v1" }, 2000)
    var album = { kind: "album", title: "Fake Album", browseId: "MPREb_fake" }
    w.openItem(album)
    tryVerify(function() { return browses("MPREb_fake") === 1 }, 2000)
    w.goBack()
    w.openItem(album)
    tryVerify(function() { return browses("MPREb_fake") === 2 }, 2000)
  }
}
