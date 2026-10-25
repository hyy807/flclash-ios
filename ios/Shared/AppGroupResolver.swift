import Foundation
import Security

/// Resolves the App Group container the bundle was actually signed with.
///
/// An unsigned IPA is re-signed by whatever tool the user happens to have
/// (ESign, Sideloadly, AltStore, TrollStore). Those tools may rename the bundle
/// and grant their own group; a hard-coded `group.<bundle id>` then points at a
/// container that does not exist. The app writes its state where the extension
/// cannot read it and `startTunnel` fails with missingVPNOptions — a "builds
/// fine, VPN won't start" report that has nothing to do with the tunnel code.
///
/// iOS does not expose the process's own entitlements to Swift (SecTask is not
/// public there), so the entitlements are read from the provisioning profile
/// the signer embedded in the bundle:
///
///   * `FlClash.app/embedded.mobileprovision` for the app,
///   * the same file inside the containing `.app` when running in the `.appex`.
///
/// The profile is a CMS blob; the plist starts at `<?xml` and is parsed
/// directly. TrollStore installs carry no profile: there the derived
/// `group.<bundle id>` is correct, because the bundle id is not rewritten.
public enum AppGroupResolver {
  public static func resolved(fallbackBundleIdentifier: String) -> String {
    if let group = groupFromProfile(appBundleURL()) {
      return group
    }
    if let group = groupFromProfile(Bundle.main.bundleURL) {
      return group
    }
    return "group.\(fallbackBundleIdentifier)"
  }

  /// The containing `.app` for an extension process, the bundle itself for the app.
  public static func appBundleURL() -> URL {
    let bundleURL = Bundle.main.bundleURL
    if bundleURL.pathExtension == "appex" {
      return bundleURL.deletingLastPathComponent().deletingLastPathComponent()
    }
    return bundleURL
  }

  private static func groupFromProfile(_ bundleURL: URL) -> String? {
    let profileURL = bundleURL.appendingPathComponent("embedded.mobileprovision")
    guard let data = try? Data(contentsOf: profileURL),
      let plistData = plistPayload(in: data),
      let plist = try? PropertyListSerialization.propertyList(
        from: plistData,
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

  private static func plistPayload(in data: Data) -> Data? {
    guard let start = data.range(of: Data("<?xml".utf8)),
      let end = data.range(
        of: Data("</plist>".utf8),
        in: start.lowerBound..<data.endIndex
      )
    else {
      return nil
    }
    return data.subdata(in: start.lowerBound..<end.upperBound)
  }
}
