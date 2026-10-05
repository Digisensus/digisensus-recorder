import SwiftUI

struct PlayerView: View {
    @ObservedObject var player: PlayerModel

    var body: some View {
        HStack(spacing: 16) {
            Button(action: player.togglePlayback) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.onStrong)
                    .frame(width: 42, height: 42)
                    .background(Palette.strong, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])
            .disabled(player.duration == 0)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
            .help(player.isPlaying ? "Pause (Space)" : "Play (Space)")

            Group {
                if let failure = player.failure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    VStack(spacing: 6) {
                        Lane(label: "You", ink: Palette.you, wave: Palette.youWave, peaks: player.peaks[1], player: player)
                        Lane(label: "Them", ink: Palette.them, wave: Palette.themWave, peaks: player.peaks[0], player: player)
                    }
                    .overlay {
                        if player.isPreparing {
                            ProgressView("Preparing audio…").controlSize(.small)
                                .padding(.horizontal, 10)
                                .background(Palette.card.opacity(0.9), in: Capsule())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .trailing, spacing: 6) {
                (Text(Self.clock(player.currentTime))
                    + Text(" / " + Self.clock(player.duration)).foregroundColor(Palette.tertiary))
                    .font(.system(size: 13))
                    .monospacedDigit()
                Menu {
                    Picker("Speed", selection: $player.rate) {
                        ForEach(PlayerModel.rates, id: \.self) { Text(Self.rateText($0)).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Picker("Listen to", selection: $player.channelMode) {
                        Text("Both sides").tag(PlayerModel.ChannelMode.both)
                        Text("Only them").tag(PlayerModel.ChannelMode.them)
                        Text("Only you").tag(PlayerModel.ChannelMode.me)
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text(Self.rateText(player.rate) + (player.channelMode == .both ? "" : player.channelMode == .me ? " · You" : " · Them"))
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 8)
                        .frame(height: 24)
                        .card(radius: 6)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Playback speed, and which side to listen to")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .card(radius: 14)
    }

    static func clock(_ time: TimeInterval) -> String {
        RecorderModel.clock(time.rounded(.down))
    }

    static func rateText(_ rate: Float) -> String {
        rate == rate.rounded() ? "\(Int(rate))×" : "\(rate.formatted())×"
    }
}

private struct Lane: View {
    let label: String
    let ink: Color
    let wave: Color
    let peaks: [Float]
    @ObservedObject var player: PlayerModel

    var body: some View {
        HStack(spacing: 10) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ink)
                .frame(width: 34, alignment: .leading)
            GeometryReader { proxy in
                let progress = player.duration > 0 ? player.currentTime / player.duration : 0
                Canvas { context, size in
                    let step: CGFloat = 5
                    let bars = max(1, Int(size.width / step))
                    guard !peaks.isEmpty else {
                        context.fill(Path(CGRect(x: 0, y: size.height / 2 - 1, width: size.width, height: 2)),
                                     with: .color(wave.opacity(0.25)))
                        return
                    }
                    for bar in 0..<bars {
                        let from = bar * peaks.count / bars
                        let to = max(from + 1, (bar + 1) * peaks.count / bars)
                        let peak = peaks[from..<min(to, peaks.count)].max() ?? 0
                        let height = max(2, CGFloat(sqrt(peak)) * size.height)
                        let played = Double(bar) / Double(bars) < progress
                        context.fill(
                            Path(roundedRect: CGRect(x: CGFloat(bar) * step, y: (size.height - height) / 2,
                                                     width: 3, height: height), cornerRadius: 1.5),
                            with: .color(wave.opacity(played ? 1 : 0.45)))
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    guard player.duration > 0, proxy.size.width > 0 else { return }
                    player.seek(to: player.duration * min(1, max(0, value.location.x / proxy.size.width)))
                })
            }
            .frame(height: 24)
        }
        .accessibilityElement()
        .accessibilityLabel("\(label), playback position")
        .accessibilityValue("\(PlayerView.clock(player.currentTime)) of \(PlayerView.clock(player.duration))")
    }
}
