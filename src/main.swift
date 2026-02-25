import AppKit
import AVKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import SwiftUI
import UniformTypeIdentifiers
import Combine
import UserNotifications

@MainActor
final class ExternalFileOpenBridge: ObservableObject {
    static let shared = ExternalFileOpenBridge()
    @Published var incomingURL: URL?

    private init() {}

    func open(_ url: URL) {
        incomingURL = url
    }
}

@MainActor
final class DockProgressController {
    static let shared = DockProgressController()

    private var rootView: NSView?
    private var iconView: NSImageView?
    private var trackView: NSView?
    private var fillView: NSView?
    private var active = false

    private init() {}

    private func ensureViewHierarchy() {
        guard rootView == nil else { return }

        let size = NSSize(width: 128, height: 128)
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true

        let icon = NSImageView(frame: root.bounds)
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.autoresizingMask = [.width, .height]
        root.addSubview(icon)

        let trackHeight: CGFloat = 10
        let horizontalInset: CGFloat = 14
        let bottomInset: CGFloat = 10
        let trackFrame = NSRect(
            x: horizontalInset,
            y: bottomInset,
            width: size.width - (horizontalInset * 2),
            height: trackHeight
        )

        let track = NSView(frame: trackFrame)
        track.wantsLayer = true
        track.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
        track.layer?.cornerRadius = trackHeight / 2
        track.layer?.borderColor = NSColor.white.withAlphaComponent(0.22).cgColor
        track.layer?.borderWidth = 0.7
        track.autoresizingMask = [.width, .minYMargin]

        let fill = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: trackHeight))
        fill.wantsLayer = true
        fill.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        fill.layer?.cornerRadius = trackHeight / 2
        fill.autoresizingMask = [.height]
        track.addSubview(fill)

        root.addSubview(track)

        rootView = root
        iconView = icon
        trackView = track
        fillView = fill
    }

    func setProgress(_ progress: Double) {
        ensureViewHierarchy()

        let clamped = min(max(progress, 0), 1)
        guard let rootView, let iconView, let trackView, let fillView else { return }

        iconView.image = NSApp.applicationIconImage
        let width = max(2, trackView.bounds.width * CGFloat(clamped))
        fillView.frame = NSRect(x: 0, y: 0, width: width, height: trackView.bounds.height)

        if !active {
            NSApp.dockTile.contentView = rootView
            active = true
        }
        NSApp.dockTile.display()
    }

    func clear() {
        guard active else { return }
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
        active = false
    }
}

