import QtQuick
Item {
  id: b
  property string text: ""
  property bool bordered: false
  property real fontSize: 14
  signal clicked()
  implicitWidth: 100
  implicitHeight: 28
  width: implicitWidth
  height: implicitHeight
  MouseArea { anchors.fill: parent; onClicked: b.clicked() }
}
