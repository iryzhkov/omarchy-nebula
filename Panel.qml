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
  moduleName: "iryzhkov.nebula"
  ipcTarget: "iryzhkov.nebula"
  manageIpc: false

  readonly property string unit: root.setting("unit", "nebula.service")
  readonly property string device: root.setting("device", "nebula1")
  readonly property int refreshIntervalSec: Math.max(2, root.setting("refreshIntervalSec", 15))
  readonly property int probeIntervalSec: Math.max(2, root.setting("probeIntervalSec", 5))

  // Mesh members, this host excluded. Nebula has no peer discovery a client can
  // query without its debug interface enabled, so the list is configuration:
  // one { name, address, role } object per node in this widget's shell.json
  // entry. `role` is "lighthouse" or "node" and defaults to "node".
  readonly property var nodes: {
    var configured = root.setting("nodes", [])
    return configured instanceof Array ? configured : []
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
      // Only plain IPv4 literals reach the shell, so a hand-edited shell.json
      // cannot turn a node entry into a command substitution.
      if (/^\d{1,3}(\.\d{1,3}){3}$/.test(address)) addresses.push(address)
    }
    if (addresses.length === 0) return
    probing = true
    // One backgrounded ping per node, then wait: the sweep costs one round of
    // latency rather than the sum of them, which matters with a node or two
    // timing out at 2s each.
    pingProc.command = ["bash", "-lc",
      'for ip in ' + addresses.join(" ") + '; do ' +
      '( rtt=$(ping -c 1 -W 2 -q "$ip" 2>/dev/null | ' +
      'sed -n "s|.*= [0-9.]*/\\([0-9.]*\\)/.*|\\1|p"); ' +
      'echo "$ip ${rtt:--1}" ) & done; wait']
    pingProc.running = true
  }

  function toggleVpn() {
    if (busy) return
    busy = true
    lastError = ""
    escalated = false
    toggleStderr = ""
    pendingVerb = unitActive ? "stop" : "start"
    toggleProc.command = ["systemctl", pendingVerb, unit]
    toggleProc.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  IpcHandler {
    target: "iryzhkov.nebula"

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
    command: ["systemctl", "is-active", "--quiet", root.unit]
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
    command: ["ip", "-4", "-brief", "addr", "show", root.device]
    stdout: StdioCollector {
      onStreamFinished: {
        // `ip -brief` prints "nebula1 UNKNOWN 10.42.0.5/24"; take the CIDR.
        var match = String(text).match(/(\d+\.\d+\.\d+\.\d+\/\d+)/)
        root.tunnelAddress = match ? match[1] : ""
      }
    }
    onExited: function (exitCode) {
      if (exitCode !== 0) root.tunnelAddress = ""
    }
  }

  Process {
    id: pingProc
    stdout: SplitParser {
      onRead: function (line) {
        var parts = String(line).trim().split(/\s+/)
        if (parts.length < 2) return
        var value = parseFloat(parts[1])
        // Reassigning the whole map is what makes QML re-evaluate the bindings
        // that read it; mutating in place would leave every row stale.
        var next = Object.assign({}, root.reachability)
        next[parts[0]] = isFinite(value) && value >= 0 ? value : -1
        root.reachability = next
      }
    }
    onExited: root.probing = false
  }

  Process {
    id: toggleProc
    stderr: StdioCollector {
      onStreamFinished: root.toggleStderr = String(text).trim()
    }
    onExited: function (exitCode) {
      // A plain systemctl call succeeds only where a polkit rule already grants
      // this user the unit. Everywhere else the first attempt fails and pkexec
      // takes over, which the desktop's polkit agent turns into a prompt.
      if (exitCode !== 0 && !root.escalated) {
        root.escalated = true
        Qt.callLater(function () {
          toggleProc.command = ["pkexec", "systemctl", root.pendingVerb, root.unit]
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
      color: parent.up ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }
  }
}
