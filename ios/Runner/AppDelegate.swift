import Flutter
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
    let line = "\(ISO8601DateFormatter().string(from: Date())) [swift] \(phase)\n"
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
}

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    StartupLog.mark("didFinishLaunching")
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
  }
}
