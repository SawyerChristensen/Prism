//
//  AboutView.swift
//  Prism
//

import SwiftUI
import AppKit

/// Custom `Prism > About Prism` panel, opened via the `about` Window scene in PrismApp
/// (CommandGroup(replacing: .appInfo) points here instead of AppKit's default about panel).
struct AboutView: View {
    private var appIcon: NSImage { NSApp.applicationIconImage }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Prism")
                .font(.title2)
                .bold()
            Text("Version \(version) (\(build))")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("A native macOS Milkdrop/projectM-style audio visualizer.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
                // Without this, the Window scene's .windowResizability(.contentSize) computes
                // this Text's ideal height as single-line before wrapping is applied, so the
                // window sizes itself one line too short and the second line gets clipped.
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(32)
        .frame(width: 320)
    }
}

#Preview {
    AboutView()
}
