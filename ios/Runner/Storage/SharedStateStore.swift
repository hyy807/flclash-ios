import Foundation
import WidgetKit

final class SharedStateStore {
  private let sharedStateKey = "sharedState"
  private let setupParamsKey = "setupParams"
  private let runTimeKey = "runTime"

  private let eventQueueDirectoryName = "core-events"

  let appGroupIdentifier = AppGroupProfileResolver.resolve(
    bundleURL: Bundle.main.bundleURL,
    fallbackBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.follow.clash"
  )
  let eventNotificationName = "\(Bundle.main.bundleIdentifier!).NECore.event"

  func activeVpnOptions() -> String? {
    guard
      let data = UserDefaults(suiteName: appGroupIdentifier)?
        .data(forKey: "activeVpnOptions")
    else {
      return nil
    }
    return String(data: data, encoding: .utf8)
  }

  func saveSharedState(_ data: Data) -> Bool {
    guard let userDefaults = UserDefaults(suiteName: appGroupIdentifier) else {
      return false
    }
    let previousData = userDefaults.data(forKey: sharedStateKey)
    let previousControlDisplayState = controlDisplayState(from: previousData)
    let previousStatusDisplayState = statusDisplayState(from: previousData)
    if let json = try? JSONSerialization.jsonObject(with: data)
      as? [String: Any],
      let setupParams = json[setupParamsKey],
      !(setupParams is NSNull),
      JSONSerialization.isValidJSONObject(setupParams),
      let setupData = try? JSONSerialization.data(withJSONObject: setupParams)
    {
      userDefaults.set(setupData, forKey: setupParamsKey)
    }
    userDefaults.set(data, forKey: sharedStateKey)
    userDefaults.synchronize()
    if previousControlDisplayState != controlDisplayState(from: data),
      #available(iOS 18.0, *)
    {
      ControlCenter.shared.reloadControls(
        ofKind: "\(Bundle.main.bundleIdentifier!).Widget"
      )
    }
    if previousStatusDisplayState != statusDisplayState(from: data) {
      WidgetCenter.shared.reloadTimelines(
        ofKind: "\(Bundle.main.bundleIdentifier!).Widget.Status"
      )
    }
    return true
  }

  private func sharedStateJSON(from data: Data?) -> [String: Any]? {
    guard let data else {
      return nil
    }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func statusDisplayState(from data: Data?) -> NSDictionary {
    let json = sharedStateJSON(from: data)
    return [
      "currentProfileName": json?["currentProfileName"] ?? NSNull(),
      "widgetTheme": json?["widgetTheme"] ?? NSNull(),
    ]
  }

  private func controlDisplayState(
    from data: Data?
  ) -> (showProfileName: Bool, profileName: String?) {
    guard let json = sharedStateJSON(from: data) else {
      return (true, nil)
    }
    let showProfileName = json["showQuickSettingsProfileName"] as? Bool ?? true
    return (
      showProfileName,
      showProfileName ? json["currentProfileName"] as? String : nil
    )
  }

  func loadTunnelConfiguration() -> TunnelConfiguration {
    guard let userDefaults = UserDefaults(suiteName: appGroupIdentifier),
      let data = userDefaults.data(forKey: sharedStateKey),
      let sharedState = try? JSONDecoder().decode(
        SharedStatePayload.self,
        from: data
      )
    else {
      return TunnelConfiguration()
    }
    return TunnelConfiguration(
      options: sharedState.vpnOptions?.networkExtensionOptions ?? NetworkExtensionOptions(),
      excludeSSIDs: sharedState.excludeSSIDs ?? [],
      alwaysOn: sharedState.alwaysOn ?? false
    )
  }

  func appGroupDirectory() -> URL? {
    FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdentifier
    )
  }

  func eventQueueDirectory() -> URL? {
    appGroupDirectory()?.appendingPathComponent(
      eventQueueDirectoryName,
      isDirectory: true
    )
  }

  func runTime() -> Int {
    UserDefaults(suiteName: appGroupIdentifier)?
      .integer(forKey: runTimeKey) ?? 0
  }
}

struct TunnelConfiguration {
  let options: NetworkExtensionOptions
  let excludeSSIDs: [String]
  let alwaysOn: Bool

  init(
    options: NetworkExtensionOptions = NetworkExtensionOptions(),
    excludeSSIDs: [String] = [],
    alwaysOn: Bool = false
  ) {
    self.options = options
    self.excludeSSIDs = excludeSSIDs
    self.alwaysOn = alwaysOn
  }
}

struct NetworkExtensionOptions {
  var includeAllNetworks = false
  var excludeLocalNetworks = true
  var excludeAPNs = true
  var excludeCellularServices = true
  var enforceRoutes = false
  var excludeDeviceCommunication = true
}

private struct SharedStatePayload: Decodable {
  let vpnOptions: VpnOptionsPayload?
  let excludeSSIDs: [String]?
  let alwaysOn: Bool?
}

private struct VpnOptionsPayload: Decodable {
  let includeAllNetworks: Bool?
  let excludeLocalNetworks: Bool?
  let excludeAPNs: Bool?
  let excludeCellularServices: Bool?
  let enforceRoutes: Bool?
  let excludeDeviceCommunication: Bool?

  var networkExtensionOptions: NetworkExtensionOptions {
    NetworkExtensionOptions(
      includeAllNetworks: includeAllNetworks ?? false,
      excludeLocalNetworks: excludeLocalNetworks ?? true,
      excludeAPNs: excludeAPNs ?? true,
      excludeCellularServices: excludeCellularServices ?? true,
      enforceRoutes: enforceRoutes ?? false,
      excludeDeviceCommunication: excludeDeviceCommunication ?? true
    )
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
