import QtQuick

// Stub of Omarchy's Panel base: open/close state and settings only.
Item {
  id: root
  property QtObject bar: null
  property string moduleName: ""
  property var settings: ({})
  property string ipcTarget: ""
  property bool manageIpc: true
  property alias controller: ctl
  readonly property bool opened: ctl.open
  property int panelSwitches: 0
  function open() { ctl.show() }
  function close() { ctl.hide() }
  function toggle() { opened ? close() : open() }
  function switchPanel(direction) { panelSwitches += 1; return false }
  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }
  QtObject {
    id: ctl
    property bool open: false
    function show() { open = true }
    function hide() { open = false }
  }
}
