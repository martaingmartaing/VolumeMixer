import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        _ = MixerModel.shared // applies saved volumes as soon as the app starts
    }

    func applicationWillTerminate(_ notification: Notification) {
        MixerModel.shared.shutdown()
    }
}

@main
struct VolumeMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = MixerModel.shared

    init() {
        // Command-line options to manage launch at login.
        let arguments = CommandLine.arguments
        if arguments.contains("--enable-login-item") {
            try? SMAppService.mainApp.register()
        }
        if arguments.contains("--login-item-status") {
            print(SMAppService.mainApp.status == .enabled ? "enabled" : "disabled")
            exit(0)
        }
    }

    var body: some Scene {
        MenuBarExtra(L("Volume Mixer", "Mixeur de volume"), systemImage: "slider.vertical.3") {
            MixerView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MixerView: View {
    @ObservedObject var model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Volume Mixer", "Mixeur de volume"))
                .font(.headline)

            VolumeRow(
                icon: Image(systemName: "hifispeaker.fill"),
                title: model.outputName,
                subtitle: L("Master volume", "Volume général"),
                volume: model.masterVolume,
                muted: model.masterMuted,
                enabled: model.masterAdjustable,
                onVolume: model.setMasterVolume,
                onMute: model.toggleMasterMute
            )

            Divider()

            Text(L("Apps", "Applications"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            if model.apps.isEmpty {
                Text(L("No app is playing sound right now.", "Aucune application ne produit de son pour le moment."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(model.apps) { app in
                            VolumeRow(
                                icon: Image(nsImage: app.icon),
                                title: app.name,
                                subtitle: app.isPlaying ? nil : L("Paused", "En pause"),
                                volume: model.volume(for: app.id),
                                muted: model.isMuted(app.id),
                                enabled: true,
                                onVolume: { model.setVolume($0, for: app.id) },
                                onMute: { model.toggleMute(app.id) }
                            )
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Toggle(L("Launch at login", "Lancer au démarrage"), isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .toggleStyle(.checkbox)
                Spacer()
                Button(L("Quit", "Quitter")) { NSApp.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { model.refresh() }
    }
}

struct VolumeRow: View {
    let icon: Image
    let title: String
    let subtitle: String?
    let volume: Float
    let muted: Bool
    let enabled: Bool
    let onVolume: (Float) -> Void
    let onMute: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            icon
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text("\(Int((volume * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(get: { Double(volume) }, set: { onVolume(Float($0)) }),
                    in: 0...1
                )
                .controlSize(.small)
                .disabled(!enabled)
                .opacity(muted ? 0.45 : 1)
            }

            Button(action: onMute) {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 20)
                    .foregroundStyle(muted ? Color.red : Color.primary)
            }
            .buttonStyle(.borderless)
            .help(muted ? L("Unmute", "Réactiver le son") : L("Mute", "Couper le son"))
        }
    }
}
