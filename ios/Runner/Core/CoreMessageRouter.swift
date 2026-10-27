import Foundation
import os

private enum AppCoreMethod: String {
  case initClash
  case getIsInit
  case validateConfig
  case getProfileConfig
  case getConfig
  case decryptConfig
  case decryptAgeConfig
  case generateAgeKeyPair
  case convertAgeSecretKeyToPublicKey
  case deleteManagedPath
  case updateGeoData
  case getCountryCode
  case asyncTestDelay
}

private enum ConfigurationCoreMethod: String {
  case setupConfig
  case updateConfig
}

private struct CoreRoutingError: LocalizedError {
  let code: String
  let message: String
  var details: Any? = nil

  var errorDescription: String? {
    message
  }
}

@MainActor
final class CoreMessageRouter {
  private let tunnelController: TunnelController
  private var delayPreparation: Task<Void, Error>?
  private var configurationRevision = 0
  private var preparedDelayRevision: Int?
  private var configurationTransactionHeld = false
  private var configurationWaiters: [CheckedContinuation<Void, Never>] = []
  private var activeDelayMeasurements = 0
  private var delayDrainWaiter: CheckedContinuation<Void, Never>?
  private var currentRoute = CoreRoute.app
  private lazy var notificationCoordinator = CoreNotificationCoordinator(
    sendMessage: { [weak self] data, route in
      guard let self else {
        throw CoreRoutingError(
          code: "core_router_unavailable",
          message: "core router is unavailable"
        )
      }
      return try await self.sendCoreMessage(data, route: route)
    }
  )
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.follow.clash",
    category: "CoreMessageRouter"
  )

  init(tunnelController: TunnelController) {
    self.tunnelController = tunnelController
  }

  func updateTunnelState(_ state: TunnelTarget) {
    let route: CoreRoute = state == .running ? .networkExtension : .app
    if route != currentRoute { configurationRevision += 1 }
    currentRoute = route
    notificationCoordinator.setDesiredRoute(currentRoute)
  }

  func invoke(_ data: Data) async -> String {
    let method = methodCallName(data)
    if method == "changeProxy" || method == AppCoreMethod.initClash.rawValue {
      configurationRevision += 1
      preparedDelayRevision = nil
    }
    let action = notificationCoordinator.action(for: data)
    await notificationCoordinator.prepare(for: action)
    defer {
      notificationCoordinator.finish(action)
    }

    let selectedRoute = currentRoute
    let networkExtensionActive = selectedRoute == .networkExtension

    do {
      if case .stop(let kind) = action {
        return try await sendNotificationStop(
          data,
          kind: kind,
          defaultRoute: selectedRoute
        )
      }

      let routedResult: (response: String, route: CoreRoute)
      if method == AppCoreMethod.asyncTestDelay.rawValue {
        let revision = configurationRevision
        if networkExtensionActive {
          try await prepareAppDelayCore()
        }
        await acquireConfigurationGate()
        guard revision == configurationRevision else {
          releaseConfigurationTransaction()
          throw CoreRoutingError(code: "measurement_core_unavailable", message: "measurement configuration changed")
        }
        activeDelayMeasurements += 1
        releaseConfigurationTransaction()
        defer { finishDelayMeasurement() }
        let response = try await sendCoreMessage(data, route: .app)
        guard revision == configurationRevision else {
          throw CoreRoutingError(code: "measurement_core_unavailable", message: "measurement configuration changed during probe")
        }
        routedResult = (response, .app)
      } else if let method,
        let configurationMethod = ConfigurationCoreMethod(rawValue: method)
      {
        let response = try await sendConfigurationMessage(
          data,
          method: configurationMethod,
          networkExtensionActive: networkExtensionActive
        )
        routedResult = (
          response,
          networkExtensionActive ? .networkExtension : .app
        )
      } else {
        routedResult = try await sendRoutedCoreMessage(
          data,
          selectedRoute: route(
            method: method,
            defaultRoute: selectedRoute
          )
        )
      }
      if case .start(let kind) = action,
        methodResponseSucceeded(routedResult.response)
      {
        notificationCoordinator.recordSuccessfulStart(
          kind,
          data: data,
          route: routedResult.route
        )
      }
      return routedResult.response
    } catch let error as CoreRoutingError {
      return methodErrorResponse(
        data: data,
        code: error.code,
        message: error.message,
        details: error.details
      )
    } catch let error as ProviderMessageError {
      return methodErrorResponse(
        data: data,
        code: error.code,
        message: error.message
      )
    } catch {
      return methodErrorResponse(
        data: data,
        code: "core_routing_error",
        message: error.localizedDescription
      )
    }
  }

  func shutdownAppCore() async -> Bool {
    configurationRevision += 1
    preparedDelayRevision = nil
    await acquireConfigurationTransaction()
    defer { releaseConfigurationTransaction() }
    let methodCall = #"{"method":"shutdown","arguments":null}"#
    return await withCheckedContinuation { continuation in
      IOSCoreBridge.invokeMethod(methodCall) { [weak self] response in
        guard let response,
          let data = response.data(using: .utf8),
          let payload = try? JSONSerialization.jsonObject(with: data)
            as? [String: Any],
          let success = payload["result"] as? Bool
        else {
          self?.log("shutdownAppCore invalid response")
          continuation.resume(returning: false)
          return
        }
        self?.log("shutdownAppCore result=\(success)")
        continuation.resume(returning: success)
      }
    }
  }

  private func acquireConfigurationGate() async {
    if configurationTransactionHeld {
      await withCheckedContinuation { configurationWaiters.append($0) }
    } else {
      configurationTransactionHeld = true
    }
  }

  private func acquireConfigurationTransaction() async {
    await acquireConfigurationGate()
    if activeDelayMeasurements != 0 {
      await withCheckedContinuation { delayDrainWaiter = $0 }
    }
  }

  private func releaseConfigurationTransaction() {
    if configurationWaiters.isEmpty {
      configurationTransactionHeld = false
    } else {
      configurationWaiters.removeFirst().resume()
    }
  }

  private func finishDelayMeasurement() {
    activeDelayMeasurements -= 1
    if activeDelayMeasurements == 0 {
      delayDrainWaiter?.resume()
      delayDrainWaiter = nil
    }
  }

  private func prepareAppDelayCore() async throws {
    if preparedDelayRevision == configurationRevision { return }
    if let preparation = delayPreparation {
      try await preparation.value
      return
    }
    let revision = configurationRevision
    let task = Task { try await self.loadAppDelayCore(revision: revision) }
    delayPreparation = task
    defer { delayPreparation = nil }
    try await task.value
  }

  private func loadAppDelayCore(revision: Int) async throws {
    await acquireConfigurationTransaction()
    defer { releaseConfigurationTransaction() }
    guard revision == configurationRevision else {
      throw CoreRoutingError(code: "measurement_core_unavailable", message: "measurement configuration changed before preparation")
    }
    let snapshot = try await sendCoreMessage(
      Data(#"{"method":"getDelayTestConfiguration","arguments":null}"#.utf8),
      route: .networkExtension
    )
    try requireMethodSuccess(snapshot)
    guard let bytes = snapshot.data(using: .utf8),
      let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      methodResponseSucceeded(object),
      let arguments = object["result"] as? [String: Any],
      let digest = arguments["digest"] as? String,
      !digest.isEmpty,
      revision == configurationRevision,
      currentRoute == .networkExtension
    else {
      throw CoreRoutingError(code: "measurement_core_unavailable", message: "running measurement configuration is unavailable")
    }
    let call = try JSONSerialization.data(withJSONObject: ["method": "prepareDelayTest", "arguments": arguments])
    let response = try await sendCoreMessage(call, route: .app)
    try requireMethodSuccess(response)
    guard methodResponseHasEmptyStringResult(response),
      revision == configurationRevision,
      currentRoute == .networkExtension
    else {
      throw CoreRoutingError(code: "measurement_core_unavailable", message: "App measurement core could not prepare the running configuration")
    }
    preparedDelayRevision = revision
  }

  private func sendRoutedCoreMessage(
    _ data: Data,
    selectedRoute: CoreRoute
  ) async throws -> (response: String, route: CoreRoute) {
    do {
      let response = try await sendCoreMessage(data, route: selectedRoute)
      return (response, selectedRoute)
    } catch {
      guard selectedRoute == .networkExtension else {
        throw error
      }
      log(
        "route fallback networkExtension -> app: \(error.localizedDescription)"
      )
      let response = try await sendCoreMessage(data, route: .app)
      return (response, .app)
    }
  }

  private func sendNotificationStop(
    _ data: Data,
    kind: CoreNotificationKind,
    defaultRoute: CoreRoute
  ) async throws -> String {
    let routes = notificationCoordinator.beginStop(
      kind,
      data: data,
      defaultRoute: defaultRoute
    )
    var successfulResponse: String?
    var failedResponse: String?
    var firstError: Error?

    for route in routes {
      do {
        let response = try await sendCoreMessage(data, route: route)
        guard methodResponseSucceeded(response) else {
          if failedResponse == nil {
            failedResponse = response
          }
          continue
        }
        notificationCoordinator.recordSuccessfulStop(
          kind,
          route: route
        )
        if successfulResponse == nil {
          successfulResponse = response
        }
      } catch {
        if firstError == nil {
          firstError = error
        }
      }
    }

    if let failedResponse {
      return failedResponse
    }
    if let firstError {
      throw firstError
    }
    guard let successfulResponse else {
      throw CoreRoutingError(
        code: "notification_stop_failed",
        message: "failed to stop Core notifications"
      )
    }
    return successfulResponse
  }

  private func sendConfigurationMessage(
    _ data: Data,
    method: ConfigurationCoreMethod,
    networkExtensionActive: Bool
  ) async throws -> String {
    configurationRevision += 1
    preparedDelayRevision = nil
    await acquireConfigurationTransaction()
    defer { releaseConfigurationTransaction() }
    let appData: Data
    if networkExtensionActive && method == .updateConfig {
      appData = try replacingArgument(
        in: data,
        key: "external-controller",
        with: ""
      )
    } else {
      appData = data
    }

    let appResponse = try await sendCoreMessage(appData, route: .app)
    guard networkExtensionActive,
      currentRoute == .networkExtension,
      methodResponseHasEmptyStringResult(appResponse)
    else {
      return appResponse
    }

    let networkExtensionData = method == .updateConfig
      ? try replacingArgument(
        in: data,
        key: "geo-auto-update",
        with: false
      )
      : data
    return try await sendCoreMessage(
      networkExtensionData,
      route: .networkExtension
    )
  }

  private func sendCoreMessage(
    _ data: Data,
    route: CoreRoute
  ) async throws -> String {
    switch route {
    case .app:
      var appData = data
      if methodCallName(data) == AppCoreMethod.initClash.rawValue {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
          throw CoreRoutingError(code: "measurement_core_unavailable", message: "private App cache directory is unavailable")
        }
        appData = try replacingArgument(in: data, key: "cache-path", with: support.appendingPathComponent("delay-core/cache.db").path)
      }
      guard let methodCall = String(data: appData, encoding: .utf8) else {
        throw CoreRoutingError(
          code: "invalid_method_call",
          message: "invalid method call"
        )
      }
      let response: String? = await withCheckedContinuation {
        (continuation: CheckedContinuation<String?, Never>) in
        IOSCoreBridge.invokeMethod(methodCall) { value in
          continuation.resume(returning: value)
        }
      }
      guard let response else {
        throw CoreRoutingError(
          code: "empty_response",
          message: "empty app core response"
        )
      }
      return response
    case .networkExtension:
      return try await tunnelController.sendProviderMessage(data)
    }
  }

  private func route(
    method: String?,
    defaultRoute: CoreRoute
  ) -> CoreRoute {
    guard let method,
      AppCoreMethod(rawValue: method) != nil
    else {
      return defaultRoute
    }
    return .app
  }

  private func replacingArgument(
    in data: Data,
    key: String,
    with value: Any
  ) throws -> Data {
    guard var object = methodCallObject(data),
      var arguments = object["arguments"] as? [String: Any]
    else {
      throw CoreRoutingError(
        code: "invalid_arguments",
        message: "invalid configuration arguments"
      )
    }
    arguments[key] = value
    object["arguments"] = arguments
    do {
      return try JSONSerialization.data(withJSONObject: object)
    } catch {
      throw CoreRoutingError(
        code: "invalid_arguments",
        message: error.localizedDescription
      )
    }
  }

  private func requireMethodSuccess(_ response: String) throws {
    guard let data = response.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      throw CoreRoutingError(code: "measurement_core_unavailable", message: "invalid measurement method response", details: ["reason": "invalid_response"])
    }
    if let failure = object["error"] as? [String: Any] {
      throw CoreRoutingError(
        code: failure["code"] as? String ?? "measurement_core_unavailable",
        message: failure["message"] as? String ?? "measurement method failed",
        details: failure["details"]
      )
    }
  }

  private func methodResponseHasEmptyStringResult(
    _ response: String
  ) -> Bool {
    guard let data = response.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data)
        as? [String: Any],
      methodResponseSucceeded(object)
    else {
      return false
    }
    return object["result"] as? String == ""
  }

  private func methodResponseSucceeded(_ response: String) -> Bool {
    guard let data = response.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data)
        as? [String: Any]
    else {
      return false
    }
    return methodResponseSucceeded(object)
  }

  private func methodResponseSucceeded(
    _ object: [String: Any]
  ) -> Bool {
    object["error"] == nil || object["error"] is NSNull
  }

  private func methodCallObject(_ data: Data) -> [String: Any]? {
    try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func methodCallName(_ data: Data) -> String? {
    methodCallObject(data)?["method"] as? String
  }

  private func methodCallID(_ data: Data?) -> String? {
    guard let data,
      let object = methodCallObject(data)
    else {
      return nil
    }
    return object["id"] as? String
  }

  private func methodErrorResponse(
    data: Data?,
    code: String,
    message: String,
    details: Any? = nil
  ) -> String {
    var payload: [String: Any] = [
      "result": NSNull(),
      "error": [
        "code": code,
        "message": message,
        "details": details ?? NSNull(),
      ],
    ]
    if let id = methodCallID(data) {
      payload["id"] = id
    }

    guard let responseData = try? JSONSerialization.data(withJSONObject: payload),
      let response = String(data: responseData, encoding: .utf8)
    else {
      return #"{"result":null,"error":{"code":"serialization_error","message":"failed to serialize method response","details":null}}"#
    }
    return response
  }

  private func log(_ message: String) {
    logger.debug("\(message, privacy: .public)")
  }
}
