import Foundation
import NetworkExtension
import os

@MainActor
final class TunnelCoordinator {
  private let managerStore: TunnelManagerStore
  private let onTunnelStateChanged: (TunnelTarget) -> Void
  private let onConnectionStateChanged: (String) -> Void
  private let onExternalStart: () -> Void
  private let onExternalStop: () -> Void
  private let logger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "com.follow.clash",
    category: "TunnelCoordinator"
  )

  private var observedTunnelStatus: NEVPNStatus?
  private var reportedTunnelState: TunnelTarget?
  private var publishedTunnelState: TunnelTarget?

  private var requestGeneration: UInt64 = 0
  private var tunnelRequest: TunnelRequest?
  private var tunnelWait: TunnelWait?
  private var isCoordinatorRunning = false
  // A start that supersedes a stop before it stopped anything must still
  // cycle the tunnel, or a restart meant to apply new options is lost.
  private var restartOwed = false

  private var configurationContinuations: [CheckedContinuation<Void, Error>] = []
  private var needsStatusRefresh = false
  private var statusRefreshShouldNotify = false

  init(
    managerStore: TunnelManagerStore,
    onTunnelStateChanged: @escaping (TunnelTarget) -> Void,
    onConnectionStateChanged: @escaping (String) -> Void,
    onExternalStart: @escaping () -> Void,
    onExternalStop: @escaping () -> Void
  ) {
    self.managerStore = managerStore
    self.onTunnelStateChanged = onTunnelStateChanged
    self.onConnectionStateChanged = onConnectionStateChanged
    self.onExternalStart = onExternalStart
    self.onExternalStop = onExternalStop
  }

  func submitTunnelRequest(
    target: TunnelTarget
  ) {
    if let request = tunnelRequest,
      request.target == target
    {
      log("merge \(target.description) request")
      return
    }

    if target == .stopped {
      restartOwed = true
    }
    requestGeneration &+= 1
    let request = TunnelRequest(
      generation: requestGeneration,
      target: target
    )
    tunnelRequest = request
    publishConnectionState()
    publishedTunnelState = target
    cancelTunnelWait()
    log(
      "request target=\(target.description) generation=\(request.generation)"
    )

    driveCoordinator()
  }

  func toggleTunnelRequest() {
    let currentTarget = tunnelRequest?.target ??
      observedTunnelStatus?.tunnelState ??
      publishedTunnelState ??
      .stopped
    submitTunnelRequest(
      target: currentTarget == .running ? .stopped : .running
    )
  }

  func reloadOnDemandRules() async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      configurationContinuations.append(continuation)
      driveCoordinator()
    }
  }

  func requestStatusRefresh(notifyExternal: Bool) {
    needsStatusRefresh = true
    statusRefreshShouldNotify =
      statusRefreshShouldNotify || notifyExternal
    driveCoordinator()
  }

  func publishConnectionState() {
    let state: String
    if tunnelRequest != nil {
      state = "pending"
    } else {
      switch observedTunnelStatus {
      case .connected:
        state = "connected"
      case .disconnected, .invalid:
        state = "disconnected"
      default:
        state = "pending"
      }
    }
    onConnectionStateChanged(state)
  }

  func handleTunnelStatusNotification(_ notification: Notification) {
    guard let connection = notification.object as? NEVPNConnection,
      managerStore.isManagedConnection(connection)
    else {
      return
    }

    if let wait = tunnelWait,
      wait.manager.connection === connection
    {
      recordObservedTunnelStatus(
        connection.status,
        notifyExternal: false
      )
      return
    }
    guard tunnelWait == nil,
      managerStore.isCachedConnection(connection)
    else {
      return
    }
    recordObservedTunnelStatus(
      connection.status,
      notifyExternal: true
    )
  }

  private func driveCoordinator() {
    guard !isCoordinatorRunning else {
      return
    }
    isCoordinatorRunning = true
    Task { [weak self] in
      await self?.runCoordinator()
    }
  }

  private func runCoordinator() async {
    while true {
      if let request = tunnelRequest {
        await reconcileTunnel(request)
        continue
      }

      if !configurationContinuations.isEmpty {
        let continuations = configurationContinuations
        configurationContinuations.removeAll()
        let error = await performOnDemandRulesReload()
        for continuation in continuations {
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume()
          }
        }
        continue
      }

      if needsStatusRefresh {
        let notifyExternal = statusRefreshShouldNotify
        needsStatusRefresh = false
        statusRefreshShouldNotify = false
        await performStatusRefresh(notifyExternal: notifyExternal)
        continue
      }

      isCoordinatorRunning = false
      return
    }
  }

  private func reconcileTunnel(_ request: TunnelRequest) async {
    while isCurrent(request) {
      do {
        switch request.target {
        case .running:
          try await reconcileRunningTunnel(request)
        case .stopped:
          try await reconcileStoppedTunnel(request)
        }
        return
      } catch {
        guard isCurrent(request) else {
          return
        }
        let status = observedTunnelStatus
        if request.preferenceRetryCount == 0,
          managerStore.invalidateCachedManager(forPreferenceError: error)
        {
          request.preferenceRetryCount += 1
          log(
            "\(request.target.description) retry preferences: \(error.localizedDescription)"
          )
          continue
        }
        log(
          "\(request.target.description) failed: \(error.localizedDescription)"
        )
        do {
          let nsError = error as NSError
          StartupLog.mark(
            "tunnel: \(request.target.description) FAILED domain=\(nsError.domain) code=\(nsError.code) \(nsError.localizedDescription) userInfo=\(nsError.userInfo.keys.joined(separator: ","))"
          )
        }
        finishTunnelRequest(
          request,
          actualState: stableFailureState(status)
        )
        return
      }
    }
  }

  private func reconcileRunningTunnel(
    _ request: TunnelRequest
  ) async throws {
    while isCurrent(request) {
      let loadedManager = try await managerStore.loadManager()
      guard isCurrent(request) else {
        return
      }
      guard var manager = loadedManager else {
        recordObservedTunnelStatus(.invalid, notifyExternal: false)
        finishTunnelRequest(request, actualState: .stopped)
        return
      }

      let status = manager.connection.status
      recordObservedTunnelStatus(status, notifyExternal: false)
      if status.tunnelState == .running {
        if restartOwed {
          guard await stopBeforeRestart(manager: manager, request: request)
          else {
            return
          }
          continue
        }
        finishTunnelRequest(request, actualState: .running)
        return
      }
      if status.tunnelState == nil {
        guard await settleBeforeStart(manager: manager, request: request) else {
          return
        }
        continue
      }

      if managerStore.hasStoredManager && manager.isEnabled {
        // Already provisioned and enabled: start it directly. Saving first is
        // what made connecting wait on the daemon; a connect should be instant.
        StartupLog.mark(
          "tunnel: configuration already provisioned, starting without saving status=\(manager.connection.status.rawValue)"
        )
      } else if managerStore.hasStoredManager {
        StartupLog.mark(
          "tunnel: stored configuration is disabled (isEnabled=false) — open Settings > General > VPN & Device Management > VPN and switch FlClash on once"
        )
        manager = try await prepareTunnelPreferences(manager: manager, request: request)
        guard isCurrent(request) else {
          return
        }
        if !manager.isEnabled {
          StartupLog.mark(
            "tunnel: the system still reports the configuration as disabled; refusing to start rather than hanging"
          )
          throw NSError(
            domain: "FlClash",
            code: -1003,
            userInfo: [
              NSLocalizedDescriptionKey:
                "VPN configuration is disabled: enable FlClash once in Settings > VPN"
            ]
          )
        }
      } else {
        manager = try await prepareTunnelPreferences(manager: manager, request: request)
        guard isCurrent(request) else {
          return
        }
      }

      let preparedStatus = manager.connection.status
      recordObservedTunnelStatus(preparedStatus, notifyExternal: false)
      if preparedStatus.tunnelState == .running {
        finishTunnelRequest(request, actualState: .running)
        return
      }
      if preparedStatus.tunnelState == nil {
        guard await settleBeforeStart(manager: manager, request: request) else {
          return
        }
        continue
      }

      do {
        StartupLog.mark("tunnel: calling startVPNTunnel status=\(manager.connection.status.rawValue)")
        try manager.connection.startVPNTunnel()
        log("start requested")
        StartupLog.mark("tunnel: startVPNTunnel returned status=\(manager.connection.status.rawValue)")
      } catch {
        if finishRunningRequestIfSatisfied(request, manager: manager) {
          return
        }
        throw error
      }

      let result = await waitForTunnelStatus(
        manager: manager,
        request: request,
        purpose: .starting
      )
      guard isCurrent(request) else {
        return
      }
      switch result {
      case .status(let status):
        if status.tunnelState != .running {
          // The tunnel fell straight back: whatever the extension managed to
          // write belongs in this log, not in the next session.
          StartupLog.importExtensionTrace()
        }
        finishTunnelRequest(
          request,
          actualState: status.tunnelState
        )
      case .superseded:
        return
      }
      return
    }
  }


  // Preference calls must never overlap: the daemon serialises them, so a second
  // save/load issued while the first is still waiting (the add-VPN prompt keeps
  // it waiting until the user answers) leaves both hanging forever. Every Dart
  // retry submits a new request, so the older flow has to queue here.
  private var preferenceLockBusy = false
  private var preferenceLockWaiters: [CheckedContinuation<Void, Never>] = []

  private func acquirePreferenceLock() async {
    if !preferenceLockBusy {
      preferenceLockBusy = true
      return
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      preferenceLockWaiters.append(continuation)
    }
  }

  private func releasePreferenceLock() {
    if preferenceLockWaiters.isEmpty {
      preferenceLockBusy = false
      return
    }
    let next = preferenceLockWaiters.removeFirst()
    next.resume()
  }

  /// Saves and reloads the tunnel configuration, then hands back the manager to
  /// start from. A save that never calls back is not fatal: the configuration is
  /// often stored anyway, so the list is re-read and whatever is there is used.
  private func prepareTunnelPreferences(
    manager: NETunnelProviderManager,
    request: TunnelRequest
  ) async throws -> NETunnelProviderManager {
    await acquirePreferenceLock()
    defer { releasePreferenceLock() }

    manager.isEnabled = true
    managerStore.applyNetworkExtensionOptions(to: manager, enableOnDemand: true)
    StartupLog.mark(
      "tunnel: save preferences provider=\(manager.protocolConfiguration?.value(forKey: "providerBundleIdentifier") as? String ?? "nil") enabled=\(manager.isEnabled) status=\(manager.connection.status.rawValue)"
    )
    do {
      try await awaitPreferenceResult { completion in
        manager.saveToPreferences(completionHandler: completion)
      }
    } catch {
      StartupLog.mark("tunnel: save did not answer (\(error.localizedDescription)); checking what got stored")
      if let stored = await storedManager() {
        StartupLog.mark("tunnel: stored configuration enabled=\(stored.isEnabled) status=\(stored.connection.status.rawValue)")
        return stored
      }
      throw error
    }
    guard isCurrent(request) else {
      return manager
    }
    if !manager.isEnabled {
      manager.isEnabled = true
      try await awaitPreferenceResult { completion in
        manager.saveToPreferences(completionHandler: completion)
      }
    }
    try await awaitPreferenceResult { completion in
      manager.loadFromPreferences(completionHandler: completion)
    }
    StartupLog.mark(
      "tunnel: preferences ready enabled=\(manager.isEnabled) status=\(manager.connection.status.rawValue)"
    )
    return manager
  }

  /// Reads the stored configurations once, without keeping them cached.
  private func storedManager() async -> NETunnelProviderManager? {
    await withCheckedContinuation {
      (continuation: CheckedContinuation<NETunnelProviderManager?, Never>) in
      NETunnelProviderManager.loadAllFromPreferences { managers, error in
        DispatchQueue.main.async {
          if let error {
            StartupLog.mark("tunnel: loadAll after failure error=\(error.localizedDescription)")
          }
          continuation.resume(returning: managers?.first)
        }
      }
    }
  }

  private func settleBeforeStart(
    manager: NETunnelProviderManager,
    request: TunnelRequest
  ) async -> Bool {
    let result = await waitForTunnelStatus(
      manager: manager,
      request: request,
      purpose: .settleThenStart
    )
    guard isCurrent(request) else {
      return false
    }
    switch result {
    case .status(let status):
      if status.tunnelState == .running && !restartOwed {
        finishTunnelRequest(request, actualState: .running)
        return false
      }
      return true
    case .superseded:
      return false
    }
  }

  private func stopBeforeRestart(
    manager: NETunnelProviderManager,
    request: TunnelRequest
  ) async -> Bool {
    restartOwed = false
    manager.connection.stopVPNTunnel()
    log("restart stop requested")
    let result = await waitForTunnelStatus(
      manager: manager,
      request: request,
      purpose: .stopping
    )
    guard isCurrent(request), case .status = result else {
      return false
    }
    return true
  }

  private func reconcileStoppedTunnel(
    _ request: TunnelRequest
  ) async throws {
    guard
      let manager = try await managerStore.loadManager(
        createIfNeeded: false
      )
    else {
      recordObservedTunnelStatus(.invalid, notifyExternal: false)
      finishTunnelRequest(request, actualState: .stopped)
      return
    }
    guard isCurrent(request) else {
      return
    }

    let status = manager.connection.status
    recordObservedTunnelStatus(status, notifyExternal: false)
    if status.tunnelState == .stopped {
      finishTunnelRequest(request, actualState: .stopped)
      return
    }

    if status != .disconnecting {
      manager.connection.stopVPNTunnel()
      log("stop requested from Network Extension")
    }
    let result = await waitForTunnelStatus(
      manager: manager,
      request: request,
      purpose: .stopping
    )
    guard isCurrent(request) else {
      return
    }
    switch result {
    case .status(let status):
      finishTunnelRequest(
        request,
        actualState: status.tunnelState
      )
    case .superseded:
      return
    }
  }

  private func waitForTunnelStatus(
    manager: NETunnelProviderManager,
    request: TunnelRequest,
    purpose: TunnelWaitPurpose
  ) async -> TunnelWaitResult {
    await withCheckedContinuation { continuation in
      let wait = TunnelWait(
        request: request,
        purpose: purpose,
        manager: manager,
        continuation: continuation
      )
      tunnelWait = wait
      consumeWaitStatus(manager.connection.status)
    }
  }

  private func consumeWaitStatus(_ status: NEVPNStatus) {
    guard let wait = tunnelWait,
      isCurrent(wait.request)
    else {
      return
    }
    switch wait.purpose {
    case .starting:
      if status.tunnelState == .running {
        resolveTunnelWait(wait, result: .status(status))
        return
      }
      if status.isLifecycleActive {
        wait.hasObservedProgress = true
      }
      if status.isTerminal && wait.hasObservedProgress {
        resolveTunnelWait(wait, result: .status(status))
      }
    case .stopping:
      if status.isTerminal {
        resolveTunnelWait(wait, result: .status(status))
      }
    case .settleThenStart:
      if status.tunnelState != nil {
        resolveTunnelWait(wait, result: .status(status))
      }
    }
  }

  private func resolveTunnelWait(
    _ wait: TunnelWait,
    result: TunnelWaitResult
  ) {
    guard tunnelWait === wait else {
      return
    }
    tunnelWait = nil
    wait.continuation.resume(returning: result)
  }

  private func cancelTunnelWait() {
    guard let wait = tunnelWait else {
      return
    }
    resolveTunnelWait(wait, result: .superseded)
  }

  private func finishRunningRequestIfSatisfied(
    _ request: TunnelRequest,
    manager: NETunnelProviderManager
  ) -> Bool {
    let status = manager.connection.status
    recordObservedTunnelStatus(status, notifyExternal: false)
    guard status.tunnelState == .running else {
      return false
    }
    finishTunnelRequest(request, actualState: .running)
    return true
  }

  private func finishTunnelRequest(
    _ request: TunnelRequest,
    actualState: TunnelTarget?
  ) {
    guard isCurrent(request) else {
      return
    }
    tunnelRequest = nil
    restartOwed = false
    defer { publishConnectionState() }
    guard let actualState else {
      log(
        "\(request.target.description) completed actual=unknown generation=\(request.generation)"
      )
      return
    }
    reportTunnelState(actualState)
    publishedTunnelState = actualState
    log(
      "\(request.target.description) completed actual=\(actualState.description) generation=\(request.generation)"
    )

    if request.target == .running,
      actualState == .stopped
    {
      StartupLog.mark("tunnel: running request ended stopped; scheduling automatic reconnect")
      Task { @MainActor [weak self] in
        guard let self else { return }
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard self.tunnelRequest == nil,
          self.publishedTunnelState == .stopped,
          self.requestGeneration == request.generation
        else { return }
        self.submitTunnelRequest(target: .running)
      }
    }

    Task { @MainActor [weak self] in
      guard let self,
        self.requestGeneration == request.generation,
        self.tunnelRequest == nil,
        self.publishedTunnelState == actualState
      else {
        return
      }
      self.notifyExternalState(actualState)
    }
  }

  private func isCurrent(_ request: TunnelRequest) -> Bool {
    tunnelRequest === request && requestGeneration == request.generation
  }

  private func performOnDemandRulesReload() async -> Error? {
    var allowPreferenceRetry = true
    while true {
      do {
        guard
          let manager = try await managerStore.loadManager(
            createIfNeeded: false
          )
        else {
          return nil
        }
        let status = manager.connection.status
        managerStore.applyNetworkExtensionOptions(
          to: manager,
          enableOnDemand: status == .connecting || status.tunnelState == .running
        )
        await acquirePreferenceLock()
        do {
          try await awaitPreferenceResult { completion in
            manager.saveToPreferences(completionHandler: completion)
          }
        } catch {
          releasePreferenceLock()
          throw error
        }
        releasePreferenceLock()
        return nil
      } catch {
        log(
          "reloadOnDemandRules save failed: \(error.localizedDescription)"
        )
        guard allowPreferenceRetry,
          managerStore.invalidateCachedManager(forPreferenceError: error)
        else {
          return error
        }
        allowPreferenceRetry = false
        log("reloadOnDemandRules retry preferences")
      }
    }
  }

  private func performStatusRefresh(notifyExternal: Bool) async {
    let generation = requestGeneration
    do {
      let manager = try await managerStore.reloadManager(createIfNeeded: false)
      let status = manager?.connection.status ?? .invalid
      recordObservedTunnelStatus(
        status,
        notifyExternal: false
      )
      if notifyExternal,
        generation == requestGeneration,
        tunnelRequest == nil,
        let state = status.tunnelState
      {
        publishedTunnelState = state
        notifyExternalState(state)
      }
    } catch {
      log("refresh status failed: \(error.localizedDescription)")
    }
  }

  private func recordObservedTunnelStatus(
    _ status: NEVPNStatus,
    notifyExternal: Bool
  ) {
    let previousStatus = observedTunnelStatus
    observedTunnelStatus = status
    defer { publishConnectionState() }
    if previousStatus != status {
      log(
        "status changed \(statusDescription(previousStatus ?? .invalid)) -> \(statusDescription(status)) target=\(tunnelRequest?.target.description ?? "none")"
      )
      StartupLog.mark(
        "tunnel: status \(statusDescription(previousStatus ?? .invalid)) -> \(statusDescription(status))"
      )
    }

    if tunnelWait != nil {
      consumeWaitStatus(status)
      return
    }
    guard tunnelRequest == nil,
      let stableState = status.tunnelState
    else {
      return
    }
    reportTunnelState(stableState)
    // A provider failure (reason 11) is not a user stop. Keep the user's
    // desired running state and submit a fresh start after NetworkExtension
    // returns to disconnected; otherwise background/network transitions leave
    // the VPN off until the user opens the app again.
    if stableState == .stopped,
      publishedTunnelState == .running,
      requestGeneration > 0
    {
      StartupLog.mark("tunnel: unexpected disconnect while running; scheduling automatic reconnect")
      submitTunnelRequest(target: .running)
      return
    }
    if notifyExternal {
      publishExternalState(stableState)
    } else if publishedTunnelState == nil {
      publishedTunnelState = stableState
    }
  }

  private func reportTunnelState(_ state: TunnelTarget) {
    guard reportedTunnelState != state else {
      return
    }
    reportedTunnelState = state
    onTunnelStateChanged(state)
  }

  private func publishExternalState(_ state: TunnelTarget) {
    guard publishedTunnelState != state else {
      return
    }
    publishedTunnelState = state
    notifyExternalState(state)
  }

  private func notifyExternalState(_ state: TunnelTarget) {
    switch state {
    case .running:
      log("sync running tunnel state")
      onExternalStart()
    case .stopped:
      log("sync stopped tunnel state")
      onExternalStop()
    }
  }

  /// A continuation that may be resumed twice (callback + timeout) without
  /// trapping the process.
  private final class OneShotResume: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private let continuation: CheckedContinuation<Void, Error>

    init(_ continuation: CheckedContinuation<Void, Error>) {
      self.continuation = continuation
    }

    func finish(_ error: Error?, onWin: () -> Void = {}) {
      lock.lock()
      if finished {
        lock.unlock()
        return
      }
      finished = true
      lock.unlock()
      onWin()
      if let error {
        continuation.resume(throwing: error)
      } else {
        continuation.resume()
      }
    }
  }

  private func awaitPreferenceResult(
    _ action: (@escaping @Sendable (Error?) -> Void) -> Void
  ) async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, Error>) in
      let once = OneShotResume(continuation)
      action { error in
        once.finish(error)
      }
      // Without this, a savePreferences that never calls back (which is what the
      // device log shows: the call is made and nothing follows) leaves the
      // request hanging with no diagnostic at all.
      Task {
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        once.finish(
          NSError(
            domain: "FlClash",
            code: -1001,
            userInfo: [NSLocalizedDescriptionKey: "preferences call timed out after 60s"]
          ),
          onWin: {
            StartupLog.mark("tunnel: preferences operation did not complete within 60s")
          }
        )
      }
    }
  }

  private func stableFailureState(
    _ status: NEVPNStatus?
  ) -> TunnelTarget? {
    status?.tunnelState
  }

  private func statusDescription(_ status: NEVPNStatus) -> String {
    switch status {
    case .invalid:
      return "invalid"
    case .disconnected:
      return "disconnected"
    case .connecting:
      return "connecting"
    case .connected:
      return "connected"
    case .reasserting:
      return "reasserting"
    case .disconnecting:
      return "disconnecting"
    @unknown default:
      return "unknown"
    }
  }

  private func log(_ message: String) {
    logger.debug("\(message, privacy: .public)")
  }
}
