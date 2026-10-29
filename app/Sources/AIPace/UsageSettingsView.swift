import SwiftUI

struct UsageSettingsView: View {
    @ObservedObject var store: UsageStore
    let loc: Loc
    @AppStorage(UsageResetTime.showInMenuBarDefaultsKey) private var showMenuBarResetTime = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(loc.sameUsageAsMenuBar, isOn: Binding(
                get: { store.usageDisplayPreferences.popoverMatchesMenuBar },
                set: { store.setPopoverMatchesMenuBar($0) }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .font(.system(size: 12, weight: .medium))

            Text(loc.usageSelectionDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(loc.showMenuBarResetTime, isOn: $showMenuBarResetTime)
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .font(.system(size: 12, weight: .medium))

            Text(loc.menuBarResetTimeDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Text(loc.usageMenuBar).frame(width: 82)
                Text(loc.usageMenu).frame(width: 82)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)

            ForEach([ProviderKind.claude, .codex], id: \.rawValue) { provider in
                Divider()
                Text(provider.rawValue)
                    .font(.system(size: 12, weight: .semibold))

                ForEach(store.usageMetrics(for: provider)) { metric in
                    HStack {
                        Text(metric.label(loc: loc))
                            .font(.system(size: 12))
                        Spacer()
                        visibilityToggle(metric, destination: .menuBar)
                        visibilityToggle(metric, destination: .popover)
                            .disabled(store.usageDisplayPreferences.popoverMatchesMenuBar)
                    }
                }
            }

            Text(loc.additionalUsageDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func visibilityToggle(_ metric: UsageMetric, destination: UsageDisplayDestination) -> some View {
        Toggle(
            "\(metric.provider.rawValue) · \(metric.label(loc: loc)) · \(destination == .menuBar ? loc.usageMenuBar : loc.usageMenu)",
            isOn: Binding(
                get: { store.usageDisplayPreferences.isVisible(metric, in: destination) },
                set: { store.setUsageVisible($0, metric: metric, in: destination) }
            )
        )
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.mini)
        .frame(width: 82)
    }
}
