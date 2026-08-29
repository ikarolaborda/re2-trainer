import SwiftUI
import RE2TrainerCore

@main
struct RE2TrainerApp: App {
    @StateObject private var trainer = Trainer()

    var body: some Scene {
        MenuBarExtra("RE2", systemImage: "gamecontroller.fill") {
            TrainerPanel(trainer: trainer)
                .frame(width: 300)
        }
        .menuBarExtraStyle(.window)
    }
}

struct TrainerPanel: View {
    @ObservedObject var trainer: Trainer
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            HStack {
                Circle()
                    .fill(trainer.attached ? Color.green : Color.red)
                    .frame(width: 9, height: 9)
                Text("Resident Evil 2")
                    .font(.headline)
                Spacer()
                if trainer.attached && !trainer.binaryVerified {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help("Game version differs from the one these offsets were built for")
                }
            }

            if trainer.pausedForSave {
                Label("Save in progress — writes paused", systemImage: "pause.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Text(trainer.status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Text(trainer.calibrationHint)
                .font(.caption)
                .foregroundStyle(trainer.calibrated ? .green : .orange)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            Group {
                Toggle("Godmode", isOn: $trainer.godmode)
                if trainer.godmode && !trainer.playerHP.isEmpty {
                    Text("HP \(trainer.playerHP)")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }

                Toggle("One-Hit Kill", isOn: $trainer.oneHitKill)
                if trainer.oneHitKill {
                    Text("\(trainer.enemiesTracked) enemies tracked")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }

                Toggle("Infinite Magnum", isOn: $trainer.infiniteMagnum)

                Divider().padding(.vertical, 2)

                Toggle("Invincible", isOn: $trainer.invincible)
                Toggle("No Damage", isOn: $trainer.noDamage)
                Toggle("Freeze Timer", isOn: $trainer.freezeTimer)
                Toggle("Mr. X Stays Down", isOn: $trainer.bossesDown)
            }
            .toggleStyle(.switch)
            .disabled(!trainer.attached)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Button("Reset Save Count") { trainer.resetSaveCount() }
                    .disabled(!trainer.attached)
                if !trainer.saveCountStatus.isEmpty {
                    Text(trainer.saveCountStatus)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .font(.caption)

            Divider()

            HStack {
                Button("Reattach") { trainer.attach() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.caption)
        }
        .padding(14)
        .onAppear {
            trainer.attach()
            // Re-attach automatically when the game is launched or restarted.
            timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in
                if !trainer.attached { trainer.attach() }
            }
        }
        .onDisappear { timer?.invalidate() }
    }
}
