import SwiftUI
import AppKit

/// The "About Claude Usage Menu" window: app identity, version and links.
struct AboutView: View {
    private static let repositoryURL = URL(string: "https://github.com/psimaker/claude-usage-menu")!
    private static let licenseURL = URL(string: "https://github.com/psimaker/claude-usage-menu/blob/main/LICENSE")!

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
                .accessibilityHidden(true)

            Text("Claude Usage Menu")
                .font(.title3)
                .fontWeight(.semibold)

            Text(appVersion)
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Menu bar app showing your Claude session, weekly and Sonnet usage limits — data straight from the claude.ai OAuth API.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            HStack(spacing: 16) {
                Link("GitHub", destination: Self.repositoryURL)
                Link("MIT License", destination: Self.licenseURL)
            }
            .font(.caption)
            .padding(.top, 8)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(width: 300)
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? "Version \(version)" : "Version \(version) (\(build))"
    }
}
