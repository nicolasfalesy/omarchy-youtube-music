import QtQuick
Item {
  property QtObject bar: null
  property real value: 0
  property real minimum: 0
  property real maximum: 1
  property real step: 0.05
  property bool integer: false
  property color fillColor
  signal moved(real value)
  signal released(real value)
  implicitHeight: 20
}
