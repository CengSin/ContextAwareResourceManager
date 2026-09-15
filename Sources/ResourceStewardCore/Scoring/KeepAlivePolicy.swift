import Foundation

/// Apps that must keep running across every workspace: VPN / proxy / tunnels.
/// Freezing Shadowrocket (or Clash / Surge / WireGuard) drops the network path.
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
        "com.nekohasekai.sfaw"
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
        "forticlient"
    ]

    public static func isKeepAlive(bundleID: String?, processName: String, path: String = "") -> Bool {
        if let bundleID {
            if bundleIDs.contains(bundleID) { return true }
            let id = bundleID.lowercased()
            if id.contains("packettunnel")
                || id.contains("packet-tunnel")
                || id.contains("wireguard")
                || id.contains("networkextension")
                || id.contains("tunnelprovider") {
                return true
            }
        }
        let blob = ((bundleID ?? "") + " " + processName + " " + path).lowercased()
        return fragments.contains { blob.contains($0) }
    }
}
