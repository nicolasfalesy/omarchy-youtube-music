pragma Singleton
import QtQuick

// The test side of the stub modules. Everything the widget would do to the
// outside world (start a process, read or write a file, open a socket, send a
// desktop notification) lands here instead, where a test can look at it and
// answer it. Nothing in the stubs touches the real system.
QtObject {
  id: h

  // Quickshell.env()
  property var env: ({ HOME: "/nonexistent/home", XDG_RUNTIME_DIR: "/nonexistent/run" })
  // Quickshell.execDetached() calls, as argv arrays.
  property var detached: []
  // A virtual file system for FileView: path -> text.
  property var files: ({})
  property var writes: []          // [{path, text}]
  property bool failWrites: false
  // Processes started (Process.running = true), in order.
  property var procs: []
  // function(command) -> {code, out, err, delay} | null (null: never ends)
  property var procResponder: null
  // WebSockets made active: [{ws, url}]
  property var sockets: []
  // CDP: function(method, params, expr) -> value | {error: "..."} | undefined
  // (undefined = no answer). Null: every connect fails (no bridge).
  property var cdpResponder: null
  property var cdpSent: []
  property var cdpTargets: [{ type: "page", url: "https://music.youtube.com/", targetId: "T1" }]

  function reset() {
    env = ({ HOME: "/nonexistent/home", XDG_RUNTIME_DIR: "/nonexistent/run" })
    detached = []
    files = ({})
    writes = []
    failWrites = false
    procs = []
    procResponder = null
    sockets = []
    cdpResponder = null
    cdpSent = []
    cdpTargets = [{ type: "page", url: "https://music.youtube.com/", targetId: "T1" }]
  }

  // One line the widget wrote to the bridge socket: answer it like the bridge
  // and the page would.
  function cdpLine(sock, line) {
    var m = JSON.parse(line)
    cdpSent = cdpSent.concat([m])
    var reply = function(obj) { obj.id = m.id; later(0, function() { if (sock.parser) sock.parser.read(JSON.stringify(obj)) }) }
    if (m.method === "Target.getTargets") { reply({ result: { targetInfos: cdpTargets } }); return }
    if (m.method === "Target.attachToTarget") { reply({ result: { sessionId: "S-" + m.params.targetId } }); return }
    var expr = ""
    if (m.method === "Runtime.evaluate") {
      var e = String(m.params.expression)
      var cut = e.lastIndexOf(";\n")
      expr = cut >= 0 ? e.slice(cut + 2) : e
    }
    var v = cdpResponder ? cdpResponder(m.method, m.params, expr) : undefined
    if (v === undefined) return
    if (v && v.cdpError) { reply({ error: { message: v.cdpError } }); return }
    if (m.method === "Runtime.evaluate") reply({ result: { result: { value: v } } })
    else reply({ result: v || {} })
  }

  function procStarted(p) {
    procs = procs.concat([p])
    if (!procResponder) return
    var r = procResponder(p.command)
    if (!r) return
    later(r.delay || 0, function() { finish(p, r.code || 0, r.out || "", r.err || "") })
  }
  // End a process the way Quickshell's Process does: collectors first, then
  // exited.
  function finish(p, code, out, err) {
    if (p.stdout) { p.stdout.text = out || ""; p.stdout.streamFinished() }
    if (p.stderr) { p.stderr.text = err || ""; p.stderr.streamFinished() }
    p.running = false
    p.exited(code, 0)
  }
  function procsMatching(word) {
    return procs.filter(function(p) { return JSON.stringify(p.command).indexOf(word) >= 0 })
  }
  function detachedMatching(word) {
    return detached.filter(function(a) { return JSON.stringify(a).indexOf(word) >= 0 })
  }

  property Component timerComp: Component { Timer { property var fn; onTriggered: { fn(); destroy() } } }
  function later(ms, fn) {
    var t = timerComp.createObject(h, { interval: Math.max(0, ms), fn: fn })
    t.start()
  }
}
