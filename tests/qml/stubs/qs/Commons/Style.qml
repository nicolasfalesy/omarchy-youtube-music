pragma Singleton
import QtQuick
QtObject {
  function space(n) { return n }
  property var font: ({ family: "sans-serif", body: 14, bodySmall: 13, caption: 12, subtitle: 16, icon: 16, iconLarge: 22, display: 28 })
  property var bar: ({ sizeHorizontal: 30 })
  property int gapsOut: 8
  property var spacing: ({ popupPadding: 12 })
}
