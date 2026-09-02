import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar widget and popup for the Nebula mesh VPN.
//
// Nebula has no status CLI the way Tailscale does, so the panel builds its
// picture from three cheap probes instead:
//
//   * `systemctl is-active` for the daemon,
//   * `ip -4 addr show` for the tunnel address, which only appears once the
//     interface is really up,
//   * one parallel ping sweep across the configured mesh members for
//     reachability and round-trip time.
//
// Reachability is what a ping sweep can honestly report: it says a peer answers
// over the tunnel, not that a direct tunnel was established rather than a
// relayed one. Nebula's own debug interface (the `sshd` block in config.yml)
// exposes the real hostmap, and if a user enables that, this panel is where the
// richer data would go.
//
// Starting and stopping the unit needs root. The widget tries plain `systemctl`
// first, which succeeds with no prompt when a polkit rule grants the desktop
// user that one unit, and falls back to `pkexec` otherwise. See the README.
Panel {
  id: root
  moduleName: "io.github.iryzhkov.nebula"
  ipcTarget: "io.github.iryzhkov.nebula"
  manageIpc: false

  // ------------------------------------------------------ input hardening
  //
  // Everything that crosses into this file from outside — settings that may be
  // hand-edited in shell.json, process output, IPC — is bounded and validated
  // before it reaches a command line, an allocation, or a Text item. The unit
  // and device names matter most: the unit name ends up under pkexec, so a
  // malformed setting must fall back to the default rather than reach a
  // privileged command.

  readonly property int maxNodes: 64
  readonly property int maxFieldChars: 128
  readonly property int maxErrorChars: 400
  readonly property int maxHelperBytes: 65536

  function boundText(value, max) {
    var s = String(value === undefined || value === null ? "" : value)
    return s.length > max ? s.slice(0, max) : s
  }

  function finiteNum(value, lo, hi, fallback) {
    var n = Number(value)
    if (!isFinite(n)) return fallback
    return Math.min(hi, Math.max(lo, n))
  }

  readonly property string unit: {
    var u = String(root.setting("unit", "nebula.service"))
    return /^[A-Za-z0-9:_.@-]{1,56}\.service$/.test(u) ? u : "nebula.service"
  }
  readonly property string device: {
    var d = String(root.setting("device", "nebula1"))
    return /^[A-Za-z0-9_.-]{1,15}$/.test(d) ? d : "nebula1"
  }
  readonly property int refreshIntervalSec: root.finiteNum(root.setting("refreshIntervalSec", 15), 2, 600, 15)
  readonly property int probeIntervalSec: root.finiteNum(root.setting("probeIntervalSec", 5), 2, 120, 5)

  // Mesh members, this host excluded. Nebula has no peer discovery a client can
  // query without its debug interface enabled, so the list is configuration:
  // one { name, address, role } object per node in this widget's shell.json
  // entry. `role` is "lighthouse" or "node" and defaults to "node". The list
  // is capped and every field bounded before anything else reads it.
  readonly property var nodes: {
    var configured = root.setting("nodes", [])
    if (!(configured instanceof Array)) return []
    var out = []
    for (var i = 0; i < configured.length && out.length < root.maxNodes; i++) {
      var entry = configured[i]
      if (!entry) continue
      out.push({
        name: root.boundText(entry.name, root.maxFieldChars),
        address: root.boundText(entry.address, root.maxFieldChars),
        role: root.boundText(entry.role || "node", 16)
      })
    }
    return out
  }

  // Fixed absolute executables, a minimal explicit environment, and a hard
  // deadline for every unprivileged helper. GNU timeout signals the child's
  // own process group, TERM then KILL, so nothing outlives the deadline;
  // Process reaps on exit. The pkexec escalation path deliberately does not
  // go through this wrapper — pkexec sanitizes its own environment, and a
  // deadline here would kill the polkit agent's password prompt while the
  // user is still typing.
  function helperCommand(seconds, argv) {
    return ["/usr/bin/env", "-i", "PATH=/usr/local/bin:/usr/bin:/bin",
      "/usr/bin/timeout", "--kill-after=2", String(seconds)].concat(argv)
  }

  property bool unitActive: false
  property string tunnelAddress: ""
  property bool busy: false
  property bool probing: false
  property string lastError: ""

  // address -> round-trip time in ms, or -1 when the last sweep got no reply.
  property var reachability: ({})

  // Toggle bookkeeping: which verb is in flight, and whether the plain
  // systemctl attempt has already failed and been retried under pkexec.
  property string pendingVerb: ""
  property bool escalated: false
  property string toggleStderr: ""

  readonly property bool connected: unitActive && tunnelAddress !== ""
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color accent: bar ? bar.accent : Color.accent
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color barIconColor: connected ? barForeground : Qt.darker(barForeground, 1.55)

  readonly property var lighthouses: nodesWithRole("lighthouse")
  readonly property var peers: nodesWithRole("node")

  readonly property string statusText: {
    if (busy) return "working…"
    if (lastError !== "") return lastError
    if (connected) return "connected · " + tunnelAddress
    if (unitActive) return "starting · no tunnel address yet"
    return "disconnected"
  }

  readonly property int reachableCount: {
    var total = 0
    for (var i = 0; i < nodes.length; i++) {
      if (rttFor(nodes[i].address) >= 0) total += 1
    }
    return total
  }

  function nodesWithRole(role) {
    var out = []
    for (var i = 0; i < nodes.length; i++) {
      if (String(nodes[i].role || "node") === role) out.push(nodes[i])
    }
    return out
  }

  // -1 means "did not answer the last sweep"; undefined means "never probed".
  function rttFor(address) {
    var value = reachability[String(address)]
    return value === undefined ? -1 : value
  }

  function rttLabel(address) {
    var value = rttFor(address)
    if (value < 0) return "—"
    return value.toFixed(value < 10 ? 1 : 0) + " ms"
  }

  function refresh() {
    if (!unitProc.running) unitProc.running = true
    if (!addressProc.running) addressProc.running = true
  }

  function probe() {
    if (probing || !connected || nodes.length === 0) return
    var addresses = []
    for (var i = 0; i < nodes.length; i++) {
      var address = String(nodes[i].address || "")
      // Only plain IPv4 literals with valid octets reach the shell, so a
      // hand-edited shell.json cannot turn a node entry into a command
      // substitution.
      if (/^(25[0-5]|2[0-4]\d|1?\d?\d)(\.(25[0-5]|2[0-4]\d|1?\d?\d)){3}$/.test(address))
        addresses.push(address)
    }
    if (addresses.length === 0) return
    probing = true
    // One backgrounded ping per node, then wait: the sweep costs one round of
    // latency rather than the sum of them, which matters with a node or two
    // timing out at 2s each. The script runs under the fixed-executable,
    // minimal-environment, hard-deadline wrapper; each ping already gives up
    // after 2s, so the 15s deadline only matters if something wedges.
    pingProc.command = root.helperCommand(15, ["/bin/bash", "-c",
      'for ip in ' + addresses.join(" ") + '; do ' +
      '( rtt=$(/usr/bin/ping -c 1 -W 2 -q "$ip" 2>/dev/null | ' +
      '/usr/bin/sed -n "s|.*= [0-9.]*/\\([0-9.]*\\)/.*|\\1|p"); ' +
      'echo "$ip ${rtt:--1}" ) & done; wait'])
    pingProc.running = true
  }

  function toggleVpn() {
    if (busy) return
    busy = true
    lastError = ""
    escalated = false
    toggleStderr = ""
    pendingVerb = unitActive ? "stop" : "start"
    // --no-ask-password makes the unprivileged attempt strictly
    // non-interactive: where polkit would prompt, systemctl fails at once
    // with "Interactive authentication required" and the pkexec fallback
    // owns the prompting. Without it, some polkit configurations would ask
    // through this call too, racing the 30s deadline while the user types.
    toggleProc.command = root.helperCommand(30,
      ["/usr/bin/systemctl", "--no-ask-password", pendingVerb, unit])
    toggleProc.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "io.github.iryzhkov.nebula"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh(); root.probe() }

    // Not named connect/disconnect: those collide with QObject's own slots.
    function vpnOn(): void { if (!root.unitActive) root.toggleVpn() }
    function vpnOff(): void { if (root.unitActive) root.toggleVpn() }
    function vpnToggle(): void { root.toggleVpn() }

    function status(): string {
      if (!root.unitActive) return "down"
      if (!root.connected) return "starting"
      return "up " + root.tunnelAddress
        + (root.nodes.length > 0
            ? " · " + root.reachableCount + "/" + root.nodes.length + " reachable"
            : "")
    }
  }

  Process {
    id: unitProc
    command: root.helperCommand(5, ["/usr/bin/systemctl", "is-active", "--quiet", root.unit])
    onExited: function (exitCode) {
      root.unitActive = exitCode === 0
      if (!root.unitActive) {
        root.tunnelAddress = ""
        root.reachability = ({})
      }
    }
  }

  Process {
    id: addressProc
    command: root.helperCommand(5, ["/usr/bin/ip", "-4", "-brief", "addr", "show", root.device])
    stdout: StdioCollector {
      onStreamFinished: {
        // `ip -brief` prints "nebula1 UNKNOWN 10.42.0.5/24"; take the CIDR.
        // One line expected; the slice bounds the regex input either way.
        var match = String(text).slice(0, 4096).match(/(\d+\.\d+\.\d+\.\d+\/\d+)/)
        root.tunnelAddress = match ? match[1] : ""
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) root.tunnelAddress = ""
    }
  }

  Process {
    id: pingProc
    property int collectedBytes: 0
    stdout: SplitParser {
      onRead: function (line) {
        // One short line per node is expected; stop the producer outright if
        // something floods the pipe instead.
        pingProc.collectedBytes += line.length
        if (pingProc.collectedBytes > root.maxHelperBytes) { pingProc.running = false; return }
        var parts = String(line).trim().slice(0, 64).split(/\s+/)
        if (parts.length < 2) return
        var value = parseFloat(parts[1])
        // Reassigning the whole map is what makes QML re-evaluate the bindings
        // that read it; mutating in place would leave every row stale.
        var next = Object.assign({}, root.reachability)
        next[parts[0]] = isFinite(value) && value >= 0 ? value : -1
        root.reachability = next
      }
    }
    onExited: {
      root.probing = false
      pingProc.collectedBytes = 0
    }
  }

  // A sweep in flight serves nobody once the panel is closed.
  onOpenedChanged: {
    if (!opened) {
      pingProc.running = false
      probing = false
    }
  }

  Process {
    id: toggleProc
    stderr: StdioCollector {
      onStreamFinished: root.toggleStderr = root.boundText(String(text).trim(), root.maxErrorChars)
    }
    onExited: function (exitCode) {
      // A plain systemctl call succeeds only where a polkit rule already grants
      // this user the unit. Where it does not, systemctl reports the denied
      // authorization and pkexec takes over, which the desktop's polkit agent
      // turns into a prompt. Other failures — a missing unit, a bad config —
      // would fail identically under root, so they surface as errors instead
      // of a pointless password dialog.
      var denied = /access denied|authentication|permission denied|not authorized/i.test(root.toggleStderr)
      if (exitCode !== 0 && denied && !root.escalated) {
        root.escalated = true
        Qt.callLater(function () {
          toggleProc.command = ["/usr/bin/pkexec", "/usr/bin/systemctl", root.pendingVerb, root.unit]
          toggleProc.running = true
        })
        return
      }

      root.busy = false
      root.lastError = exitCode === 0
        ? ""
        : (root.toggleStderr !== "" ? root.toggleStderr : "could not " + root.pendingVerb + " " + root.unit)
      root.refresh()
      settleTimer.restart()
    }
  }

  // The tunnel address lands a beat after the unit reports active, so take a
  // second look shortly after a toggle instead of waiting for the next tick.
  Timer {
    id: settleTimer
    interval: 1500
    repeat: false
    onTriggered: { root.refresh(); root.probe() }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Pinging every mesh member is only worth the traffic while someone is
  // looking at the list.
  Timer {
    interval: root.probeIntervalSec * 1000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: { root.refresh(); root.probe() }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.connected ? "\u{F0318}" : "\u{F0319}"
    foreground: root.barIconColor
    useActiveColor: false
    opacity: root.busy ? 0.5 : 1.0
    tooltipText: root.connected
      ? "Nebula up — " + root.tunnelAddress
      : (root.unitActive ? "Nebula starting" : "Nebula down")
    onPressed: function (buttonCode) {
      if (buttonCode === Qt.RightButton) root.toggleVpn()
      else if (buttonCode === Qt.MiddleButton) { root.refresh(); root.probe() }
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- Hero: icon · title/status · on-off switch ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroSwitch.implicitHeight)

          Text {
            id: heroIcon
            text: root.connected ? "\u{F0318}" : "\u{F0319}"
            color: root.connected ? root.foreground : root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter

            Behavior on color { ColorAnimation { duration: 200 } }
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(12)
            anchors.right: heroSwitch.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Nebula"
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              text: root.statusText.toUpperCase()
              textFormat: Text.PlainText
              color: root.lastError !== "" ? root.urgent : Qt.darker(root.foreground, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.1
              elide: Text.ElideRight
              width: parent.width
            }
          }

          ToggleSwitch {
            id: heroSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.unitActive
            busy: root.busy
            foreground: root.foreground
            accent: root.accent
            onToggled: root.toggleVpn()
          }
        }

        PanelSeparator { foreground: root.foreground }

        // ---------- Lighthouses ----------
        PanelSectionHeader {
          text: root.lighthouses.length === 1 ? "LIGHTHOUSE" : "LIGHTHOUSES"
          foreground: root.foreground
          fontFamily: root.fontFamily
          visible: root.lighthouses.length > 0
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.lighthouses.length > 0

          Repeater {
            model: root.lighthouses
            NodeRow { node: modelData }
          }
        }

        PanelSeparator {
          foreground: root.foreground
          visible: root.lighthouses.length > 0 && root.peers.length > 0
        }

        // ---------- Everything else on the mesh ----------
        PanelSectionHeader {
          text: "MESH NODES"
          foreground: root.foreground
          fontFamily: root.fontFamily
          visible: root.peers.length > 0
        }

        Column {
          width: parent.width
          spacing: Style.space(4)
          visible: root.peers.length > 0

          Repeater {
            model: root.peers
            NodeRow { node: modelData }
          }
        }

        // ---------- Empty state ----------
        // Nebula cannot be asked who else is on the mesh, so an unconfigured
        // widget has nothing to list and should say why rather than look broken.
        Text {
          width: parent.width
          visible: root.nodes.length === 0
          wrapMode: Text.WordWrap
          horizontalAlignment: Text.AlignHCenter
          color: Qt.darker(root.foreground, 1.4)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          text: "No mesh nodes configured.\nAdd a \"nodes\" list to this widget's entry\nin ~/.config/omarchy/shell.json."
        }

        // ---------- Footer ----------
        Text {
          width: parent.width
          visible: root.nodes.length > 0
          horizontalAlignment: Text.AlignHCenter
          color: Qt.darker(root.foreground, 1.5)
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          textFormat: Text.PlainText
          text: root.connected
            ? root.reachableCount + " of " + root.nodes.length + " reachable"
            : "Turn Nebula on to probe the mesh"
        }
      }
    }
  }

  // One mesh member: a reachability dot, the node name, its Nebula address and
  // the last round-trip time. Everything greys out when the tunnel is down,
  // because nothing was measured then and a stale green dot would lie.
  component NodeRow: Item {
    property var node: null

    readonly property string address: node ? String(node.address) : ""
    readonly property real rtt: root.connected ? root.rttFor(address) : -1
    readonly property bool up: rtt >= 0

    width: parent ? parent.width : 0
    implicitHeight: Math.max(nameText.implicitHeight, rttText.implicitHeight, Style.space(18))

    Rectangle {
      id: dot
      width: Style.space(7)
      height: width
      radius: width / 2
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      color: parent.up ? root.accent : Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.22)

      Behavior on color { ColorAnimation { duration: 200 } }
    }

    Text {
      id: nameText
      anchors.left: dot.right
      anchors.leftMargin: Style.space(9)
      anchors.verticalCenter: parent.verticalCenter
      text: parent.node ? String(parent.node.name) : ""
      textFormat: Text.PlainText
      color: parent.up ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Text {
      id: addressText
      anchors.left: nameText.right
      anchors.leftMargin: Style.space(8)
      anchors.right: rttText.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: parent.address
      textFormat: Text.PlainText
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      elide: Text.ElideRight
    }

    Text {
      id: rttText
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      text: root.connected ? root.rttLabel(parent.address) : "—"
      textFormat: Text.PlainText
      color: parent.up ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
