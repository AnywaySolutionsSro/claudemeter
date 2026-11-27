import Combine
import Foundation

/// The widgets can't read our defaults, so the time format rides in their data files.
/// Stamps the current style into every snapshot, and when the setting changes republishes
/// both files right away (which also reloads the widget timelines) instead of waiting for
/// the next scan or fetch.
@MainActor
func bindClockStyle(settings: Settings, monitor: SessionMonitor, apiSpend: ApiSpendStore) -> AnyCancellable {
    monitor.clockStyleProvider = { [weak settings] in settings?.clockStyle ?? .system }
    apiSpend.clockStyleProvider = { [weak settings] in settings?.clockStyle ?? .system }
    return settings.$clockStyle.dropFirst().receive(on: RunLoop.main)
        .sink { [weak monitor, weak apiSpend] _ in
            Task { await monitor?.refresh() }
            apiSpend?.redeliverToWidget()
        }
}
