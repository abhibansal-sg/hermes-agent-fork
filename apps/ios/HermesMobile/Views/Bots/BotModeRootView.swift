import SwiftUI

/// Native Bot Mode root. It presents the Hermes profile roster, resolves a
/// selected profile's canonical durable session, and reuses ``ChatView`` rather
/// than introducing another transcript or composer surface.
struct BotModeRootView: View {
    @Environment(BotModeStore.self) private var botMode
    @Environment(ConnectionStore.self) private var connection
    @Environment(SessionStore.self) private var sessions
    @Environment(ThemeStore.self) private var themeStore

    /// RootView retains the Settings sheet's presentation state so switching
    /// modes cannot dismiss or recreate it during a size-class transition.
    let onOpenSettings: () -> Void

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            BotRosterView(path: $path, onOpenSettings: onOpenSettings)
                .navigationDestination(for: BotChatDestination.self) { _ in
                    ChatView(
                        onNewChat: { sessions.startDraft() },
                        isDraft: sessions.isDraft,
                        modelName: connection.sessionModel ?? connection.activeModelName
                    )
                }
        }
        .hermesThemed(themeStore)
        // A newly accepted transport gets a fresh profile read. This is a
        // presentation refresh only; the server remains profile authority.
        .task(id: connection.transportEpoch) {
            await botMode.refresh(using: connection)
        }
        .alert(
            "Unable to Open Bot",
            isPresented: Binding(
                get: { botMode.openError != nil },
                set: { presented in
                    if !presented { botMode.dismissOpenError() }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(botMode.openError ?? "")
        }
    }
}

private struct BotRosterView: View {
    @Environment(BotModeStore.self) private var botMode
    @Environment(ConnectionStore.self) private var connection
    @Environment(SessionStore.self) private var sessions
    @Environment(\.hermesTheme) private var theme

    @Binding var path: NavigationPath
    let onOpenSettings: () -> Void

    var body: some View {
        List {
            rosterContent
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(theme.bg)
        .navigationTitle("Bots")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Open settings")
                .accessibilityIdentifier("botModeSettings")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await botMode.refresh(using: connection) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh bots")
                .accessibilityIdentifier("botModeRefresh")
            }
        }
        .refreshable {
            await botMode.refresh(using: connection)
        }
        .accessibilityIdentifier("botModeRoster")
    }

    @ViewBuilder
    private var rosterContent: some View {
        switch botMode.rosterPhase {
        case .idle where botMode.profiles.isEmpty,
             .loading where botMode.profiles.isEmpty:
            Section {
                ProgressView("Loading bots…")
                    .frame(maxWidth: .infinity, alignment: .center)
                    .accessibilityIdentifier("botModeLoading")
            }
            .listRowBackground(theme.card)
        case .loaded where botMode.profiles.isEmpty:
            emptyState
        case .failed(let message) where botMode.profiles.isEmpty:
            errorState(message)
        default:
            botsSection
            if case .loading = botMode.rosterPhase {
                Section {
                    ProgressView("Refreshing bots…")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .listRowBackground(theme.card)
            }
            if case .failed(let message) = botMode.rosterPhase {
                errorState(message)
            }
        }
    }

    private var botsSection: some View {
        Section("Bots") {
            ForEach(botMode.profiles) { profile in
                BotRosterRow(
                    profile: profile,
                    openingProfileID: botMode.openingProfileID,
                    path: $path
                )
                .listRowBackground(theme.card)
            }
        }
    }

    private var emptyState: some View {
        Section {
            ContentUnavailableView(
                "No Bots",
                systemImage: "person.2.slash",
                description: Text("Hermes has no profiles available for Bot Mode.")
            )
            .accessibilityIdentifier("botModeEmpty")
        }
        .listRowBackground(Color.clear)
    }

    private func errorState(_ message: String) -> some View {
        Section {
            ContentUnavailableView {
                Label("Couldn’t Load Bots", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") {
                    Task { await botMode.refresh(using: connection) }
                }
            }
            .accessibilityIdentifier("botModeError")
        }
        .listRowBackground(Color.clear)
    }
}

private struct BotRosterRow: View {
    @Environment(BotModeStore.self) private var botMode
    @Environment(ConnectionStore.self) private var connection
    @Environment(SessionStore.self) private var sessions
    @Environment(\.hermesTheme) private var theme

    let profile: ProfileSummary
    let openingProfileID: String?
    @Binding var path: NavigationPath

    private var isOpening: Bool { openingProfileID == profile.id }
    private var subtitle: String {
        if let description = profile.description,
           !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return description
        }
        return profile.isDefault ? "Default profile" : "Hermes profile"
    }

    var body: some View {
        Button {
            Task {
                guard let destination = await botMode.open(
                    profile,
                    in: sessions,
                    using: connection
                ) else { return }
                path.append(destination)
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title2)
                    .foregroundStyle(theme.midground)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(profile.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(theme.fg)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(theme.mutedFg)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                if isOpening {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(theme.mutedFg)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(openingProfileID != nil)
        .accessibilityLabel("Open \(profile.name) bot")
        .accessibilityValue(isOpening ? "Opening" : subtitle)
        .accessibilityHint("Opens this bot’s canonical Hermes chat")
        .accessibilityIdentifier("botRosterRow.\(profile.id)")
    }
}
