import Flutter
import Foundation
import os

@MainActor
private final class CoreMessageRouterReference {
  weak var value: CoreMessageRouter?
}

/// Holds the newest start/stop command revision so the completion closures
/// created during `init` can read it without capturing `self`.
final class CommandRevisionBox {
  var value = 0
}

enum QuickAction: String {
  case start
  case stop
  case toggle

  // Before the engine is up only the latest intent survives: a toggle flips a pending start or
  // stop, and two toggles cancel out.
  func folded(onto pending: QuickAction?) -> QuickAction? {
    guard self == .toggle, let pending else {
      return self
    }
    switch pending {
    case .start:
      return .stop
    case .stop:
      return .start
    case .toggle:
      return nil
    }
  }
}

/// Bridges the Dart side of FlClash to the Network Extension.
///
/// Two channels, matching `lib/plugins/service.dart` and `lib/core/lib.dart`:
///
/// * `<bundle>/service` — lifecycle (init / start / stop / syncState /
///   shutdown / getRunTime) and the core's push events.
/// * `<bundle>/core` — method calls, UTF-8 JSON string in, UTF-8 JSON bytes out.
///
/// Core operations are answered by the copy of the core running inside the
/// extension once the tunnel is up, and by the app-side core before that.
@MainActor
final class ServiceChannel {
  private static var instance: ServiceChannel?
  private static var pendingQuickAction: QuickAction?

  private static let packageName = "com.follow.clash"
  private let channel: FlutterMethodChannel
  private let coreChannel: FlutterMethodChannel
  private let sharedStateStore: SharedStateStore
  private let tunnelController: TunnelController
  private let coreMessageRouter: CoreMessageRouter
  private let coreEventRelay: CoreEventRelay
  private let commandRevision: CommandRevisionBox
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.follow.clash",
    category: "ServiceChannel"
  )

  static func register(with messenger: FlutterBinaryMessenger) {
    let serviceChannel = ServiceChannel(messenger: messenger)
    instance = serviceChannel
    guard let action = pendingQuickAction else {
      return
    }
    pendingQuickAction = nil
    serviceChannel.perform(action)
  }

  static func request(_ action: QuickAction) {
    guard let instance else {
      pendingQuickAction = action.folded(onto: pendingQuickAction)
      return
    }
    instance.perform(action)
  }

  private func perform(_ action: QuickAction) {
    switch action {
    case .start:
      tunnelController.start()
    case .stop:
      tunnelController.stop()
    case .toggle:
      tunnelController.toggle()
    }
  }

  private init(messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "\(Self.packageName)/service",
      binaryMessenger: messenger
    )
    let coreChannel = FlutterMethodChannel(
      name: "\(Self.packageName)/core",
      binaryMessenger: messenger
    )
    let revisionBox = CommandRevisionBox()
    let sharedStateStore = SharedStateStore()
    let routerReference = CoreMessageRouterReference()
    let tunnelController = TunnelController(
      sharedStateStore: sharedStateStore,
      onTunnelStateChanged: { state in
        routerReference.value?.updateTunnelState(state)
      },
      onConnectionStateChanged: { state in
        // Pending includes connecting/disconnecting and is NOT a stopped run.
        // Reporting it as stopped makes Dart roll back and stop the tunnel
        // while startTunnel is still completing.
        guard state == "disconnected" else {
          return
        }
        let revision = revisionBox.value
        Task { @MainActor in
          channel.invokeMethod("stopped", arguments: revision)
        }
      },
      onExternalStart: {},
      onExternalStop: {}
    )
    let coreMessageRouter = CoreMessageRouter(
      tunnelController: tunnelController
    )
    routerReference.value = coreMessageRouter
    let coreEventRelay = CoreEventRelay(
      sharedStateStore: sharedStateStore,
      sendEvent: { event, completion in
        let payload = FlutterStandardTypedData(bytes: Data(event.utf8))
        channel.invokeMethod("event", arguments: payload) { callbackResult in
          completion(callbackResult == nil)
        }
      }
    )

    self.channel = channel
    self.coreChannel = coreChannel
    self.sharedStateStore = sharedStateStore
    self.tunnelController = tunnelController
    self.coreMessageRouter = coreMessageRouter
    self.coreEventRelay = coreEventRelay
    self.commandRevision = revisionBox

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handle(call, result: result)
    }
    coreChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(FlutterMethodNotImplemented)
        return
      }
      self.handleCore(call, result: result)
    }
    coreEventRelay.start()
    tunnelController.startObserving()
  }

  /// Method calls: UTF-8 JSON string in, UTF-8 JSON bytes out.
  private func handleCore(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "invokeMethod" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let message = call.arguments as? String,
      let data = message.data(using: .utf8)
    else {
      result(
        FlutterStandardTypedData(bytes: Data(invalidMethodCallResponse.utf8))
      )
      return
    }
    Task {
      let response = await coreMessageRouter.invoke(data)
      result(FlutterStandardTypedData(bytes: Data(response.utf8)))
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    log("handle method=\(call.method)")
    switch call.method {
    case "start":
      commandRevision.value = call.arguments as? Int ?? commandRevision.value
      StartupLog.mark("vpn: start requested revision=\(commandRevision.value)")
      tunnelController.start()
      StartupLog.mark("vpn: start dispatched")
      result(true)
    case "stop":
      commandRevision.value = call.arguments as? Int ?? commandRevision.value
      StartupLog.mark("vpn: native stop revision=\(commandRevision.value)")
      tunnelController.stop()
      result(true)
    case "init":
      tunnelController.publishConnectionState()
      coreEventRelay.drainEventQueue()
      result("")
    case "syncState":
      StartupLog.mark("vpn: syncState")
      syncState(call, result: result)
    case "shutdown":
      Task {
        tunnelController.stop()
        result(await coreMessageRouter.shutdownAppCore())
      }
    case "getRunTime":
      Task {
        result(await tunnelController.getRunTime())
      }
    case "getActiveVpnOptions":
      Task {
        let running = await tunnelController.getRunTime() > 0
        result(running ? sharedStateStore.activeVpnOptions() : nil)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func syncState(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    StartupLog.mark("syncState: appGroup=\(sharedStateStore.appGroupIdentifier)")
    guard let message = call.arguments as? String,
      let data = message.data(using: .utf8),
      sharedStateStore.saveSharedState(data)
    else {
      StartupLog.mark("syncState: saveSharedState FAILED")
      result("failed to sync shared state")
      return
    }
    log("saveSharedState bytes=\(data.count)")
    StartupLog.mark("syncState: saved bytes=\(data.count)")
    result("")
    Task {
      do {
        try await tunnelController.reloadOnDemandRules()
        StartupLog.mark("syncState: on-demand rules reloaded")
      } catch {
        StartupLog.mark("syncState: reload failed :: \(error.localizedDescription)")
      }
    }
  }

  private var invalidMethodCallResponse: String {
    #"{"result":null,"error":{"code":"invalid_method_call","message":"invalid method call","details":null}}"#
  }

  private func log(_ message: String) {
    logger.debug("\(message, privacy: .public)")
  }
}
