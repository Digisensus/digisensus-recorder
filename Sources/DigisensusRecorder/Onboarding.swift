import SwiftUI

/// Where the first-launch walkthrough is, and the choices made in it. Nothing is applied
/// until the last step, except permissions and the email sign-in, which happen right away.
@MainActor
final class OnboardingFlow: ObservableObject {
    enum AIChoice: CaseIterable { case account, own, skip }

    static let doneKey = "onboardingDone"
    static let stepCount = 5

    @Published var step = 0
    @Published var aiChoice = AIChoice.account
    @Published var server = ""
    @Published var apiKey = ""
    @Published var autoRecord = true
    @Published var openAtLogin = true
    let signIn = SignInForm()

    var finish: () -> Void = {}
}

struct OnboardingView: View {
    @ObservedObject var flow: OnboardingFlow
    @ObservedObject var model: RecorderModel
    @ObservedObject var permissions: Permissions

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 40) // the title bar, with its traffic lights
            Group {
                switch flow.step {
                case 0: WelcomeStep()
                case 1: HowItWorksStep()
                case 2: PermissionsStep(model: model, permissions: permissions)
                case 3: AISetupStep(flow: flow, library: model.library, account: model.library.account, form: flow.signIn)
                default: ReadyStep(flow: flow)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            Divider()
            footer
                .frame(height: 76)
                .padding(.horizontal, 32)
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
            if flow.step == 0 {
                Text("Takes about a minute").font(.system(size: 13)).foregroundStyle(Palette.tertiary)
            }
            Spacer()
            if flow.step == 2 {
                Text(permissionsHint).font(.system(size: 13)).foregroundStyle(Palette.tertiary)
            }
            primaryButton
        }
    }

    private var permissionsHint: String {
        guard permissions.requiredGranted else { return "You can also allow these later" }
        if case .done(true, true) = model.audioTest { return "All set" }
        return "Test recording to be sure"
    }

    @ViewBuilder private var primaryButton: some View {
        switch flow.step {
        case 0:
            Button { flow.step = 1 } label: {
                HStack(spacing: 8) {
                    Text("Get Started")
                    Image(systemName: "arrow.right").font(.system(size: 13, weight: .semibold))
                }
            }
            .buttonStyle(StrongButtonStyle())
            .keyboardShortcut(.defaultAction)
        case 2:
            Button("Continue") { flow.step += 1 }
                .buttonStyle(StrongButtonStyle(fill: permissions.requiredGranted ? Palette.strong : Palette.tertiary))
                .keyboardShortcut(.defaultAction)
        case 3:
            Button(flow.aiChoice == .skip ? "Skip for Now" : "Continue") { flow.step += 1 }
                .buttonStyle(StrongButtonStyle())
        case OnboardingFlow.stepCount - 1:
            Button("Open Digisensus") { flow.finish() }
                .buttonStyle(StrongButtonStyle())
                .keyboardShortcut(.defaultAction)
        default:
            Button("Continue") { flow.step += 1 }
                .buttonStyle(StrongButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: 1 · Welcome

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

// MARK: 2 · How it works

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
                    Feature(symbol: "record.circle", ink: Color(hex: 0xC02E26), tint: Palette.recordTint,
                            title: "Starts and stops with your call",
                            detail: "Auto-record begins the moment a call starts and ends when you hang up.")
                    Feature(symbol: "bell", ink: Color(hex: 0xB25E14), tint: Palette.dynamic(0xFDF1E6, 0x45331F),
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
                    Feature(symbol: "sparkles", ink: Color(hex: 0x1F5E86), tint: Palette.dynamic(0xE6F2F9, 0x1F3542),
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
    let title: String
    let detail: String

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

// MARK: 3 · Permissions

private struct PermissionsStep: View {
    @ObservedObject var model: RecorderModel
    @ObservedObject var permissions: Permissions

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Allow recording").font(.system(size: 26, weight: .bold)).tracking(-0.5)
                Text("Three permissions, then a quick test. The app records audio only, never your screen.")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.secondary)
            }
            VStack(spacing: 0) {
                row(.microphone, symbol: "mic", ink: Palette.accent, tint: Palette.accentTint,
                    title: "Microphone", tag: "required", detail: "Records your side of the conversation.",
                    action: "Allow")
                Divider()
                row(.systemAudio, symbol: "speaker.wave.2", ink: Color(hex: 0xB25E14), tint: Palette.dynamic(0xFDF1E6, 0x45331F),
                    title: "System Audio Recording", tag: "required",
                    detail: "Records the other side from the calling app. You may need to reopen the app after allowing it.",
                    action: "Open Settings")
                Divider()
                row(.notifications, symbol: "bell", ink: Palette.secondary, tint: Palette.fill,
                    title: "Notifications", tag: "recommended",
                    detail: "Tells you when auto-record starts or stops a recording.", action: "Allow")
            }
            .card()
            testCard
        }
        .padding(.horizontal, 48)
    }

    private func row(_ kind: Permissions.Kind, symbol: String, ink: Color, tint: Color, title: String, tag: String,
                     detail: String, action: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .foregroundStyle(ink)
                .frame(width: 34, height: 34)
                .background(tint, in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                (Text(title).fontWeight(.semibold) + Text(" · \(tag)").font(.system(size: 12, weight: .medium))
                    .foregroundColor(Palette.tertiary))
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
        case .idle: return me ? "Say something" : "Play any video or song"
        case .running: return "Listening…"
        case .failed(let message): return message
        case .done(let heardMe, let heardThem):
            if me { return heardMe ? "Heard you" : "No sound, allow Microphone" }
            return heardThem ? "Heard system audio" : "No sound, allow System Audio"
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

// MARK: 4 · Transcripts & summaries

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
                option(.account, title: "Digisensus account", detail: "Free daily credit. Sign in with your email, no password.",
                       tag: "RECOMMENDED", tagInk: Palette.you)
                option(.own, title: "Your own AI service", detail: "Use your API key, or a server you run yourself.",
                       tag: "FOR ADVANCED USERS", tagInk: Palette.tertiary)
                option(.skip, title: "Not now", detail: "Just record. Everything stays on this Mac.",
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

    private func option(_ choice: OnboardingFlow.AIChoice, title: String, detail: String, tag: String,
                        tagInk: Color) -> some View {
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
                }
            }
        case .waiting(let email, _):
            HStack(alignment: .top, spacing: 12) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Check your inbox at \(email)").font(.system(size: 14, weight: .semibold))
                    Text("Open the link on any device and press Confirm. The app signs in by itself; you can continue meanwhile.")
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
                    // One Markdown string, so both terms render as links.
                    Text(LocalizedStringKey("I accept the [Terms of Service](\(DigisensusAccount.termsURL.absoluteString))"
                        + (form.hasInviteCode
                           ? " and the [Referral Program Terms](\((account.referralTermsURL ?? DigisensusAccount.defaultReferralTermsURL).absoluteString))"
                           : "")
                        + ". Recordings processed with free daily credit may be used to improve Digisensus models."))
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.secondary)
                }
                .toggleStyle(.checkbox)
                Text(account.message ?? "No password. Open the link on any device and the app signs in by itself.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.tertiary)
            }
        }
    }

    private var ownBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Server address").font(.system(size: 13, weight: .semibold))
                    TextField("Server address", text: $flow.server, prompt: Text("https://api.example.com"))
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("API key").font(.system(size: 13, weight: .semibold))
                    SecureField("API key", text: $flow.apiKey, prompt: Text("Optional"))
                }
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
            .labelsHidden()
            .autocorrectionDisabled()
            HStack(spacing: 12) {
                Button("Test Connection") {
                    OnboardingSetup.applyOwnService(flow, to: library)
                    library.checkConnection()
                }
                .disabled(flow.server.isEmpty)
                Text(library.connectionStatus
                     ?? "Any OpenAI-compatible speech-to-text and chat API. Models and language can be changed later in Settings.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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

// MARK: 5 · Ready

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

    private func legend(dot: Color?, period: Double, title: String, detail: String) -> some View {
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

/// The menu bar icon as it looks on a dark menu bar, with its status dot.
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

/// Applies the walkthrough's choices when it finishes.
@MainActor
enum OnboardingSetup {
    static func applyOwnService(_ flow: OnboardingFlow, to library: LibraryStore) {
        library.aiService = .own
        let server = flow.server.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !server.isEmpty else { return }
        library.transcription.server = server
        library.summary.server = server
        library.transcription.apiKey = flow.apiKey
        library.summary.apiKey = flow.apiKey
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
