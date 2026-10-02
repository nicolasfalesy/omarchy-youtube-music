pragma Singleton
import QtQuick
QtObject {
  property color foreground: "#e0e0e0"
  property color background: "#101010"
  property color accent: "#e5484d"
  property var popups: ({ background: "#181818", border: "#333333" })
  property var tooltip: ({ background: "#181818", text: "#e0e0e0", border: "#333333" })
}
