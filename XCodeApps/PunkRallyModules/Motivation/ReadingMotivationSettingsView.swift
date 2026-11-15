#if os(iOS)
import SwiftUI
import SilveranKit

struct ReadingMotivationSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var store = ReadingMotivationStore.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    goalStepper(
                        title: "Daily reading",
                        value: store.settings.dailyReadingGoalMinutes,
                        reading: true
                    )
                    goalStepper(
                        title: "Daily listening",
                        value: store.settings.dailyListeningGoalMinutes,
                        reading: false
                    )
                } header: {
                    Text("Daily goals")
                } footer: {
                    Text("Progress comes from recorded reading and listening sessions on this device.")
                }

                Section {
                    ForEach(ReadingMotivationPinnedStat.allCases, id: \.self) { stat in
                        Toggle(
                            stat.label,
                            isOn: Binding(
                                get: { store.settings.pinnedStats.contains(stat) },
                                set: { store.setPinned(stat, isPinned: $0) }
                            )
                        )
                        .disabled(
                            !store.settings.pinnedStats.contains(stat)
                                && store.settings.pinnedStats.count >= 3
                        )
                    }
                    if store.settings.pinnedStats.isEmpty {
                        Text("No stats pinned. The Home strip will show this empty state.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Pinned on Home · up to 3")
                } footer: {
                    Text("Unselected stats stay available in the Stats tab.")
                }

                Section {
                    Toggle(
                        "Motivational reminders",
                        isOn: Binding(
                            get: { store.settings.notificationsEnabled },
                            set: { enabled in
                                Task { _ = await store.setNotificationsEnabled(enabled) }
                            }
                        )
                    )
                    DatePicker(
                        "Quiet delivery time",
                        selection: quietTime,
                        displayedComponents: .hourAndMinute
                    )
                    .disabled(!store.settings.notificationsEnabled)
                    Text(store.notificationMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Notifications")
                } footer: {
                    Text("Optional local reminders only. iOS asks for permission when you turn them on.")
                }
            }
            .navigationTitle("Reading motivation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var quietTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    from: DateComponents(
                        hour: store.settings.quietHour,
                        minute: store.settings.quietMinute
                    )
                ) ?? Date()
            },
            set: { store.setQuietTime($0) }
        )
    }

    private func goalStepper(title: String, value: Int, reading: Bool) -> some View {
        Stepper(
            value: Binding(
                get: {
                    reading
                        ? store.settings.dailyReadingGoalMinutes
                        : store.settings.dailyListeningGoalMinutes
                },
                set: { newValue in
                    store.setGoals(
                        reading: reading ? newValue : store.settings.dailyReadingGoalMinutes,
                        listening: reading ? store.settings.dailyListeningGoalMinutes : newValue
                    )
                }
            ),
            in: 5...240,
            step: 5
        ) {
            LabeledContent(title, value: String(value) + " min")
        }
    }
}
#endif
