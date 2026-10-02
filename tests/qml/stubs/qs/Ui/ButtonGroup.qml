import QtQuick
Item {
  property var options: []
  property var value
  property bool focusable: true
  property color foreground
  property string fontFamily
  property real fontSize
  property real spacing
  signal changed(var v)
  implicitWidth: 300
  implicitHeight: 28
}
