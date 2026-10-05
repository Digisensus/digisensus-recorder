import SwiftUI

struct MenuBarPanel: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var library: LibraryStore
    @ObservedObject var updates: UpdateController
    let openApp: () -> Void
    let openCall: (Int64) -> Void
    let openSettings: () -> Void
    @ObservedObject var messages: MessageCenter
    let openMessages: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 26, height: 26)
                Text("Digisensus Recorder")
                    .font(.system(size: 14, weight: .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16))
                        .foregroundStyle(Palette.secondary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Settings")
            }

            RecordButton(model: model, height: 52)

            if AppDistribution.current == .appStore, updates.isOutdated {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.recordInk)
                    Text("This version is out of date")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Update in App Store", action: updates.openAppStore)
                        .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .card()
            }

            if let pending = updates.pending {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Palette.accent)
                    Text(pending.isReady ? "Version \(pending.version) is ready" : "Version \(pending.version) is available")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(pending.isReady ? "Restart to Update" : "Update…", action: updates.installNow)
                        .controlSize(.small)
                        .disabled(model.isRecording)
                        .help(model.isRecording ? "Updates wait until the recording ends" : "")
                }
                .padding(.horizontal, 14)
                .frame(height: 44)
                .card()
            }

            if let latest = messages.messages.first {
                Button(action: openMessages) {
                    HStack(spacing: 10) {
                        Image(systemName: "megaphone.fill").foregroundStyle(Palette.accent)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(messages.unreadCount > 0 ? "New from Digisensus" : "Messages")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Palette.tertiary)
                            Text(latest.title)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if messages.unreadCount > 0 {
                            Text("\(messages.unreadCount)")
                                .font(.system(size: 11, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .frame(minWidth: 20, minHeight: 20)
                                .background(Capsule().fill(Palette.accent))
                                .accessibilityLabel("\(messages.unreadCount) unread")
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .card()
            }

            VStack(spacing: 0) {
                inputRow("You", ink: Palette.you, levels: model.micHistory, wave: Palette.youWave) {
                    Picker("Your microphone", selection: $model.micID) {
                        ForEach(model.mics) { Text($0.name).tag($0.id) }
                    }
                }
                Divider()
                inputRow("Them", ink: Palette.them, levels: model.appHistory, wave: Palette.themWave) {
                    Picker("Other side", selection: $model.source) {
                        ForEach(model.apps) { Text($0.name).tag($0.source) }
                    }
                }
                Divider()
                Toggle(isOn: $model.autoRecord) {
                    Label("Auto-record calls", systemImage: "bolt.fill")
                        .font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(Palette.accent)
                .padding(.horizontal, 14)
                .frame(height: 48)
            }
            .card()

            if let status = model.message ?? model.autoStatus {
                Text(status)
                    .font(.system(size: 12))
                    .foregroundStyle(model.message == nil ? Palette.tertiary : Palette.recordInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .padding(.top, -6)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("RECENT")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.4)
                    .foregroundStyle(Palette.tertiary)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
                if library.recordings.isEmpty {
                    Text("Your calls show up here.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.tertiary)
                        .padding(.horizontal, 4)
                }
                ForEach(library.recordings.prefix(3)) { recording in
                    Button { openCall(recording.rowID) } label: { recent(recording) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            RecordingMenu(library: library, recording: recording, openApp: { openCall(recording.rowID) })
                        }
                }
            }

            HStack(spacing: 8) {
                Button(action: openApp) { Text("Open Digisensus").frame(maxWidth: .infinity) }
                    .buttonStyle(StrongButtonStyle(height: 40))
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(StrongButtonStyle(fill: Palette.card, ink: Palette.ink, height: 40))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
            }
        }
        .padding(16)
        .frame(width: 360)
        .background(Palette.canvas)
    }

    private func inputRow<P: View>(_ name: String, ink: Color, levels: [Float], wave: Color,
                                   @ViewBuilder picker: () -> P) -> some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(ink)
                .frame(width: 40, alignment: .leading)
            if model.isRecording {
                LevelBars(levels: levels, color: wave, slots: 40, maxHeight: 20)
                    .frame(height: 22)
            } else {
                picker()
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    private func recent(_ recording: Recording) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(recording.titleOrChannel)
                    .font(.system(size: 13, weight: .bold))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(DayText.short(recording.startedAt)) · \(recording.durationShort)")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Palette.tertiary)
            }
            Group {
                switch CallState(recording, in: library) {
                case .summarized(let headline): Text(headline).foregroundStyle(Palette.ink.opacity(0.8))
                case .transcribing: Text("Transcribing…").italic().foregroundStyle(Palette.you)
                case .summarizing: Text("Summarizing…").italic().foregroundStyle(Palette.you)
                case .transcribed: Text("Transcript ready").italic().foregroundStyle(Palette.tertiary)
                case .failed: Text("Transcription failed").italic().foregroundStyle(Palette.recordInk)
                case .audioOnly: Text("Not transcribed").italic().foregroundStyle(Palette.tertiary)
                }
            }
            .font(.system(size: 12))
            .lineLimit(1)
        }
        .padding(8)
        .contentShape(Rectangle())
    }
}
