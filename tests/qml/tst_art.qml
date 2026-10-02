import QtQuick
import QtTest
import YtmTest
import "../.."

// Every cover, thumbnail and backdrop is fetched by the shell itself. Its URL
// comes from YouTube's data, the app's API or last.json, so the widget loads
// only https URLs on Google's image hosts, and decodes the two big images at
// the size they are drawn (they had no sourceSize and decoded at full size).
TestCase {
  id: tc
  name: "Art"
  width: 900; height: 700
  when: windowShown
  Component { id: widgetComp; Widget {} }
  function init() { Harness.reset() }

  function test_only_google_image_hosts() {
    var w = createTemporaryObject(widgetComp, tc)
    var bad = ["file:///home/u/pic.png", "http://lh3.googleusercontent.com/x", "https://example.com/x.png",
      "qrc:/x.png", "https://lh3.googleusercontent.com.example.com/x", "https://yt3.ggpht.com@example.com/x", "//i.ytimg.com/vi/x/mqdefault.jpg"]
    for (var i = 0; i < bad.length; i++) {
      compare(w.artAt(bad[i], 0), "", bad[i])
      compare(w.artAt(bad[i], 2), "", bad[i] + " (retry)")
    }
    compare(w.artAt("https://lh3.googleusercontent.com/a=w120", 0), "https://lh3.googleusercontent.com/a=w120")
    compare(w.artAt("https://lh3.googleusercontent.com/a=w120", 1), "https://lh4.googleusercontent.com/a=w120")
    compare(w.artAt("https://www.gstatic.com/a.png", 1), "https://www.gstatic.com/a.png?try=1")
  }

  function test_rows_with_bad_art_load_nothing() {
    var w = createTemporaryObject(widgetComp, tc)
    w.upNext = [{ title: "Row", subtitle: "x", thumb: "file:///etc/hostname", videoId: "abcDEF_12-x", queueId: 1, queueIndex: 0 }]
    w.appUp = true
    wait(50)
    var imgs = images(w)
    verify(imgs.length > 0)
    for (var i = 0; i < imgs.length; i++)
      verify(String(imgs[i].source).indexOf("file:") !== 0, "an image loads " + imgs[i].source)
  }

  function test_big_images_decode_small() {
    var w = createTemporaryObject(widgetComp, tc)
    var back = findChild(w, "backdropArt"), cover = findChild(w, "coverArt")
    verify(back !== null && cover !== null)
    compare(back.sourceSize.width, 544)
    compare(back.sourceSize.height, 544)
    compare(cover.sourceSize.width, 544)
    compare(cover.sourceSize.height, 544)
  }

  function images(item) {
    var out = []
    var walk = function(o) {
      if (!o) return
      if (o.toString().indexOf("ArtImage") >= 0 || (o.hasOwnProperty("sourceSize") && o.hasOwnProperty("fillMode"))) out.push(o)
      var kids = o.children || []
      for (var i = 0; i < kids.length; i++) walk(kids[i])
      if (o.contentItem && o.contentItem !== o) walk(o.contentItem)
    }
    walk(item)
    return out
  }
}
