import SwiftUI

@MainActor
final class OnboardingFlow: ObservableObject {
    enum AIChoice: CaseIterable { case account, own, skip }

    struct ServiceDraft {
        var preset = AIPreset.local
        var server = ""
        var apiKey = ""

        var trimmedServer: String { server.trimmingCharacters(in: .whitespacesAndNewlines) }
        var isComplete: Bool { preset != .other || !trimmedServer.isEmpty }
    }

    nonisolated static let doneKey = "onboardingDone"
    static let onceMoreKey = "showIntroOnNextStart"
    static let stepCount = 6
    private static let languageChosenKey = "onboardingLanguageChosen"

    static var resumesAfterLanguageChoice: Bool { UserDefaults.standard.bool(forKey: languageChosenKey) }

    @Published var step = 0
    @Published var aiChoice = AIChoice.account
    @Published var transcriptionService = ServiceDraft()
    @Published var summaryService = ServiceDraft()
    @Published var autoRecord = true
    @Published var openAtLogin = true
    let signIn = SignInForm()

    var finish: () -> Void = {}

    init() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: Self.languageChosenKey) {
            defaults.removeObject(forKey: Self.languageChosenKey)
            step = 1
        }
    }

    func chooseLanguage(_ code: String) {
        LanguageOffer.markMade()
        guard code != AppLanguage.inUse else {
            step = 1
            return
        }
        AppLanguage.apply(code)
        UserDefaults.standard.set(true, forKey: Self.languageChosenKey)
        AppLanguage.relaunch()
    }

    var summaryUsesTranscriptionKey: Bool {
        summaryService.preset == transcriptionService.preset && summaryService.preset.server != nil
    }

    func draft(for purpose: AIPurpose) -> ServiceDraft {
        purpose == .transcription ? transcriptionService : summaryService
    }

    func keepCurrentSettings(of model: RecorderModel) {
        let library = model.library
        switch library.aiService {
        case .digisensus: aiChoice = .account
        case .own: aiChoice = .own
        case .off: aiChoice = .skip
        }
        transcriptionService = Self.draft(of: library.transcription, for: .transcription)
        summaryService = Self.draft(of: library.summary, for: .summary)
        autoRecord = model.autoRecord
        openAtLogin = model.launchAtLogin
    }

    private static func draft(of settings: some AIServiceSettings, for purpose: AIPurpose) -> ServiceDraft {
        let preset = settings.servicePreset(for: purpose)
        return ServiceDraft(preset: preset, server: preset.server == nil ? settings.server : "", apiKey: settings.apiKey)
    }

    func choose(_ preset: AIPreset, for purpose: AIPurpose) {
        guard preset != draft(for: purpose).preset else { return }
        let draft = ServiceDraft(preset: preset)
        if purpose == .transcription { transcriptionService = draft } else { summaryService = draft }
    }
}

struct OnboardingView: View {
    @ObservedObject var flow: OnboardingFlow
    @ObservedObject var model: RecorderModel
    @ObservedObject var permissions: Permissions

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 40)
            Group {
                switch flow.step {
                case 0: LanguageStep(flow: flow)
                case 1: WelcomeStep()
                case 2: HowItWorksStep()
                case 3: PermissionsStep(model: model, permissions: permissions)
                case 4: AISetupStep(flow: flow, library: model.library, account: model.library.account, form: flow.signIn)
                default: ReadyStep(flow: flow)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if flow.step > 0 {
                Divider()
                footer
                    .frame(height: 76)
                    .padding(.horizontal, 32)
            }
        }
        .frame(width: 760, height: 540)
        .background(Palette.canvas)
        .onAppear { permissions.startWatching() }
        .onDisappear { permissions.stopWatching() }
    }

    private var footer: some View {
        HStack(spacing: 20) {
            if flow.step > 0 {
                Button("Back") { flow.step -= 1 }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.secondary)
                    .frame(height: 44)
            }
            HStack(spacing: 6) {
                ForEach(0..<OnboardingFlow.stepCount, id: \.self) { index in
                    Capsule()
                        .fill(index <= flow.step ? Palette.strong : Palette.tertiary.opacity(0.3))
                        .frame(width: index == flow.step ? 18 : 6, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Step \(flow.step + 1) of \(OnboardingFlow.stepCount)")
            if flow.step == 1 {
                Text("Takes about a minute").font(.system(size: 13)).foregroundStyle(Palette.tertiary)
            }
            Spacer()
            if flow.step == 3 {
                Text(permissionsHint).font(.system(size: 13)).foregroundStyle(Palette.tertiary)
            }
            primaryButton
        }
    }

    private var permissionsHint: LocalizedStringResource {
        guard permissions.requiredGranted else { return "You can also allow these later" }
        if case .done(true, true) = model.audioTest { return "All set" }
        return "Test recording to be sure"
    }

    @ViewBuilder private var primaryButton: some View {
        switch flow.step {
        case 1:
            Button { flow.step = 2 } label: {
                HStack(spacing: 8) {
                    Text("Get Started")
                    Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold))
                }
            }
            .buttonStyle(StrongButtonStyle())
            .keyboardShortcut(.defaultAction)
        case 3:
            Button("Continue") { flow.step += 1 }
                .buttonStyle(StrongButtonStyle(fill: permissions.requiredGranted ? Palette.strong : Palette.tertiary))
                .keyboardShortcut(.defaultAction)
        case 4:
            Button(flow.aiChoice == .skip ? "Skip for Now" : "Continue") { flow.step += 1 }
                .buttonStyle(StrongButtonStyle())
        case OnboardingFlow.stepCount - 1:
            Button("Open Digisensus Recorder") { flow.finish() }
                .buttonStyle(StrongButtonStyle())
                .keyboardShortcut(.defaultAction)
        default:
            Button("Continue") { flow.step += 1 }
                .buttonStyle(StrongButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}

private struct LanguageStep: View {
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        VStack(spacing: 30) {
            VStack(spacing: 12) {
                Image(systemName: "globe")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(Palette.accent)
                Text("Choose your language").font(.system(size: 28, weight: .bold)).tracking(-0.5)
            }
            LanguageGrid(choose: flow.chooseLanguage)
        }
        .padding(.top, 16)
        .padding(.horizontal, 48)
    }
}

struct LanguageGrid: View {
    var choose: (String) -> Void

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(122), spacing: 10), count: 5), spacing: 10) {
            ForEach(AppLanguage.byNativeName, id: \.self) { code in
                let current = code == AppLanguage.inUse
                Button { choose(code) } label: {
                    Text(AppLanguage.nativeName(code))
                        .font(.system(size: 13, weight: current ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(current ? Palette.accentTint : Palette.card, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(current ? Palette.accent : Palette.border, lineWidth: current ? 1.5 : 1))
                        .contentShape(RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(current ? .isSelected : [])
            }
        }
    }
}

struct LanguageOfferSheet: View {
    @ObservedObject var model: RecorderModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 10) {
                Image(systemName: "globe")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Palette.accent)
                Text("Digisensus Recorder now speaks your language")
                    .font(.system(size: 22, weight: .bold)).tracking(-0.4)
                    .multilineTextAlignment(.center)
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 650)
            LanguageGrid(choose: choose)
                .disabled(model.isRecording)
                .opacity(model.isRecording ? 0.5 : 1)
            Button("Keep \(AppLanguage.nativeName(AppLanguage.inUse))") { dismiss() }
                .buttonStyle(StrongButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .padding(.vertical, 36)
        .padding(.horizontal, 48)
        .presentationBackground(Palette.canvas)
        .onExitCommand { dismiss() }
    }

    private var note: LocalizedStringResource {
        if model.isRecording { return "You can switch when the recording ends." }
        return "Choose a language for the app. You can change it later in Settings › General."
    }

    private func choose(_ code: String) {
        guard code != AppLanguage.inUse else { return dismiss() }
        AppLanguage.apply(code)
        AppLanguage.relaunch()
    }
}

private struct WelcomeStep: View {
    private static let apps: [(name: String, dot: UInt32)] = [
        ("FaceTime", 0x5EBDC3), ("WhatsApp", 0x34A7D7), ("Viber", 0x2C71B5), ("Telegram", 0x35336F),
        ("Zoom", 0x5EBDC3), ("Google Meet", 0x34A7D7), ("Teams", 0x2C71B5), ("Slack", 0x35336F),
    ]

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 92, height: 92)
                Text("Digisensus Recorder").font(.system(size: 15, weight: .bold))
            }
            VStack(spacing: 10) {
                Text("Record any call on your Mac")
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.6)
                Text("Get call transcripts that show who said what, plus short summaries of every conversation.")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
            }
            FlowLayout(spacing: 8, alignment: .center) {
                pill {
                    Image(systemName: "iphone").font(.system(size: 13))
                    Text("iPhone calls via Continuity")
                }
                .foregroundStyle(Palette.you)
                .background(Palette.accentTint, in: Capsule())
                ForEach(Self.apps, id: \.name) { app in
                    pill {
                        Circle().fill(Color(hex: app.dot)).frame(width: 8, height: 8)
                        Text(app.name)
                    }
                    .background(Palette.card, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.border))
                }
                pill { Text("and any other app").fontWeight(.medium) }
                    .foregroundStyle(Palette.secondary)
                    .overlay(Capsule().strokeBorder(Palette.tertiary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            }
            .frame(maxWidth: 600)
        }
        .padding(.horizontal, 56)
    }

    private func pill<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 7) { content() }
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 12)
            .frame(height: 34)
    }
}

private struct HowItWorksStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("How it works").font(.system(size: 28, weight: .bold)).tracking(-0.5)
                Text("Set it once, and your calls take care of themselves.")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.secondary)
            }
            Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Feature(symbol: "record.circle", ink: Palette.dynamic(0xC02E26, 0xFF7A70), tint: Palette.recordTint,
                            title: "Starts and stops with your call",
                            detail: "Auto-record begins the moment a call starts and ends when you hang up.")
                    Feature(symbol: "bell", ink: Palette.dynamic(0xB25E14, 0xF0A35E), tint: Palette.dynamic(0xFDF1E6, 0x45331F),
                            title: "You always know",
                            detail: "A banner flashes when recording starts, with a Stop button. Stop any time.")
                }
                GridRow {
                    Feature(symbol: "mic.slash", ink: Palette.accent, tint: Palette.accentTint,
                            title: "Never listening between calls",
                            detail: "Audio is captured only while a call is streaming. No call, no recording.")
                    Feature(symbol: "lock", ink: Palette.good, tint: Palette.goodTint,
                            title: "Private, on your Mac",
                            detail: "Recordings stay in a folder on this Mac. Nothing is uploaded unless you choose.")
                }
                GridRow {
                    Feature(symbol: "sparkles", ink: Palette.dynamic(0x1F5E86, 0x7DB8E0), tint: Palette.dynamic(0xE6F2F9, 0x1F3542),
                            title: "AI when you want it",
                            detail: "Transcripts that show who said what, and short summaries. With MCP, Claude Code or Codex can find recordings, read transcripts and start or stop recording.")
                        .gridCellColumns(2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 48)
    }
}

private struct Feature: View {
    let symbol: String
    let ink: Color
    let tint: Color
    let title: LocalizedStringResource
    let detail: LocalizedStringResource

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .foregroundStyle(ink)
                .frame(width: 38, height: 38)
                .background(tint, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .card()
    }
}

private struct PermissionsStep: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var permissions: Permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Allow recording").font(.system(size: 26, weight: .bold)).tracking(-0.5)
                Text("A few permissions, then a quick test. The app records audio only, never your screen.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondary)
            }
            VStack(spacing: 0) {
                row(.microphone, symbol: "mic", ink: Palette.accent, tint: Palette.accentTint,
                    title: "Microphone", tag: "required", detail: "Records your side of the conversation.",
                    action: "Allow")
                Divider()
                row(.systemAudio, symbol: "speaker.wave.2", ink: Palette.dynamic(0xB25E14, 0xF0A35E), tint: Palette.dynamic(0xFDF1E6, 0x45331F),
                    title: "System Audio Recording", tag: "required",
                    detail: "Records the other side from the calling app.",
                    action: permissions.systemAudioRefused ? "Open Settings" : "Allow")
                Divider()
                row(.notifications, symbol: "bell", ink: Palette.secondary, tint: Palette.fill,
                    title: "Notifications", tag: "recommended",
                    detail: "Messages from Digisensus, and recordings started by an AI agent.", action: "Allow")
                Divider()
                row(.meetingNames, symbol: "globe", ink: Palette.secondary, tint: Palette.fill,
                    title: "Browser meeting names", tag: "optional",
                    detail: "Shows the meeting app, like Zoom or Teams, instead of the browser's name.",
                    action: permissions.meetingNamesRefused ? "Open Settings" : "Allow")
            }
            .card()
            testCard
        }
        .padding(.horizontal, 48)
    }

    private func row(_ kind: Permissions.Kind, symbol: String, ink: Color, tint: Color, title: LocalizedStringResource,
                     tag: LocalizedStringResource, detail: LocalizedStringResource, action: LocalizedStringResource) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(ink)
                .frame(width: 34, height: 34)
                .background(tint, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                (Text(title).fontWeight(.semibold) + Text(verbatim: " · ").font(.system(size: 12, weight: .medium))
                    + Text(tag).font(.system(size: 12, weight: .medium)).foregroundColor(Palette.tertiary))
                    .font(.system(size: 14))
                Text(kind == .systemAudio && permissions.systemAudioRefused ? Permissions.systemAudioHint : detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if permissions.isGranted(kind) {
                Label("Allowed", systemImage: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.good)
            } else if kind.isRequired {
                Button(action) { permissions.request(kind) }
                    .buttonStyle(StrongButtonStyle(height: 32))
            } else {
                Button(action) { permissions.request(kind) }
                    .buttonStyle(StrongButtonStyle(fill: Palette.card, ink: Palette.ink, height: 32))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.border))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private var testCard: some View {
        let test = model.audioTest
        let live = test == .running
        return HStack(spacing: 18) {
            VStack(spacing: 10) {
                testRow("You", ink: Palette.you, wave: Palette.youWave, levels: live ? model.micHistory : [],
                        status: status(me: true), statusInk: statusInk(me: true))
                testRow("Them", ink: Palette.them, wave: Palette.themWave, levels: live ? model.appHistory : [],
                        status: status(me: false), statusInk: statusInk(me: false))
            }
            VStack(spacing: 6) {
                Button {
                    Task { await model.runAudioTest() }
                } label: {
                    HStack(spacing: 8) {
                        Circle().fill(Palette.record).frame(width: 8, height: 8)
                        Text(live ? "Testing…" : "Test")
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(live ? Palette.onStrong : Palette.ink)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .background(live ? Palette.strong : Palette.card, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.strong))
                    .contentShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(live || model.isRecording)
                Text(test == .done(me: true, them: true) ? "Both sides work" : "5 seconds, nothing saved")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 112)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .card()
    }

    private func testRow(_ name: String, ink: Color, wave: Color, levels: [Float], status: String, statusInk: Color) -> some View {
        HStack(spacing: 12) {
            Text(name).font(.system(size: 12, weight: .bold)).foregroundStyle(ink).frame(width: 38, alignment: .leading)
            LevelBars(levels: levels, color: wave, maxHeight: 20, fade: false)
                .frame(height: 22)
                .background(alignment: .leading) {
                    if levels.isEmpty {
                        Capsule().fill(Palette.track).frame(height: 2)
                    }
                }
            Text(status)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusInk)
                .frame(width: 170, alignment: .leading)
        }
    }

    private func status(me: Bool) -> String {
        switch model.audioTest {
        case .idle: return me ? String(localized: "Say something") : String(localized: "Plays a short chime")
        case .running: return String(localized: "Listening…")
        case .failed(let message): return message
        case .done(let heardMe, let heardThem):
            if me { return heardMe ? String(localized: "Heard you") : String(localized: "No sound, allow Microphone") }
            return heardThem ? String(localized: "Heard system audio") : String(localized: "No sound, allow System Audio")
        }
    }

    private func statusInk(me: Bool) -> Color {
        switch model.audioTest {
        case .done(let heardMe, let heardThem): return (me ? heardMe : heardThem) ? Palette.good : Palette.recordInk
        case .failed: return Palette.recordInk
        default: return Palette.tertiary
        }
    }
}

private struct AISetupStep: View {
    @ObservedObject var flow: OnboardingFlow
    @ObservedObject var library: LibraryStore
    @ObservedObject var account: DigisensusAccount
    @ObservedObject var form: SignInForm

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Transcripts & summaries").font(.system(size: 28, weight: .bold)).tracking(-0.5)
                Text("Optional. Turn recordings into searchable text and short summaries.")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.secondary)
            }
            HStack(spacing: 12) {
                option(.account, title: AIService.digisensus.label, detail: "Free daily credit. Sign in with your email, no password.",
                       tag: "RECOMMENDED", tagInk: Palette.you)
                option(.own, title: AIService.own.label, detail: "A server on this Mac, or a cloud API with your key.",
                       tag: "FOR ADVANCED USERS", tagInk: Palette.tertiary)
                option(.skip, title: String(localized: "Not now"), detail: "Just record. Everything stays on this Mac.",
                       tag: "NO AI", tagInk: Palette.tertiary)
            }
            Group {
                switch flow.aiChoice {
                case .account: accountBox
                case .own: ownBox
                case .skip: skipBox
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 176, alignment: .top)
            .card()
        }
        .padding(.horizontal, 56)
    }

    private func option(_ choice: OnboardingFlow.AIChoice, title: String, detail: LocalizedStringResource,
                        tag: LocalizedStringResource, tagInk: Color) -> some View {
        let selected = flow.aiChoice == choice
        return Button {
            flow.aiChoice = choice
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Circle()
                        .strokeBorder(selected ? Palette.accent : Palette.tertiary.opacity(0.6), lineWidth: selected ? 5 : 1.5)
                        .frame(width: 16, height: 16)
                }
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Text(tag).font(.system(size: 11, weight: .semibold)).foregroundStyle(tagInk)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .strokeBorder(selected ? Palette.accent : Palette.border, lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .frame(height: 118)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var accountBox: some View {
        switch account.state {
        case .signedIn(let email):
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(Palette.good)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Signed in as \(email)").font(.system(size: 14, weight: .semibold))
                    Text("Transcripts and summaries use your free daily credit.")
                        .font(.system(size: 13)).foregroundStyle(Palette.secondary)
                    TrainingToggle(account: account)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .padding(.top, 8)
                }
            }
        case .waiting(let email, _):
            HStack(alignment: .top, spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Check your inbox at \(email)").font(.system(size: 14, weight: .semibold))
                    Text("Open the link on any device and confirm your email address. The app signs in by itself; you can continue meanwhile.")
                        .font(.system(size: 13))
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Button("Resend") { account.resend(to: email) }
                        Button("Use Another Email", action: account.cancel)
                    }
                    .controlSize(.small)
                    .padding(.top, 4)
                }
            }
        case .signedOut, .sending:
            VStack(alignment: .leading, spacing: 12) {
                Text("Your email").font(.system(size: 13, weight: .semibold))
                HStack(spacing: 10) {
                    TextField("Email", text: $form.email, prompt: Text("you@example.com"))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .onSubmit { form.send(to: account) }
                    TextField("Invite code", text: $form.inviteCode, prompt: Text("Invite code (optional)"))
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.large)
                        .autocorrectionDisabled()
                        .frame(width: 170)
                    Button("Send Sign-in Link") { form.send(to: account) }
                        .buttonStyle(StrongButtonStyle(fill: Palette.accent, ink: .white, height: 32))
                        .disabled(!form.emailLooksValid || !form.acceptedTerms || account.state == .sending)
                }
                Toggle(isOn: $form.acceptedTerms) {
                    Text(LocalizedStringKey(termsAcceptance))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                }
                .toggleStyle(.checkbox)
                Text(account.message ?? String(localized: "No password. Open the link on any device and the app signs in by itself."))
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
            }
        }
    }

    private var ownBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    columnTitle("Service")
                    columnTitle("Server address")
                    columnTitle("API key")
                }
                serviceRow(.transcription, title: "Transcription", detail: "ASR", draft: $flow.transcriptionService)
                serviceRow(.summary, title: "Summaries", detail: "LLM", draft: $flow.summaryService)
            }
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .autocorrectionDisabled()
            HStack(spacing: 12) {
                Button("Test Connection") {
                    OnboardingSetup.applyOwnService(flow, to: library)
                    library.checkConnection()
                    library.checkSummaryConnection()
                }
                .disabled(!flow.transcriptionService.isComplete || !flow.summaryService.isComplete)
                Text(connectionStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var termsAcceptance: String {
        let terms = DigisensusAccount.termsURL.absoluteString
        guard form.hasInviteCode else { return String(format: String(localized: "I accept the [Terms of Service](%@)."), terms) }
        let referral = (account.referralTermsURL ?? DigisensusAccount.defaultReferralTermsURL).absoluteString
        return String(format: String(localized: "I accept the [Terms of Service](%1$@) and the [Referral Program Terms](%2$@)."),
                      terms, referral)
    }

    private var connectionStatus: String {
        switch (library.connectionStatus, library.summaryConnectionStatus) {
        case (nil, nil):
            return String(localized: "Other server takes any OpenAI-compatible API. Models and language can be changed later in Settings.")
        case let (transcription, summary):
            return String(localized: "Transcription: \(transcription ?? "…")  Summaries: \(summary ?? "…")")
        }
    }

    private func columnTitle(_ title: LocalizedStringResource) -> some View {
        Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.secondary)
    }

    private func serviceRow(_ purpose: AIPurpose, title: LocalizedStringResource, detail: LocalizedStringResource,
                            draft: Binding<OnboardingFlow.ServiceDraft>) -> some View {
        let preset = draft.wrappedValue.preset
        return GridRow {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(Palette.tertiary)
            }
            ServicePicker(purposes: [purpose], selection: preset) { flow.choose($0, for: purpose) }
                .frame(width: 170)
            if let fixed = preset.server {
                Text(URL(string: fixed)?.host ?? fixed)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
                    .lineLimit(1)
                    .help(fixed)
                    .frame(minWidth: 150, alignment: .leading)
            } else {
                TextField("Server address", text: draft.server, prompt: Text(preset.addressPrompt(for: purpose)))
                    .frame(minWidth: 150)
            }
            if purpose == .summary && flow.summaryUsesTranscriptionKey {
                Text("Same key as above")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
            } else {
                SecureField("API key", text: draft.apiKey, prompt: Text(preset.keyPrompt))
            }
        }
    }

    private var skipBox: some View {
        HStack(spacing: 16) {
            Image(systemName: "mic")
                .font(.system(size: 18))
                .foregroundStyle(Palette.secondary)
                .frame(width: 40, height: 40)
                .background(Palette.fill, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text("Recording only").font(.system(size: 14, weight: .semibold))
                Text("Nothing leaves your Mac. You can set up transcripts any time in Settings › Transcription & AI.")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.secondary)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

private struct ReadyStep: View {
    @ObservedObject var flow: OnboardingFlow

    var body: some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("You're all set").font(.system(size: 28, weight: .bold)).tracking(-0.5)
                    Text("Digisensus Recorder lives in your menu bar. Two last choices:")
                        .font(.system(size: 15))
                        .foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    Toggle(isOn: $flow.autoRecord) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Auto-record calls").font(.system(size: 14, weight: .semibold))
                            Text("Starts and stops with your calls. Telling others they're being recorded is up to you.")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                    Divider()
                    Toggle(isOn: $flow.openAtLogin) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Open at login").font(.system(size: 14, weight: .semibold))
                            Text("Always ready in the menu bar.").font(.system(size: 12)).foregroundStyle(Palette.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(16)
                }
                .toggleStyle(.switch)
                .tint(Palette.accent)
                .card()
            }
            .frame(width: 320)

            VStack(alignment: .trailing, spacing: 12) {
                HStack(spacing: 14) {
                    Image(systemName: "wifi").font(.system(size: 12, weight: .semibold))
                    MenuBarGlyph(dot: Palette.accent, period: 2.2)
                        .frame(width: 26, height: 22)
                        .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 5))
                    Text(Date().formatted(.dateTime.weekday(.abbreviated).hour().minute()))
                        .font(.system(size: 12))
                        .monospacedDigit()
                }
                .foregroundStyle(Color(hex: 0xEDEAE4))
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .frame(height: 28)
                .background(Color(hex: 0x2A2825), in: RoundedRectangle(cornerRadius: 8))
                Text("Click the icon any time to record or open the app")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
                    .padding(.top, -4)
                VStack(spacing: 0) {
                    legend(dot: Palette.accent, period: 2.2, title: "Blue dot pulsing",
                           detail: "Waiting for your next call. Not recording and not listening.")
                    Divider()
                    legend(dot: Color(hex: 0xEF4444), period: 1.2, title: "Red dot pulsing",
                           detail: "Recording now. Click the icon to stop.")
                    Divider()
                    legend(dot: nil, period: 0, title: "No dot", detail: "Auto-record is off. Click to record by hand.")
                }
                .card()
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 56)
        .padding(.top, 4)
    }

    private func legend(dot: Color?, period: Double, title: LocalizedStringResource, detail: LocalizedStringResource) -> some View {
        HStack(spacing: 12) {
            MenuBarGlyph(dot: dot, period: period)
                .frame(width: 36, height: 30)
                .background(Color(hex: 0x2A2825), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

private struct MenuBarGlyph: View {
    let dot: Color?
    let period: Double

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: dot == nil ? MenuIcon.plain : MenuIcon.withDotGap)
                .renderingMode(.template)
                .foregroundStyle(.white)
            if let dot {
                PulsingDot(color: dot, size: 6.5, period: period)
                    .offset(x: -0.5, y: 0.5)
            }
        }
        .frame(width: 18, height: 18)
    }
}

@MainActor
enum OnboardingSetup {
    static func applyOwnService(_ flow: OnboardingFlow, to library: LibraryStore) {
        library.aiService = .own
        let transcription = flow.transcriptionService
        let summary = flow.summaryService
        library.choose(transcription.preset, for: .transcription)
        library.choose(summary.preset, for: .summary)
        if transcription.preset.server == nil, !transcription.trimmedServer.isEmpty {
            library.transcription.server = transcription.trimmedServer
        }
        if summary.preset.server == nil, !summary.trimmedServer.isEmpty {
            library.summary.server = summary.trimmedServer
        }
        library.transcription.apiKey = transcription.apiKey
        library.summary.apiKey = flow.summaryUsesTranscriptionKey ? transcription.apiKey : summary.apiKey
    }

    static func apply(_ flow: OnboardingFlow, to model: RecorderModel) {
        let library = model.library
        switch flow.aiChoice {
        case .account: library.aiService = .digisensus
        case .own: applyOwnService(flow, to: library)
        case .skip: library.aiService = .off
        }
        model.autoRecord = flow.autoRecord
        model.launchAtLogin = flow.openAtLogin
        UserDefaults.standard.set(true, forKey: OnboardingFlow.doneKey)
    }
}
