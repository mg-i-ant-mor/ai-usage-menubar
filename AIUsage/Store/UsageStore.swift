import Foundation
import Observation

struct MenuBarReading: Equatable, Sendable {
    let provider: ProviderID
    let metric: MenuBarMetricID
    let value: MenuBarReadingValue
    let displayMode: UsageDisplayMode
    let isStale: Bool
    /// The window runs out before its reset at its current pace.
    let isAtRisk: Bool
    let resetsAt: Date?
    /// When the window fills at its current pace, if before `resetsAt`.
    let exhaustsAt: Date?

    init(
        provider: ProviderID,
        metric: MenuBarMetricID,
        value: MenuBarReadingValue,
        displayMode: UsageDisplayMode,
        isStale: Bool,
        isAtRisk: Bool = false,
        resetsAt: Date? = nil,
        exhaustsAt: Date? = nil
    ) {
        self.provider = provider
        self.metric = metric
        self.value = value
        self.displayMode = displayMode
        self.isStale = isStale
        self.isAtRisk = isAtRisk
        self.resetsAt = resetsAt
        self.exhaustsAt = exhaustsAt
    }
}

struct MenuBarProviderReadings: Equatable, Identifiable, Sendable {
    let provider: ProviderID
    var accountID: String
    /// Set only when the provider has more than one account.
    var accountName: String?
    let selectedMetrics: [MenuBarMetricID]
    let readings: [MenuBarReading]

    init(
        provider: ProviderID,
        accountID: String? = nil,
        accountName: String? = nil,
        selectedMetrics: [MenuBarMetricID],
        readings: [MenuBarReading]
    ) {
        self.provider = provider
        self.accountID = accountID ?? provider.rawValue
        self.accountName = accountName
        self.selectedMetrics = selectedMetrics
        self.readings = readings
    }

    var id: String { accountID }
    var title: String {
        accountName.map { "\(provider.displayName) · \($0)" } ?? provider.displayName
    }
    var showsMetricLabels: Bool { readings.count > 1 }
}

@MainActor
@Observable
final class UsageStore {
    private(set) var states: [ProviderID: ProviderState]
    private(set) var installedProviderIDs: Set<ProviderID>?
    private(set) var trackedProviderIDs: Set<ProviderID>
    private(set) var lastAttemptAt: Date?
    private(set) var lastSuccessfulRefreshAt: Date?
    private(set) var refreshInterval: RefreshIntervalOption
    private(set) var workSchedule: WorkSchedule?

    private let providers: [any UsageProvider]
    private let availabilityChecker: any ProviderAvailabilityChecking
    private var cadenceTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0

    init(
        providers: [any UsageProvider] = [
            ClaudeProvider(accountDirectories: {
                ClaudeAuthStore.additionalConfigDirectories()
            }),
            CodexProvider(),
            CursorProvider(),
            AntigravityProvider(),
            CopilotProvider(),
            DevinProvider(),
            GrokProvider(),
            KiroProvider(),
            ZAIProvider()
        ],
        availabilityChecker: any ProviderAvailabilityChecking =
            SystemProviderAvailabilityChecker(),
        refreshInterval: RefreshIntervalOption = .fiveMinutes,
        trackedProviderIDs: Set<ProviderID> = Set(ProviderID.allCases),
        workSchedule: WorkSchedule? = nil
    ) {
        self.providers = providers
        self.availabilityChecker = availabilityChecker
        self.refreshInterval = refreshInterval
        self.trackedProviderIDs = trackedProviderIDs
        self.workSchedule = workSchedule
        states = Dictionary(uniqueKeysWithValues: ProviderID.allCases.map {
            ($0, ProviderState(provider: $0))
        })
    }

    func start() {
        guard cadenceTask == nil else { return }
        LoginShellEnvironment.shared.prewarm()
        cadenceTask = makeCadenceTask(refreshImmediately: true)
    }

    func stop() {
        cadenceTask?.cancel()
        cadenceTask = nil
        cancelRefresh()
    }

    func setTrackedProviders(_ providers: Set<ProviderID>) {
        guard trackedProviderIDs != providers else { return }

        let newlyEnabled = providers.subtracting(trackedProviderIDs)
        trackedProviderIDs = providers
        for provider in ProviderID.allCases where !providers.contains(provider) {
            states[provider]?.isRefreshing = false
        }

        guard cadenceTask != nil else { return }
        cadenceTask?.cancel()
        cadenceTask = nil
        cancelRefresh()
        cadenceTask = makeCadenceTask(
            refreshImmediately: !newlyEnabled.isEmpty,
            initialProviderIDs: newlyEnabled.isEmpty ? nil : newlyEnabled
        )
    }

    func setRefreshInterval(_ interval: RefreshIntervalOption) {
        guard refreshInterval != interval else { return }
        refreshInterval = interval

        guard cadenceTask != nil else { return }
        cadenceTask?.cancel()
        cadenceTask = makeCadenceTask(refreshImmediately: false)
    }

    func setWorkSchedule(_ schedule: WorkSchedule?) {
        guard workSchedule != schedule else { return }
        workSchedule = schedule
        for provider in ProviderID.allCases {
            guard let snapshot = states[provider]?.snapshot else { continue }
            states[provider]?.snapshot = snapshot.paced(previous: snapshot, schedule: schedule)
        }
    }

    func refreshNow() {
        cadenceTask?.cancel()
        cadenceTask = nil
        cancelRefresh()
        cadenceTask = makeCadenceTask(refreshImmediately: true)
    }

    func refresh(providerIDs requestedProviderIDs: Set<ProviderID>? = nil) async {
        if let refreshTask {
            await refreshTask.value
            return
        }

        refreshGeneration += 1
        let generation = refreshGeneration
        let providers = self.providers
        let trackedProviderIDs = self.trackedProviderIDs
        let availabilityChecker = self.availabilityChecker
        let task = Task { [weak self] in
            let installedProviders =
                await availabilityChecker.installedProviders()
            guard !Task.isCancelled else { return }

            self?.applyInstalledProviders(installedProviders)

            let requested = requestedProviderIDs ?? trackedProviderIDs
            let effectiveProviders = providers.filter { provider in
                trackedProviderIDs.contains(provider.id) &&
                    requested.contains(provider.id) &&
                    (installedProviders?.contains(provider.id) ?? true)
            }

            for provider in effectiveProviders {
                self?.states[provider.id]?.isRefreshing = true
            }

            let fetchResults = await withTaskGroup(
                of: FetchResult.self
            ) { group in
                for provider in effectiveProviders {
                    group.addTask {
                        do {
                            return FetchResult(
                                provider: provider.id,
                                result: .success(try await provider.fetch())
                            )
                        } catch let failure as ProviderFailure {
                            return FetchResult(
                                provider: provider.id,
                                result: .failure(failure)
                            )
                        } catch {
                            return FetchResult(
                                provider: provider.id,
                                result: .failure(ProviderFailure(
                                    .transient,
                                    "\(provider.id.displayName) could not be refreshed."
                                ))
                            )
                        }
                    }
                }

                var results: [FetchResult] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }

            guard !Task.isCancelled else { return }
            self?.applyFetchResults(fetchResults)
        }
        refreshTask = task
        await task.value
        if generation == refreshGeneration {
            refreshTask = nil
        }
    }

    func isProviderVisibleInDashboard(_ provider: ProviderID) -> Bool {
        trackedProviderIDs.contains(provider) &&
            states[provider]?.isToolInstalled != false
    }

    func availableMenuBarItems(
        for provider: ProviderID
    ) -> [MenuBarItemID] {
        guard trackedProviderIDs.contains(provider),
              states[provider]?.isToolInstalled != false else {
            return []
        }
        return states[provider]?.snapshot?.availableMenuBarItems ?? []
    }

    var availableMenuBarItemsByProvider:
        [ProviderID: [MenuBarItemID]] {
        Dictionary(uniqueKeysWithValues: ProviderID.allCases.map {
            ($0, availableMenuBarItems(for: $0))
        })
    }

    func isMenuBarItemAvailable(_ item: MenuBarItemID) -> Bool {
        availableMenuBarItems(for: item.provider).contains(item)
    }

    func menuBarReadings(
        for items: [MenuBarItemID],
        displayMode: UsageDisplayMode = .used
    ) -> [MenuBarReading] {
        items.compactMap { item in
            guard let state = states[item.provider] else { return nil }
            return readings(
                for: [item],
                in: state,
                displayMode: displayMode
            ).first
        }
    }

    private func readings(
        for items: [MenuBarItemID],
        in state: ProviderState,
        displayMode: UsageDisplayMode
    ) -> [MenuBarReading] {
        let now = Date()
        return items.compactMap { item in
            guard trackedProviderIDs.contains(item.provider),
                  state.isToolInstalled != false,
                  let value = state.snapshot?.menuBarValue(
                    for: item.metric,
                    displayMode: displayMode
                  ) else {
                return nil
            }

            let exhaustion = state.snapshot?.exhaustion(
                for: item.metric,
                now: now,
                schedule: workSchedule
            )
            return MenuBarReading(
                provider: item.provider,
                metric: item.metric,
                value: value,
                displayMode: displayMode,
                isStale: state.isStale,
                isAtRisk: state.snapshot?.isAtRisk(item.metric, now: now) == true,
                resetsAt: state.snapshot?.window(for: item.metric)?.resetsAt,
                exhaustsAt: exhaustion
            )
        }
    }

    func menuBarProviderReadings(
        for configurations: [MenuBarProviderConfiguration],
        displayMode: UsageDisplayMode = .used
    ) -> [MenuBarProviderReadings] {
        configurations.flatMap { configuration -> [MenuBarProviderReadings] in
            guard trackedProviderIDs.contains(configuration.provider),
                  let state = states[configuration.provider],
                  state.isToolInstalled != false else {
                return []
            }

            let accounts = state.accounts
            let chosen = accounts.filter { configuration.accountIDs.contains($0.id) }
            let items = configuration.metrics.map {
                MenuBarItemID(
                    provider: configuration.provider,
                    metric: $0
                )
            }
            return (chosen.isEmpty ? [accounts[0]] : chosen).map { account in
                var readings = self.readings(
                    for: items,
                    in: account.state,
                    displayMode: displayMode
                )
                // Selected metrics can vanish from the live snapshot (for
                // example, Claude accounts without a five-hour window return
                // `five_hour: null`). Show the provider's default metric rather
                // than nothing, without touching the saved selection.
                if readings.isEmpty,
                   let fallback = AppPreferences.defaultMenuBarItem(
                       for: configuration.provider,
                       in: account.state.snapshot?.availableMenuBarItems ?? []
                   ) {
                    readings = self.readings(
                        for: [fallback],
                        in: account.state,
                        displayMode: displayMode
                    )
                }
                return MenuBarProviderReadings(
                    provider: configuration.provider,
                    accountID: account.id,
                    accountName: accounts.count > 1 ? account.name : nil,
                    selectedMetrics: configuration.metrics,
                    readings: readings
                )
            }
        }
    }

    func menuBarReading(
        for item: MenuBarItemID,
        displayMode: UsageDisplayMode = .used
    ) -> MenuBarReading? {
        menuBarReadings(
            for: [item],
            displayMode: displayMode
        ).first
    }

    private func applyInstalledProviders(_ installedProviders: Set<ProviderID>?) {
        installedProviderIDs = installedProviders
        guard let installedProviders else { return }

        for provider in ProviderID.allCases {
            states[provider]?.isToolInstalled =
                installedProviders.contains(provider)
            if !installedProviders.contains(provider) {
                states[provider]?.isRefreshing = false
            }
        }
    }

    private func applyFetchResults(_ fetchResults: [FetchResult]) {
        lastAttemptAt = Date()
        var successfulDates: [Date] = []

        for fetchResult in fetchResults {
            guard trackedProviderIDs.contains(fetchResult.provider) else {
                continue
            }

            var state =
                states[fetchResult.provider] ??
                ProviderState(provider: fetchResult.provider)
            state.isRefreshing = false
            switch fetchResult.result {
            case .success(let snapshot):
                state.snapshot = snapshot.paced(previous: state.snapshot, schedule: workSchedule)
                state.failure = nil
                successfulDates.append(snapshot.fetchedAt)
            case .failure(let failure):
                if !failure.preservesLastGood {
                    state.snapshot = nil
                }
                state.failure = failure
            }
            states[fetchResult.provider] = state
        }

        if let latest = successfulDates.max() {
            lastSuccessfulRefreshAt = latest
        }
    }

    private func cancelRefresh() {
        refreshGeneration += 1
        refreshTask?.cancel()
        refreshTask = nil
    }

    private func makeCadenceTask(
        refreshImmediately: Bool,
        initialProviderIDs: Set<ProviderID>? = nil
    ) -> Task<Void, Never> {
        let duration = refreshInterval.duration
        return Task { [weak self, duration] in
            if refreshImmediately {
                await self?.refresh(providerIDs: initialProviderIDs)
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: duration)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }
}

private struct FetchResult: Sendable {
    let provider: ProviderID
    let result: Result<ProviderSnapshot, ProviderFailure>
}
