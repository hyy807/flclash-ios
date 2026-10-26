import Flutter
import NetworkExtension
import UIKit
import os

/// Startup breadcrumbs written from the first delegate callback onward.
///
/// The Dart side (`StartupTrace`) can only write once `main()` runs and once it
/// found a writable directory. This writes earlier and from a place where the
/// sandbox path is guaranteed, so the log tells the story apart: Swift lines
/// but no Dart lines means the engine never reached Dart; stopping after
/// "engine initialized" means Dart started and then stopped.
///
/// Lives in `Documents/`, which `UIFileSharingEnabled` exposes to the Files app.
/// Descriptor used by the SIGQUIT handler. A C function pointer cannot capture
/// context, so the descriptor lives at file scope.
private var startupProbeFD: Int32 = -1

enum StartupLog {
  private static let fileName = "flclash-startup.log"
  private static let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.follow.clash",
    category: "Startup"
  )

  static var fileURL: URL? {
    FileManager.default
      .urls(for: .documentDirectory, in: .userDomainMask)
      .first?
      .appendingPathComponent(fileName)
  }

  static func mark(_ phase: String) {
    logger.info("\(phase, privacy: .public)")
    guard let url = fileURL else {
      return
    }
    append("\(ISO8601DateFormatter().string(from: Date())) [swift] \(phase)\n", to: url)
  }



  /// Pulls the packet tunnel's own trace out of the shared container into this
  /// log, because an extension that dies on launch leaves nothing readable.
  static func importExtensionTrace() {
    let group = AppGroupProfileResolver.resolve(
      bundleURL: Bundle.main.bundleURL,
      fallbackBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.follow.clash"
    )
    guard
      let directory = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: group
      )
    else {
      mark("ext trace: no app group container (\(group))")
      return
    }
    let source = directory.appendingPathComponent("extension-start.log")
    guard let text = try? String(contentsOf: source, encoding: .utf8) else {
      mark("ext trace: extension never wrote a trace file")
      return
    }
    mark("ext trace from \(group):")
    for line in text.split(separator: "\n").suffix(80) {
      mark("  \(line)")
    }
    try? FileManager.default.removeItem(at: source)
  }

  /// Reads the provisioning profile the signer embedded and records the
  /// entitlements it grants. This is the only way, from inside the app, to tell
  /// whether the re-sign actually carried Network Extension and the App Group —
  /// and it answers "is the certificate the problem" with evidence.
  static func dumpSignedProfile() {
    let bundleURL = Bundle.main.bundleURL
    let profileURL = bundleURL.appendingPathComponent("embedded.mobileprovision")
    guard let data = try? Data(contentsOf: profileURL) else {
      mark("profile: NO embedded.mobileprovision (unsigned install?)")
      return
    }
    guard let start = data.range(of: Data("<?xml".utf8)),
      let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
      let plist = try? PropertyListSerialization.propertyList(
        from: data.subdata(in: start.lowerBound..<end.upperBound),
        options: [],
        format: nil
      ) as? [String: Any]
    else {
      mark("profile: unparseable")
      return
    }
    let entitlements = (plist["Entitlements"] as? [String: Any]) ?? [:]
    let appId = entitlements["application-identifier"] as? String ?? "nil"
    let teamId = entitlements["team-identifier"] as? String ?? "nil"
    let groups = (entitlements["com.apple.security.application-groups"] as? [String])?.joined(separator: ",") ?? "none"
    let ne = entitlements["com.apple.developer.networking.networkextension"] as? [String]
    let expire = (plist["ExpirationDate"] as? Date).map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
    mark("profile: appId=\(appId) team=\(teamId) expires=\(expire)")
    mark("profile: networkextension=\(ne?.joined(separator: ",") ?? "ABSENT")")
    mark("profile: appGroups=\(groups)")
    mark("profile: allEntitlements=\(entitlements.keys.sorted().joined(separator: ","))")
  }


  /// Asks NetworkExtension for the saved configurations and logs the outcome.
  ///
  /// saveToPreferences never calling back is ambiguous: it can be the daemon
  /// refusing us (signing/entitlement) or a configuration problem. A read that
  /// answers immediately proves the framework talks to us at all, and its error
  /// domain/code says why it would not.
  static func probeNetworkExtension() {
    NETunnelProviderManager.loadAllFromPreferences { managers, error in
      if let error {
        let nsError = error as NSError
        StartupLog.mark(
          "ne probe: loadAllFromPreferences FAILED domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription)"
        )
        return
      }
      StartupLog.mark("ne probe: loadAllFromPreferences ok managers=\(managers?.count ?? 0)")
      for manager in managers ?? [] {
        let proto = manager.protocolConfiguration as? NETunnelProviderProtocol
        StartupLog.mark(
          "ne probe: manager enabled=\(manager.isEnabled) status=\(manager.connection.status.rawValue) provider=\(proto?.providerBundleIdentifier ?? "nil")"
        )
      }
    }
  }

  static func append(_ line: String, to url: URL) {
    guard let data = line.data(using: .utf8) else {
      return
    }
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: url, options: .atomic)
    }
  }

  /// Opens the log once and arms a signal handler that can still write after
  /// the process has been told to die.
  ///
  /// The crash reports show `EXC_CRASH (SIGQUIT)` with `byProc` pointing at
  /// Runner itself, and the Dart frames are an AOT snapshot with no symbols, so
  /// the only way to see the call chain that ends the process is to catch the
  /// signal and dump it from inside the handler with async-signal-safe calls
  /// (`backtrace_symbols_fd` writes straight to the descriptor).
  static func armQuitProbe() {
    guard let url = fileURL else {
      return
    }
    let path = url.path
    startupProbeFD = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard startupProbeFD >= 0 else {
      return
    }
    StartupLog.mark("quit probe armed")
    signal(SIGQUIT) { _ in
      let fd = startupProbeFD
      let message = "\n===== SIGQUIT caught, native frames follow =====\n"
      _ = message.withCString { pointer in
        write(fd, pointer, strlen(pointer))
      }
      var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 48)
      let count = backtrace(&frames, Int32(frames.count))
      backtrace_symbols_fd(&frames, count, fd)
      let tail = "===== end =====\n"
      _ = tail.withCString { pointer in
        write(fd, pointer, strlen(pointer))
      }
      // Restore the default and re-raise so the report is still generated.
      signal(SIGQUIT, SIG_DFL)
      raise(SIGQUIT)
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    StartupLog.mark("didFinishLaunching")
    StartupLog.dumpSignedProfile()
    StartupLog.mark("signed: \(IOSCoreBridge.effectiveEntitlements())")
    StartupLog.probeNetworkExtension()
    StartupLog.importExtensionTrace()
    StartupLog.armQuitProbe()
    atexit {
      StartupLog.mark("atexit fired")
    }
    let result = super.application(
      application,
      didFinishLaunchingWithOptions: launchOptions
    )
    StartupLog.mark("didFinishLaunching returned \(result)")
    return result
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    StartupLog.mark("engine initialized")
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    StartupLog.mark("plugins registered")
    ServiceChannel.register(with: engineBridge.applicationRegistrar.messenger())
    StartupLog.mark("service channel registered")
    registerAppGroupChannel(messenger: engineBridge.applicationRegistrar.messenger())
  }
}

/// Tells Dart where the shared container is. The tunnel extension runs in its
/// own sandbox and can only read the profile, providers and geo files if they
/// live in the App Group; Dart's default Application Support directory is
/// invisible to it, which made quickSetup fail with no config at all.
private func registerAppGroupChannel(messenger: FlutterBinaryMessenger) {
  let channel = FlutterMethodChannel(
    name: "com.follow.clash/app_group",
    binaryMessenger: messenger
  )
  channel.setMethodCallHandler { call, result in
    guard call.method == "containerPath" else {
      result(FlutterMethodNotImplemented)
      return
    }
    let group = AppGroupProfileResolver.resolve(
      bundleURL: Bundle.main.bundleURL,
      fallbackBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.follow.clash"
    )
    let url = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: group
    )
    StartupLog.mark("app group container for Dart: \(group) -> \(url?.path ?? "nil")")
    result(url?.path)
  }
}
