import Foundation






public enum KeepAlivePolicy: Sendable {
    public static let bundleIDs: Set<String> = [
        "com.liguangming.Shadowrocket",
        "com.west2online.ClashX",
        "com.west2online.ClashXPro",
        "com.github.yichengchen.clashX",
        "com.github.yichengchen.clashXPro",
        "com.metacubex.ClashX",
        "com.clash.verge",
        "io.github.clash-verge-rev.clash-verge-rev",
        "com.nssurge.surge-mac",
        "com.nssurge.surge-dashboard",
        "com.nssurge.Surgex",
        "com.stash.mac",
        "uk.co.proxifier.mac",
        "com.wireguard.macos",
        "com.wireguard.ios.network-extension",
        "org.strongswan.osx",
        "net.openvpn.openvpn",
        "net.openvpn.connect",
        "io.tailscale.ipn.macsys",
        "io.tailscale.ipn.macos",
        "ch.protonvpn.mac",
        "com.protonvpn.mac",
        "com.nordvpn.NordVPN",
        "com.expressvpn.ExpressVPN",
        "com.privateinternetaccess.vpn",
        "org.outline.macos.client",
        "com.cloudflare.1dot1dot1dot1.macos",
        "com.cloudflare.warp",
        "com.zerotier.ZeroTier-One",
        "net.mullvad.MullvadVPN",
        "com.viscosityvpn.Viscosity",
        "net.twingate.macos",
        "com.cisco.anyconnect.gui",
        "com.fortinet.forticlient",
        "com.yanue.V2rayU",
        "net.ericek111.V2RayXS",
        "com.qiuyuzhou.ShadowsocksX-NG",
        "com.qiuyuzhou.shadowsocksX-NG",
        "clowwindy.ShadowsocksX",
        "io.nekohasekai.sfa",
        "com.nekohasekai.sfaw",
        "dev.kdrag0n.MacVirt",
        "dev.kdrag0n.MacVirt.vmgr",
        "dev.kdrag0n.MacVirt.scli",
        "com.orbstack.orbstack",
        "com.docker.docker",
        "com.electron.dockerdesktop",
        "com.docker.helper",
        "com.apple.docker",
        "io.github.containers.podman",
        "com.rancherdesktop.app",
        "io.rancherdesktop.app",
        "com.utmapp.UTM",
        "com.parallels.desktop.console",
        "com.vmware.fusion",
        "org.virtualbox.app.VirtualBox"
    ]

    private static let bundlePrefixes = [
        "dev.kdrag0n.macvirt",
        "com.docker.",
        "com.electron.docker",
        "io.lima.",
        "com.utmapp.",
        "com.parallels.",
        "com.vmware."
    ]

    private static let fragments = [
        "shadowrocket",
        "clashx",
        "clash-verge",
        "clash verge",
        "clash-meta",
        "mihomo",
        "nssurge",
        "surge-mac",
        "stash",
        "proxifier",
        "wireguard",
        "openvpn",
        "tailscale",
        "shadowsocks",
        "v2ray",
        "v2box",
        "sing-box",
        "singbox",
        "hysteria",
        "quantumult",
        "packet-tunnel",
        "packettunnel",
        "packetunnel",
        "nepackettunnel",
        "protonvpn",
        "nordvpn",
        "expressvpn",
        "mullvad",
        "zerotier",
        "cloudflare warp",
        "1.1.1.1",
        "outline",
        "viscosity",
        "twingate",
        "anyconnect",
        "forticlient",
        "orbstack",
        "macvirt",
        "docker.app",
        "docker desktop",
        "colima",
        "podman",
        "qemu-system",
        "rancher desktop",
        "rancherdesktop",
        "utm.app",
        "virtualbox",
        "containerd",
        ".orbstack/"
    ]

    private static let identityCache = IdentityRuleCache<Bool>()

    public static func isKeepAlive(bundleID: String?, processName: String, path: String = "") -> Bool {
        identityCache.value(bundleID: bundleID, processName: processName, path: path) {
            evaluate(bundleID: bundleID, processName: processName, path: path)
        }
    }

    private static func evaluate(bundleID: String?, processName: String, path: String) -> Bool {
        if let bundleID {
            if bundleIDs.contains(bundleID) { return true }
            let id = bundleID.lowercased()
            if bundlePrefixes.contains(where: { id == $0 || id.hasPrefix($0) }) {
                return true
            }
            if id.contains("packettunnel")
                || id.contains("packet-tunnel")
                || id.contains("wireguard")
                || id.contains("networkextension")
                || id.contains("tunnelprovider")
                || id.contains("orbstack") {
                return true
            }
        }
        let blob = ((bundleID ?? "") + " " + processName + " " + path).lowercased()
        return fragments.contains { blob.contains($0) }
    }

    
    
    public static func isUserListed(bundleID: String?, extras: Set<String>) -> Bool {
        guard !extras.isEmpty else { return false }
        if let bundleID, extras.contains(bundleID) { return true }
        if let root = ProcessFamily.rootBundleID(from: bundleID), extras.contains(root) {
            return true
        }
        return false
    }

    public static func shouldStayAlive(
        bundleID: String?,
        processName: String,
        path: String = "",
        extras: Set<String> = []
    ) -> Bool {
        isKeepAlive(bundleID: bundleID, processName: processName, path: path)
            || isUserListed(bundleID: bundleID, extras: extras)
    }
}
