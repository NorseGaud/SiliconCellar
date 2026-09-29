import AppKit
import SiliconCellarCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: LibraryModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = AppIcon.image
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stopWineSessions()
    }
}

enum AppIcon {
    /// A .app reads AppIcon.icns. The SwiftPM resource bundle is only next to a bare binary (`swift run`).
    static let image: NSImage = {
        if Bundle.main.bundleURL.pathExtension != "app",
            let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
            let icon = NSImage(contentsOf: iconURL)
        {
            return icon
        }
        return NSApp.applicationIconImage
    }()
}

@main
struct SiliconCellarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = LibraryModel()

    var body: some Scene {
        WindowGroup("Silicon Cellar") {
            LibraryView(model: model)
                .frame(minWidth: 720, minHeight: 480)
                .onAppear { appDelegate.model = model }
        }
        .windowStyle(.automatic)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Find Runtime Again") {
                    model.findWineAgain()
                }
                .disabled(model.busy)
            }
        }
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var recipes: [Recipe] = []
    @Published var selectedID: String?
    @Published var snapshot = LibrarySnapshot(stage: .setup)
    @Published var activity = ""
    @Published var error: String?
    @Published var busy = false
    @Published var hostMessage: String?
    @Published var homebrewStatus = ""
    @Published var homebrewBusy = false
    @Published var statusLines: [String] = []
    @Published var popup: AppPopup?
    @Published var backgroundReady = false
    @Published var launchProgress = SteamLaunchProgress()
    @Published var installedIDs: Set<String> = []
    @Published var detailStatusReady = false
    private var library: Library?
    private var timer: Timer?
    private var refreshInFlight = false
    private var refreshAgain = false
    /// Consecutive Steam-up polls before UI shows "Steam is running" (avoids orphan flicker).
    private var steamUpConfirmations = 0
    private let steamUpConfirmNeeded = 3

    var selected: Recipe? { recipes.first { $0.id == selectedID } }
    /// Stable Steam-up for buttons/labels — ignores brief false-positive polls.
    var steamIsUpStable: Bool { steamUpConfirmations >= steamUpConfirmNeeded }
    /// True while an action runs, or while Steam is still starting (no window yet).
    var sessionBusy: Bool {
        busy || homebrewBusy || (snapshot.wineSessionLive && !steamIsUpStable)
    }

    func stopWineSessions() {
        timer?.invalidate()
        timer = nil
        library?.stopAllSessions()
    }

    /// Always close Steam. Does not stop only the game.
    func stopSteamSession() {
        library?.stopAllSessions()
        appendStatus("Stopped Steam.")
        busy = false
        activity = ""
        backgroundReady = true
        refreshInstalled()
        refresh()
    }

    /// Actions that show Steam UI after the user clicks (install, sign-in, play, …).
    private static let steamFrontActions: Set<LibraryAction> = [
        .setup, .steam, .install, .uninstall, .logout, .play
    ]

    func start() {
        do {
            let executableDirectory = Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS")
            let store = RecipeStore.standard(executableDirectory: executableDirectory)
            recipes = try store.loadAll()
            selectedID = nil
            refreshHost()
            library?.removeLegacyData()
            WineTerminal.closeStagingSessions()
            applySelectedFileStatus()
            refresh()
            refreshInstalled()
            backgroundReady = hostMessage == nil
            DispatchQueue.global(qos: .utility).async {
                try? GPTKCleanup().removeLeftovers { _ in }
                DispatchQueue.main.async {
                    self.refreshHost()
                    self.refresh()
                }
            }
            if hostMessage?.localizedCaseInsensitiveContains("game runtime was not found") == true {
                findWineAgain()
            } else if let hostMessage {
                presentPopup(hostMessage, retry: true)
            }
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                    self?.refreshInstalled()
                }
            }
        } catch {
            presentPopup((error as? PortError)?.message ?? error.localizedDescription, retry: false)
        }
    }

    func refreshHost() {
        do {
            let status = try LiveHostInspector().inspect()
            let pair = try HostCheck.require(status)
            library = Library(
                recipes: [Recipe.onboarding] + recipes,
                wine: pair.wine,
                wineserver: pair.wineserver,
                sink: CallbackSink { message in
                    DispatchQueue.main.async { [weak self] in
                        self?.appendStatus(message)
                    }
                }
            )
            hostMessage = nil
        } catch let error as PortError {
            library = nil
            hostMessage = error.message
        } catch {
            library = nil
            hostMessage = error.localizedDescription
        }
    }

    func findWineAgain() {
        guard !busy else { return }
        busy = true
        homebrewBusy = true
        homebrewStatus = "Checking runtime…"
        activity = "Checking runtime…"
        statusLines = []
        appendStatus("Checking runtime…")
        popup = nil
        backgroundReady = false
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try GPTKCleanup().removeLeftovers { line in
                    DispatchQueue.main.async {
                        self.homebrewStatus = line
                        self.activity = line
                        self.appendStatus(line)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = (error as? PortError)?.message ?? error.localizedDescription
                }
            }
            DispatchQueue.main.async {
                self.refreshHost()
                if self.hostMessage == nil {
                    self.error = nil
                    self.homebrewStatus = ""
                    self.statusLines = []
                    self.popup = nil
                    self.backgroundReady = true
                } else {
                    self.backgroundReady = false
                    self.presentPopup(
                        [self.error, self.hostMessage, EngineLocator.missingMessage]
                            .compactMap { $0 }
                            .joined(separator: "\n\n"),
                        retry: true
                    )
                }
                self.busy = false
                self.homebrewBusy = false
                self.activity = ""
                self.refresh()
            }
        }
    }

    var installInProgress: Bool { busy && activity == "install" && !snapshot.isInstalled }
    var uninstallInProgress: Bool { busy && activity == "uninstall" }
    /// Spinner + status text while Steam is starting or work is in progress — not when Steam is idle and up.
    var showsSessionProgress: Bool {
        if busy || homebrewBusy { return true }
        if !launchProgress.detail.isEmpty { return true }
        if snapshot.wineSessionLive, !steamIsUpStable { return true }
        return false
    }

    /// Sync disk status for the selected game so steps do not flash the wrong action.
    func applySelectedFileStatus() {
        guard let library else {
            detailStatusReady = false
            return
        }
        let recipe = selected ?? Recipe.onboarding
        let keepLive = snapshot.wineSessionLive
        let keepSteam = snapshot.steamReady
        let keepWindow = snapshot.steamWindowVisible
        let keepGame = snapshot.gameRunning
        snapshot = LibrarySnapshot.display(
            library.runtime(for: recipe).fileSnapshot(
                wineSessionLive: keepLive,
                steamReady: keepSteam,
                steamWindowVisible: keepWindow,
                gameRunning: keepGame
            ),
            activity: activity,
            busy: busy
        )
        detailStatusReady = true
    }

    func handleSelectionChange() {
        error = nil
        detailStatusReady = false
        applySelectedFileStatus()
        refresh()
        refreshInstalled()
    }

    func refresh() {
        guard let library else { return }
        if refreshInFlight {
            refreshAgain = true
            return
        }
        refreshInFlight = true
        let recipe = selected ?? Recipe.onboarding
        let selectedAtStart = selectedID
        let runtime = library.runtime(for: recipe)
        let keepWineLive = snapshot.wineSessionLive
        let keepSteam = snapshot.steamReady
        let keepWindow = snapshot.steamWindowVisible
        let keepGame = snapshot.gameRunning
        DispatchQueue.global(qos: .utility).async {
            let filesOnly = runtime.fileSnapshot(
                wineSessionLive: keepWineLive,
                steamReady: keepSteam,
                steamWindowVisible: keepWindow,
                gameRunning: keepGame
            )
            DispatchQueue.main.async {
                guard self.selectedID == selectedAtStart else { return }
                self.snapshot = LibrarySnapshot.display(filesOnly, activity: self.activity, busy: self.busy)
            }
            let session = runtime.inspectSession()
            DispatchQueue.main.async {
                self.refreshInFlight = false
                defer {
                    if self.refreshAgain {
                        self.refreshAgain = false
                        self.refresh()
                    }
                }
                guard self.selectedID == selectedAtStart else { return }
                self.snapshot = LibrarySnapshot.display(session.0, activity: self.activity, busy: self.busy)
                if session.0.steamIsUp {
                    self.steamUpConfirmations = min(self.steamUpConfirmations + 1, self.steamUpConfirmNeeded)
                } else {
                    self.steamUpConfirmations = 0
                }
                if self.installInProgress || self.uninstallInProgress { return }
                self.applyLaunchProgress(session.1)
            }
        }
    }

    func refreshInstalled() {
        guard let library else { return }
        let recipes = self.recipes
        DispatchQueue.global(qos: .utility).async {
            let ids = Set(
                recipes.compactMap { recipe -> String? in
                    library.runtime(for: recipe).isGameInstalled ? recipe.id : nil
                }
            )
            DispatchQueue.main.async {
                if self.installedIDs != ids { self.installedIDs = ids }
                if let id = self.selectedID, ids.contains(id), !self.snapshot.isInstalled {
                    self.applySelectedFileStatus()
                }
            }
        }
    }

    func applyLaunchProgress(_ progress: SteamLaunchProgress) {
        launchProgress = progress
        if !progress.detail.isEmpty { appendStatus(progress.detail) }
    }

    func run(_ action: LibraryAction) {
        refreshHost()
        guard let library else { return }
        if selected == nil, [.install, .uninstall, .play].contains(action) { return }
        // Cancel install / close Steam: kill the Steam session.
        // Stop while a game is running: kill only the game (Steam stays open).
        if action == .stop, !snapshot.isRunning {
            library.stopAllSessions()
            appendStatus("Stopped Steam.")
            busy = false
            activity = ""
            backgroundReady = true
            refreshInstalled()
            refresh()
            return
        }
        busy = true
        error = nil
        popup = nil
        activity = action.rawValue
        statusLines = []
        appendStatus("Working: \(action.rawValue)")
        backgroundReady = false
        // One raise after the click so Steam shows for install / sign-in / play.
        // Do not keep re-raising — that fights the user when they return to this app.
        if Self.steamFrontActions.contains(action) {
            let wine = library.wine
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                WorkspaceFrontmost().bringToFront(executable: wine)
            }
        }
        let gameID = selected?.id ?? Recipe.onboarding.id
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try library.perform(action, gameID: gameID)
                DispatchQueue.main.async {
                    self.busy = false
                    self.activity = ""
                    self.backgroundReady = true
                    self.applySelectedFileStatus()
                    self.refreshInstalled()
                    self.refresh()
                    let wine = library.wine
                    let raiseGame = action == .play && self.selected?.launchesDirectly == true
                    let gameTitle = self.selected?.title
                    // Defer past UI refresh so Silicon Cellar does not immediately steal focus back.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if raiseGame, let gameTitle {
                            WorkspaceFrontmost().bringGameWindowToFront(
                                executable: wine,
                                windowName: gameTitle,
                                timeout: 5
                            )
                        } else if Self.steamFrontActions.contains(action) {
                            WorkspaceFrontmost().bringToFront(executable: wine)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.busy = false
                    self.activity = ""
                    self.backgroundReady = false
                    self.error = (error as? PortError)?.message ?? error.localizedDescription
                    self.presentPopup(self.error ?? error.localizedDescription, retry: false)
                    self.applySelectedFileStatus()
                    self.refreshInstalled()
                    self.refresh()
                    if Self.steamFrontActions.contains(action) {
                        WorkspaceFrontmost().bringToFront(executable: library.wine)
                    }
                }
            }
        }
    }

    func appendStatus(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, statusLines.last != trimmed else { return }
        statusLines.append(trimmed)
        if statusLines.count > 200 {
            statusLines.removeFirst(statusLines.count - 200)
        }
    }

    var showsStatusBar: Bool {
        if busy || homebrewBusy { return true }
        // Steam is up and idle — hide the log footer (green check is enough).
        if steamIsUpStable { return false }
        return sessionBusy || !statusLines.isEmpty
    }

    func presentPopup(_ message: String, retry: Bool) {
        popup = AppPopup(title: "Error", message: message, retry: retry)
    }

    func dismissPopup() {
        popup = nil
    }
}

struct AppPopup: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let retry: Bool
}

struct LibraryView: View {
    @ObservedObject var model: LibraryModel

    var body: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                List(selection: $model.selectedID) {
                    ForEach(model.recipes) { recipe in
                        HStack(spacing: 8) {
                            Text(recipe.title)
                            Spacer(minLength: 0)
                            if model.installedIDs.contains(recipe.id) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                                    .imageScale(.medium)
                                    .help("Installed")
                            }
                        }
                        .tag(recipe.id)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .pointingHandCursor()
                    }
                }
                .navigationTitle("Silicon Cellar")
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
            } detail: {
                VStack(alignment: .leading, spacing: 16) {
                    if let recipe = model.selected {
                        detailHeader(
                            title: recipe.title,
                            subtitle: "Steam app \(recipe.steamID)"
                        )
                        if model.detailStatusReady {
                            actionSteps(includeGame: true, title: recipe.title)
                        } else {
                            detailStatusLoading
                        }
                    } else {
                        Image(nsImage: AppIcon.image)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 72, height: 72)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if model.detailStatusReady {
                            actionSteps(includeGame: false, title: nil)
                        } else {
                            detailStatusLoading
                        }
                    }
                    Text("This app does not include a game license. Use a Steam account that owns the game.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(24)
            }
            .navigationTitle("Silicon Cellar")
            .toolbar {
                if #available(macOS 26.0, *) {
                    ToolbarItemGroup(placement: .primaryAction) {
                        headerItems
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItemGroup(placement: .primaryAction) {
                        headerItems
                    }
                }
            }
            if model.showsStatusBar {
                StatusBar(lines: model.statusLines, busy: model.sessionBusy)
            }
        }
        .sheet(item: $model.popup) { popup in
            ErrorPopup(
                popup: popup,
                busy: model.busy,
                retry: {
                    model.dismissPopup()
                    model.findWineAgain()
                },
                dismiss: { model.dismissPopup() }
            )
        }
        .onAppear {
            model.start()
            for window in NSApp.windows {
                window.title = "Silicon Cellar"
                window.titleVisibility = .visible
            }
        }
        .onChange(of: model.selectedID) { _, _ in
            model.handleSelectionChange()
        }
    }

    private var detailStatusLoading: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text("Checking install status…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
    }

    @ViewBuilder
    private var headerItems: some View {
        if model.showsSessionProgress {
            sessionProgress
        }
        if !model.showsSessionProgress, model.backgroundReady {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .imageScale(.large)
                .help("Ready")
        }
    }

    @ViewBuilder
    private func actionSteps(includeGame: Bool, title: String?) -> some View {
        Text("Do these steps in order.")
            .font(.title3)
            .foregroundStyle(.secondary)
        if model.snapshot.needsSetup {
            Text(
                title.map {
                    "Install the Steam client for \($0)."
                } ?? "Install the Steam client. Select a game after you sign in."
            )
            .foregroundStyle(.secondary)
        } else if !model.steamIsUpStable {
            Text(
                model.snapshot.wineSessionLive
                    ? "Wait until the Steam window opens."
                    : "Start Steam, then continue with the next steps."
            )
            .foregroundStyle(.secondary)
        } else if !model.snapshot.isSignedIn {
            Text(
                title.map {
                    "Sign in with an account that owns \($0)."
                } ?? "Sign in in the Steam window."
            )
            .foregroundStyle(.secondary)
        } else if !includeGame {
            Text("Steam sign-in is complete. Select a game in the list.")
                .foregroundStyle(.secondary)
        }

        let steamInstalled = !model.snapshot.needsSetup
        let sessionLive = model.snapshot.wineSessionLive
        let steamUp = model.steamIsUpStable
        let steamActionBusy = model.busy && ["steam", "setup"].contains(model.activity)
        // Starting = wineserver live, or Start Steam still in progress.
        let steamStarting = (sessionLive || steamActionBusy) && !steamUp
        let signedIn = model.snapshot.isSignedIn

        if model.snapshot.needsSetup {
            splitStep(
                1,
                status: "Steam is not installed",
                done: false,
                actionTitle: "Install Steam",
                actionColor: StepColor.setup,
                enabled: model.backgroundReady
            ) {
                model.run(.setup)
            }
        } else if steamUp {
            splitStep(
                1,
                status: "Steam is running",
                done: true,
                actionTitle: "Stop Steam",
                actionColor: StepColor.danger,
                enabled: true
            ) {
                model.stopSteamSession()
            }
        } else if steamStarting {
            splitStep(
                1,
                status: "Steam is starting…",
                done: false,
                actionTitle: "Stop Steam",
                actionColor: StepColor.danger,
                enabled: true
            ) {
                model.stopSteamSession()
            }
        } else {
            splitStep(
                1,
                status: "Steam is installed",
                done: true,
                actionTitle: "Start Steam",
                actionColor: StepColor.setup,
                enabled: model.backgroundReady
            ) {
                model.run(.steam)
            }
        }

        if signedIn {
            splitStep(
                2,
                status: "Signed in",
                done: true,
                actionTitle: "Sign out of Steam",
                actionColor: StepColor.danger,
                enabled: steamUp
            ) {
                model.run(.logout)
            }
        } else {
            splitStep(
                2,
                status: "Not signed in",
                done: false,
                actionTitle: "Sign in",
                actionColor: StepColor.signIn,
                enabled: steamInstalled && steamUp && !model.busy
            ) {
                model.run(.steam)
            }
        }

        if includeGame {
            if model.installInProgress || model.snapshot.stage == .downloading {
                splitStep(
                    3,
                    status: "Installing…",
                    done: false,
                    actionTitle: "Install game",
                    actionColor: StepColor.install,
                    enabled: false
                ) {}
                // Stop ends the Steam session and cancels the install — not a running game.
                splitStep(
                    4,
                    status: "Not ready to play",
                    done: false,
                    actionTitle: "Stop Steam",
                    actionColor: StepColor.danger,
                    enabled: true
                ) {
                    model.run(.stop)
                }
            } else if model.uninstallInProgress {
                splitStep(
                    3,
                    status: "Uninstalling…",
                    done: false,
                    actionTitle: "Uninstall",
                    actionColor: StepColor.danger,
                    enabled: false
                ) {}
                splitStep(
                    4,
                    status: "Not ready to play",
                    done: false,
                    actionTitle: "Stop Steam",
                    actionColor: StepColor.danger,
                    enabled: true
                ) {
                    model.run(.stop)
                }
            } else if model.snapshot.isInstalled {
                splitStep(
                    3,
                    status: "Game is installed",
                    done: true,
                    actionTitle: "Uninstall",
                    actionColor: StepColor.danger,
                    enabled: steamUp && signedIn
                ) {
                    model.run(.uninstall)
                }
                if model.snapshot.isRunning {
                    splitStep(
                        4,
                        status: "Game is running",
                        done: true,
                        actionTitle: "Stop",
                        actionColor: StepColor.danger,
                        enabled: true
                    ) {
                        model.run(.stop)
                    }
                } else {
                    splitStep(
                        4,
                        status: steamUp ? "Ready to play" : "Start Steam to play",
                        done: false,
                        actionTitle: "Play",
                        actionColor: StepColor.play,
                        enabled: steamUp
                    ) {
                        model.run(.play)
                    }
                }
            } else {
                let installReady = steamUp && signedIn
                let installHint =
                    installReady
                    ? "Game is not installed"
                    : steamStarting && !steamUp
                        ? "Wait until the Steam window opens"
                        : steamUp
                            ? "Sign in before you install"
                            : "Start Steam before you install"
                splitStep(
                    3,
                    status: installHint,
                    done: false,
                    actionTitle: "Install game",
                    actionColor: StepColor.install,
                    enabled: installReady
                ) {
                    model.run(.install)
                }
                // Stop Steam stays on step 1. Step 4 is play readiness only.
                splitStep(
                    4,
                    status: "Not ready to play",
                    done: false,
                    actionTitle: "Play",
                    actionColor: StepColor.play,
                    enabled: false
                ) {}
            }
        }
    }

    private func detailHeader(title: String, subtitle: String?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.largeTitle.bold())
            if let subtitle {
                Text(subtitle).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let stepFont = Font.title2.weight(.semibold)
    /// Keeps every action label the same width and the same font size.
    private static let widestActionTitle = "Sign out of Steam"

    private func splitStep(
        _ number: Int,
        status: String,
        done: Bool,
        actionTitle: String,
        actionColor: Color,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        let active = enabled && (!model.busy || actionTitle.hasPrefix("Stop") || actionTitle.hasPrefix("Sign out"))
        let statusColor = done ? StepColor.ready : StepColor.pending
        return HStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.title)
                Text("\(number). \(status)")
                    .font(Self.stepFont)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(statusColor, in: SplitEnd(leading: true))

            Button {
                guard active else { return }
                action()
            } label: {
                ZStack {
                    Text(Self.widestActionTitle)
                        .font(Self.stepFont)
                        .hidden()
                        .accessibilityHidden(true)
                    Text(actionTitle)
                        .font(Self.stepFont)
                        .lineLimit(1)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxHeight: .infinity)
                .background(actionColor, in: SplitEnd(leading: false))
                .contentShape(SplitEnd(leading: false))
            }
            .buttonStyle(.plain)
            .allowsHitTesting(active)
            .opacity(active ? 1 : 0.45)
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxHeight: .infinity)
            .pointingHandCursor(active)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var sessionProgress: some View {
        HStack(alignment: .center, spacing: 8) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .trailing, spacing: 2) {
                Text(
                    model.launchProgress.detail.isEmpty
                        ? "Steam is starting."
                        : model.launchProgress.detail
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
                if let fraction = model.launchProgress.fraction {
                    ProgressView(value: fraction)
                        .frame(maxWidth: 120)
                }
                if let fraction = model.snapshot.downloadFraction, model.installInProgress {
                    ProgressView(value: fraction)
                        .frame(maxWidth: 120)
                }
            }
        }
        .help(model.statusLines.last ?? "Steam session")
    }

}

extension View {
    @ViewBuilder
    fileprivate func pointingHandCursor(_ enabled: Bool = true) -> some View {
        if enabled {
            if #available(macOS 15.0, *) {
                pointerStyle(.link)
            } else {
                onHover { hovering in
                    if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
                }
            }
        } else {
            self
        }
    }
}

private struct SplitEnd: Shape {
    var leading: Bool

    func path(in rect: CGRect) -> Path {
        let radius = rect.height / 2
        let corners = RectangleCornerRadii(
            topLeading: leading ? radius : 0,
            bottomLeading: leading ? radius : 0,
            bottomTrailing: leading ? 0 : radius,
            topTrailing: leading ? 0 : radius
        )
        return UnevenRoundedRectangle(cornerRadii: corners, style: .circular).path(in: rect)
    }
}

private enum StepColor {
    static let setup = Color(red: 0.16, green: 0.40, blue: 0.78)
    static let ready = Color(red: 0.10, green: 0.40, blue: 0.24)
    static let pending = Color(white: 0.28)
    static let signIn = Color(red: 0.30, green: 0.24, blue: 0.66)
    static let install = Color(red: 0.12, green: 0.46, blue: 0.26)
    static let play = Color(red: 0.10, green: 0.34, blue: 0.46)
    static let danger = Color(red: 0.70, green: 0.16, blue: 0.16)
}

struct StatusBar: View {
    let lines: [String]
    let busy: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if busy {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                }
                .onChange(of: lines.count) { _, count in
                    guard count > 0 else { return }
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120, alignment: .topLeading)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

struct ErrorPopup: View {
    let popup: AppPopup
    let busy: Bool
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(popup.title)
                .font(.title2.bold())
            ScrollView {
                Text(popup.message)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("OK") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                if popup.retry {
                    Button("Try again") { retry() }
                        .disabled(busy)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 520, idealWidth: 640, minHeight: 240, idealHeight: 320)
    }
}
