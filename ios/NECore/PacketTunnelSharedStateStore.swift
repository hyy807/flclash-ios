import Foundation

enum PacketTunnelEnvironment {
  static let extensionBundleIdentifier = Bundle.main.bundleIdentifier!
  static let baseBundleIdentifier = String(
    extensionBundleIdentifier.dropLast(".NECore".count)
  )
  /// The group the signer granted, resolved from the embedded profile; the
  /// derived name is only the fallback.
  static let appGroupIdentifier = AppGroupProfileResolver.resolve(
    bundleURL: Bundle.main.bundleURL,
    fallbackBundleIdentifier: baseBundleIdentifier
  )
  static let widgetIdentifier = "\(baseBundleIdentifier).Widget"
  static let eventNotificationName =
    "\(extensionBundleIdentifier).event"
}

final class PacketTunnelSharedStateStore {
  private static let emptySetupParams = Data("{}".utf8)

  private let sharedStateKey = "sharedState"
  private let setupParamsKey = "setupParams"
  private let runTimeKey = "runTime"
  private let activeVpnOptionsKey = "activeVpnOptions"

  func loadVPNOptionsSnapshot() -> (options: PacketTunnelVPNOptions, data: Data)? {
    guard let sharedData = userDefaults?.data(forKey: sharedStateKey),
      let shared = try? JSONSerialization.jsonObject(with: sharedData) as? [String: Any],
      let rawOptions = shared["vpnOptions"] as? [String: Any],
      let data = try? JSONSerialization.data(withJSONObject: rawOptions),
      let options = try? JSONDecoder().decode(PacketTunnelVPNOptions.self, from: data)
    else {
      return nil
    }
    return (options, data)
  }

  func loadSetupParams() -> Data {
    guard let userDefaults else {
      return Self.emptySetupParams
    }
    if let data = userDefaults.data(forKey: setupParamsKey) {
      return data
    }
    guard let sharedStateData = userDefaults.data(forKey: sharedStateKey),
      let json = try? JSONSerialization.jsonObject(with: sharedStateData)
        as? [String: Any],
      let setupParams = json[setupParamsKey],
      !(setupParams is NSNull),
      JSONSerialization.isValidJSONObject(setupParams),
      let data = try? JSONSerialization.data(withJSONObject: setupParams)
    else {
      return Self.emptySetupParams
    }
    userDefaults.set(data, forKey: setupParamsKey)
    return data
  }

  func makeInitParams() -> String {
    let homeDirectory = appGroupDirectory()?.path ?? ""
    return "{\"home-dir\":\"\(homeDirectory)\",\"version\":0}"
  }


  /// Appends a line to the extension's own trace file in the shared container.
  /// The app copies it into its Documents on the next launch, because the
  /// extension has no readable log of its own and a tunnel that dies instantly
  /// leaves nothing behind.
  func trace(_ line: String) {
    guard let directory = appGroupDirectory() else { return }
    let url = directory.appendingPathComponent("extension-start.log")
    let stamp = ISO8601DateFormatter().string(from: Date())
    guard let data = "\(stamp) [ext] \(line)\n".data(using: .utf8) else { return }
    if let handle = try? FileHandle(forWritingTo: url) {
      handle.seekToEndOfFile()
      handle.write(data)
      try? handle.close()
    } else {
      try? data.write(to: url, options: .atomic)
    }
  }

  func appGroupDirectory() -> URL? {
    FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier:
        PacketTunnelEnvironment.appGroupIdentifier
    )
  }

  func saveRunTime(vpnOptions: Data) {
    let milliseconds = Int(Date().timeIntervalSince1970 * 1000)
    userDefaults?.set(vpnOptions, forKey: activeVpnOptionsKey)
    userDefaults?.set(milliseconds, forKey: runTimeKey)
  }

  func clearRunTime() {
    userDefaults?.removeObject(forKey: runTimeKey)
    userDefaults?.removeObject(forKey: activeVpnOptionsKey)
  }

  private var userDefaults: UserDefaults? {
    UserDefaults(
      suiteName: PacketTunnelEnvironment.appGroupIdentifier
    )
  }
}

struct PacketTunnelVPNOptions: Decodable {
  let port: Int
  let ipv6: Bool
  let captureDns: Bool
  let systemProxy: Bool
  let bypassDomain: [String]
  let stack: String
  let mtu: Int
  let routeAddress: [String]
  let disableIcmpForwarding: Bool
  let endpointIndependentNat: Bool
  let congestionController: String
  let recvMsgX: Bool
  let sendMsgX: Bool
  let includeAllNetworks: Bool
  let excludeLocalNetworks: Bool
  let excludeAPNs: Bool
  let excludeCellularServices: Bool
  let enforceRoutes: Bool
  let excludeDeviceCommunication: Bool

  private enum CodingKeys: String, CodingKey {
    case port
    case ipv6
    case captureDns
    case systemProxy
    case bypassDomain
    case stack
    case mtu
    case routeAddress
    case disableIcmpForwarding
    case endpointIndependentNat
    case congestionController
    case recvMsgX
    case sendMsgX
    case includeAllNetworks
    case excludeLocalNetworks
    case excludeAPNs
    case excludeCellularServices
    case enforceRoutes
    case excludeDeviceCommunication
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    port = try container.decode(Int.self, forKey: .port)
    ipv6 = try container.decode(Bool.self, forKey: .ipv6)
    captureDns = try container.decode(Bool.self, forKey: .captureDns)
    systemProxy = try container.decode(Bool.self, forKey: .systemProxy)
    bypassDomain = try container.decodeIfPresent(
      [String].self,
      forKey: .bypassDomain
    ) ?? []
    stack = try container.decode(String.self, forKey: .stack)
    mtu = try container.decodeIfPresent(Int.self, forKey: .mtu) ?? 9000
    routeAddress = try container.decodeIfPresent(
      [String].self,
      forKey: .routeAddress
    ) ?? []
    disableIcmpForwarding = try container.decodeIfPresent(
      Bool.self,
      forKey: .disableIcmpForwarding
    ) ?? false
    endpointIndependentNat = try container.decodeIfPresent(
      Bool.self,
      forKey: .endpointIndependentNat
    ) ?? false
    congestionController = try container.decodeIfPresent(
      String.self,
      forKey: .congestionController
    ) ?? ""
    recvMsgX = try container.decodeIfPresent(Bool.self, forKey: .recvMsgX) ?? true
    sendMsgX = try container.decodeIfPresent(Bool.self, forKey: .sendMsgX) ?? false
    includeAllNetworks = try container.decodeIfPresent(
      Bool.self,
      forKey: .includeAllNetworks
    ) ?? false
    excludeLocalNetworks = try container.decodeIfPresent(
      Bool.self,
      forKey: .excludeLocalNetworks
    ) ?? true
    excludeAPNs = try container.decodeIfPresent(
      Bool.self,
      forKey: .excludeAPNs
    ) ?? true
    excludeCellularServices = try container.decodeIfPresent(
      Bool.self,
      forKey: .excludeCellularServices
    ) ?? true
    enforceRoutes = try container.decodeIfPresent(
      Bool.self,
      forKey: .enforceRoutes
    ) ?? false
    excludeDeviceCommunication = try container.decodeIfPresent(
      Bool.self,
      forKey: .excludeDeviceCommunication
    ) ?? true
  }
}

/// Reads the App Group out of the provisioning profile the signer embedded.
///
/// An unsigned IPA is re-signed by whatever tool the user has (ESign,
/// Sideloadly, AltStore, TrollStore), and those tools may rename the bundle and
/// grant their own group. A hard-coded `group.<bundle id>` then points at a
/// container that does not exist: state is written where the other process
/// cannot read it and the tunnel fails with missingVPNOptions.
///
/// iOS does not expose a process's own entitlements to Swift (SecTask is not
/// public there), so the profile is parsed instead. TrollStore installs carry
/// no profile; there the derived name is right, because the bundle id is kept.
enum AppGroupProfileResolver {
  static func resolve(bundleURL: URL, fallbackBundleIdentifier: String) -> String {
    let bundles = [bundleURL, containingApp(of: bundleURL)].compactMap { $0 }
    for bundle in bundles {
      if let group = group(in: bundle) {
        return group
      }
    }
    return "group.\(fallbackBundleIdentifier)"
  }

  private static func containingApp(of bundleURL: URL) -> URL? {
    guard bundleURL.pathExtension == "appex" else {
      return nil
    }
    return bundleURL.deletingLastPathComponent().deletingLastPathComponent()
  }

  private static func group(in bundleURL: URL) -> String? {
    let profileURL = bundleURL.appendingPathComponent("embedded.mobileprovision")
    guard let data = try? Data(contentsOf: profileURL),
      let start = data.range(of: Data("<?xml".utf8)),
      let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
      let plist = try? PropertyListSerialization.propertyList(
        from: data.subdata(in: start.lowerBound..<end.upperBound),
        options: [],
        format: nil
      ) as? [String: Any],
      let entitlements = plist["Entitlements"] as? [String: Any],
      let groups = entitlements["com.apple.security.application-groups"] as? [String],
      let group = groups.first,
      !group.isEmpty
    else {
      return nil
    }
    return group
  }
}
