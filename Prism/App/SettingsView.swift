//
//  SettingsView.swift
//  Prism
//

import SwiftUI
import AppKit

/// Backs the `Prism > Settings…` menu item (wired up via the `Settings` scene in PrismApp).
/// The Screen Saver and Music Plug-in tabs each expose one of the sandbox-compliant install
/// actions from AddOnsInstaller — see that file's doc comment for why these are user-triggered
/// buttons rather than automatic installs. App Icon is first since it's the tab people reach for
/// most casually - see AppIconManager's doc comment for how the switch itself works.
struct SettingsView: View {
    var body: some View {
        TabView {
            AppIconSettingsTab()
                .tabItem { Label("App Icon", systemImage: "app.dashed") }
            ScreenSaverSettingsTab()
                .tabItem { Label("Screen Saver", systemImage: "moon.stars") }
            MusicVisualizerSettingsTab()
                .tabItem { Label("Apple Music Plug-in", systemImage: "waveform") }
        }
        .frame(width: 420, height: 220)
    }
}

private struct AppIconSettingsTab: View {
    private static let options: [(assetName: String, displayName: String)] = [
        (AppIconManager.defaultAssetName, "Dark Side"),
        (AppIconManager.tieDyeAssetName, "Tie-Dye"),
    ]

    @State private var selectedAssetName = AppIconManager.selectedAssetName

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Choose an app icon:")
                .foregroundStyle(.secondary)
            HStack(spacing: 24) {
                ForEach(Self.options, id: \.assetName) { option in
                    Button {
                        selectedAssetName = option.assetName
                        AppIconManager.selectedAssetName = option.assetName
                        AppIconManager.apply(option.assetName)
                    } label: {
                        VStack(spacing: 6) {
                            Image(nsImage: NSImage(named: option.assetName) ?? NSImage())
                                .resizable()
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(
                                            selectedAssetName == option.assetName
                                                ? Color.accentColor : .clear,
                                            lineWidth: 3
                                        )
                                )
                            Text(option.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

private struct ScreenSaverSettingsTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text(
                "Install Prism as a screen saver, then enable it via System Settings > Wallpaper > Screen Saver... > Other > Prism."
            )
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 320)
            .fixedSize(horizontal: false, vertical: true)

            Button("Install Screen Saver…") {
                AddOnsInstaller.installScreenSaver()
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

private struct MusicVisualizerSettingsTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Apple Music/iTunes Visualizer")
                .font(.headline)

            Button("Install Visualizer Plug-in…") {
                AddOnsInstaller.installVisualizerPlugin()
            }

            Text(
                "In Music, choose Window > Visualizer Settings > Prism to select it, then Window > Visualizer (⌘T)."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 320)
            .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

#Preview {
    SettingsView()
}
