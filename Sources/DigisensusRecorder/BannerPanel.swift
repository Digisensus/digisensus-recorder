import AppKit
import SwiftUI

@MainActor
final class BannerPresenter {
    struct Banner {
        let symbol: String
        let tint: Color
        let title: String
        let detail: String
        var button: String? = nil
        var action: () -> Void = {}
    }

    private static let margin: CGFloat = 12

    private var panel: NSPanel?
    private var host: NSHostingView<BannerView>?
    private var dismissTask: Task<Void, Never>?

    func show(_ banner: Banner, for seconds: Double) {
        dismissTask?.cancel()
        let view = BannerView(banner: banner) { [weak self] in self?.dismiss() }
        if let host {
            host.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            host.sizingOptions = [.preferredContentSize]
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.isMovableByWindowBackground = false
            panel.animationBehavior = .utilityWindow
            panel.contentView = host
            self.panel = panel
            self.host = host
        }
        guard let panel, let host else { return }

        host.layoutSubtreeIfNeeded()
        var size = host.intrinsicContentSize
        if size.width <= 0 || size.height <= 0 { size = host.fittingSize }
        if size.width <= 0 || size.height <= 0 { size = NSSize(width: 372, height: 72) }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: area.maxX - size.width - Self.margin, y: area.maxY - size.height - Self.margin)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                panel.animator().alphaValue = 1
            }
        }

        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                if self.dismissTask == nil { panel.orderOut(nil) }
            }
        })
    }
}

private struct BannerView: View {
    let banner: BannerPresenter.Banner
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: banner.symbol)
                .font(.title2)
                .foregroundStyle(banner.tint)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(banner.title).font(.callout.weight(.semibold))
                Text(banner.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let title = banner.button {
                Button {
                    banner.action()
                    close()
                } label: {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(banner.tint, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(width: 360)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.1)))
        .padding(6)
    }
}
