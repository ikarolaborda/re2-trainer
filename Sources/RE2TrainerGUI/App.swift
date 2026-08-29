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

            // Godmode writes into the player's health component, and a
            // signature match alone does not identify it -- ~45 structs match.
            // Calibration proves which ones move when you take damage.
            VStack(alignment: .leading, spacing: 6) {
                Text(trainer.calibrationHint)
                    .font(.caption)
                    .foregroundStyle(trainer.calibrated ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button("1 · Baseline") { trainer.calibrateStep1() }
                    Button("2 · After hit") { trainer.calibrateStep2() }
                }
                .font(.caption)
                .disabled(!trainer.attached)
            }
            .padding(.bottom, 2)

            Divider()

            Group {
                Toggle("Godmode", isOn: $trainer.godmode)
                    .disabled(!trainer.calibrated)
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
            }
            .toggleStyle(.switch)
            .disabled(!trainer.attached)

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
