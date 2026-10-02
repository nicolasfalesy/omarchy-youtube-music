import QtQuick

// Stub: a plain item sized to the content, inside the test window, so its
// content can be inspected and clicked offscreen.
Item {
  property Item anchorItem: null
  property var owner: null
  property QtObject bar: null
  property bool open: false
  property Item focusTarget: null
  property int contentWidth: 820
  property int contentHeight: 640
  property int padding: 12
  function fittedContentWidth(w) { return w }
  function fittedContentHeight(h, min) { return h }
  width: contentWidth
  height: contentHeight
}
