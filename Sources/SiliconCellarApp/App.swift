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
    private var launcherUpConfirmations = 0
    private let launcherUpConfirmNeeded = 3
    private var gameWasRunning = false
    /// True from the click until `library.perform` returns. Stop can end `busy` only when this is false.
    private var actionInFlight = false

    var selected: Recipe? { recipes.first { $0.id == selectedID } }
    /// The launcher of the selected game. Steam when no game is selected (onboarding).
    var launcherName: String { (selected?.launcherKind ?? .steam).displayName }
    /// Stable Steam-up for buttons/labels — ignores brief false-positive polls.
    var launcherIsUpStable: Bool { launcherUpConfirmations >= launcherUpConfirmNeeded }
    /// True while an action runs, or while Steam is still starting (no window yet).
    var sessionBusy: Bool {
        busy || homebrewBusy || (snapshot.wineSessionLive && !launcherIsUpStable)
    }

    func stopWineSessions() {
        timer?.invalidate()
        timer = nil
        library?.stopAllSessions()
        SystemChrome.showMenuBarAndDock()
    }

    /// Close the launcher of the selected game (Steam when no game is selected). The other launcher keeps running.
    func stopLauncherSession() {
        try? library?.stopSession(gameID: selected?.id ?? Recipe.onboarding.id)
        appendStatus("Stopped \(launcherName).")
        // An action that waits for the launcher ends at its next poll, then `run` ends the busy state.
        if !actionInFlight { endAction() }
        SystemChrome.showMenuBarAndDock()
        refreshInstalled()
        refresh()
    }

    private func endAction() {
        actionInFlight = false
        busy = false
        activity = ""
        backgroundReady = hostMessage == nil
    }

    /// Saves the launcher for the selected game, then shows the steps of that launcher.
    func chooseLauncher(_ launcher: Launcher) {
        guard let library, let recipe = selected, recipe.launcherKind != launcher else { return }
        do {
            try library.setLauncher(launcher, gameID: recipe.id)
        } catch {
            presentPopup((error as? PortError)?.message ?? error.localizedDescription, retry: false)
            return
        }
        recipes = recipes.map { $0.id == recipe.id ? $0.using(launcher) : $0 }
        launcherUpConfirmations = 0
        appendStatus("\(recipe.title) uses \(launcher.displayName).")
        handleSelectionChange()
    }

    /// Actions that show Steam UI after the user clicks (install, sign-in, play, …).
    private static let launcherFrontActions: Set<LibraryAction> = [
        .setup, .steam, .install, .uninstall, .logout, .play,
    ]

    func start() {
        do {
            let executableDirectory = Bundle.main.bundleURL
                .appendingPathComponent("Contents/MacOS")
            let store = RecipeStore.standard(executableDirectory: executableDirectory)
            recipes = try store.loadAll()
            selectedID = nil
            refreshHost()
            if let library { recipes = recipes.map(library.applyingLauncherChoice) }
            library?.removeLegacyData()
            WineTerminal.closeStagingSessions()
            applySelectedFileStatus()
            refresh()
            refreshInstalled()
            backgroundReady = hostMessage == nil
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

    var installInProgress: Bool { busy && activity == "install" && !snapshot.isInstalled }
    var uninstallInProgress: Bool { busy && activity == "uninstall" }
    /// Spinner + status text while Steam is starting or work is in progress — not when Steam is idle and up.
    var showsSessionProgress: Bool {
        if busy || homebrewBusy { return true }
        if !launchProgress.detail.isEmpty { return true }
        if snapshot.wineSessionLive, !launcherIsUpStable { return true }
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
        let keepSteam = snapshot.launcherReady
        let keepWindow = snapshot.launcherWindowVisible
        let keepGame = snapshot.gameRunning
        snapshot = LibrarySnapshot.display(
            library.runtime(for: recipe).fileSnapshot(
                wineSessionLive: keepLive,
                launcherReady: keepSteam,
                launcherWindowVisible: keepWindow,
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
        let keepSteam = snapshot.launcherReady
        let keepWindow = snapshot.launcherWindowVisible
        let keepGame = snapshot.gameRunning
        DispatchQueue.global(qos: .utility).async {
            let filesOnly = runtime.fileSnapshot(
                wineSessionLive: keepWineLive,
                launcherReady: keepSteam,
                launcherWindowVisible: keepWindow,
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
                // Window visibility flickers when you switch apps or a game covers Steam.
                // Once Steam was confirmed up, keep it up while the client process stays ready.
                if !session.0.launcherReady {
                    self.launcherUpConfirmations = 0
                } else if session.0.launcherWindowVisible {
                    self.launcherUpConfirmations = min(
                        self.launcherUpConfirmations + 1,
                        self.launcherUpConfirmNeeded
                    )
                }
                if self.gameWasRunning, !session.0.isRunning {
                    SystemChrome.showMenuBarAndDock()
                }
                self.gameWasRunning = session.0.isRunning
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
        // Cancel install / close the launcher: kill the session of that launcher.
        // Stop while a game is running: kill only the game (the launcher stays open).
        if action == .stop, !snapshot.isRunning {
            stopLauncherSession()
            return
        }
        busy = true
        actionInFlight = true
        error = nil
        popup = nil
        activity = action.rawValue
        statusLines = []
        appendStatus("Working: \(action.rawValue)")
        backgroundReady = false
        // One raise after the click so Steam shows for install / sign-in / play.
        // Do not keep re-raising — that fights the user when they return to this app.
        if Self.launcherFrontActions.contains(action) {
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
                    self.endAction()
                    self.applySelectedFileStatus()
                    self.refreshInstalled()
                    self.refresh()
                    let wine = library.wine
                    let raiseGame = action == .play && self.selected?.launchesDirectly == true
                    let gameTitle = self.selected?.title
                    // Defer past UI refresh so Silicon Cellar does not immediately steal focus back.
                    // Raise on a background queue — a sync poll on main freezes the Play button.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if raiseGame, let gameTitle {
                            DispatchQueue.global(qos: .userInitiated).async {
                                WorkspaceFrontmost().bringGameWindowToFront(
                                    executable: wine,
                                    windowName: gameTitle,
                                    timeout: 15
                                )
                            }
                        } else if Self.launcherFrontActions.contains(action) {
                            WorkspaceFrontmost().bringToFront(executable: wine)
                        }
                    }
                }
            } catch is LauncherStopped {
                DispatchQueue.main.async {
                    self.endAction()
                    self.applySelectedFileStatus()
                    self.refreshInstalled()
                    self.refresh()
                }
            } catch let licenseRequired as AppleLicenseRequired {
                DispatchQueue.main.async {
                    self.endAction()
                    self.popup = AppPopup(
                        title: "Apple D3DMetal licence",
                        message: licenseRequired.message,
                        retry: false,
                        appleLicenseFile: licenseRequired.licenseFile
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.endAction()
                    self.error = (error as? PortError)?.message ?? error.localizedDescription
                    self.presentPopup(self.error ?? error.localizedDescription, retry: false)
                    self.applySelectedFileStatus()
                    self.refreshInstalled()
                    self.refresh()
                    if Self.launcherFrontActions.contains(action) {
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
        if launcherIsUpStable { return false }
        return sessionBusy || !statusLines.isEmpty
    }

    func presentPopup(_ message: String, retry: Bool) {
        popup = AppPopup(title: "Error", message: message, retry: retry)
    }

    func dismissPopup() {
        popup = nil
    }

    func acceptAppleLicenseAndPlay() {
        popup = nil
        guard let library, let gameID = selected?.id else { return }
        do {
            try library.perform(.acceptAppleLicense, gameID: gameID)
        } catch {
            presentPopup((error as? PortError)?.message ?? error.localizedDescription, retry: false)
            return
        }
        run(.play)
    }
}

struct AppPopup: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String
    let retry: Bool
    var appleLicenseFile: URL?
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
                            subtitle: recipe.launcherKind == .steam ? "Steam app \(recipe.steamAppID)" : recipe.launcherKind.displayName
                        )
                        if recipe.supportedLaunchers.count > 1 {
                            launcherPicker(for: recipe)
                        }
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
                    Text("This app does not include a game license. Use a \(model.launcherName) account that owns the game.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if model.selected?.launcherKind == .battleNet {
                        Text(
                            "Bought the game on Steam? Link your Steam account to your Battle.net account to see it in Battle.net: sign in at [account.battle.net](https://account.battle.net), then open Account Settings > Connections > Steam."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
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
            if let licenseFile = popup.appleLicenseFile {
                AppleLicensePopup(
                    licenseFile: licenseFile,
                    accept: { model.acceptAppleLicenseAndPlay() },
                    decline: { model.dismissPopup() }
                )
            } else {
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
        let launcherName = model.launcherName
        Text("Do these steps in order.")
            .font(.title3)
            .foregroundStyle(.secondary)
        if model.snapshot.needsSetup {
            Text(
                title.map {
                    "Install the \(launcherName) client for \($0)."
                } ?? "Install the Steam client. Select a game after you sign in."
            )
            .foregroundStyle(.secondary)
        } else if !model.launcherIsUpStable {
            Text(
                model.snapshot.wineSessionLive
                    ? "Wait until the \(launcherName) window opens."
                    : "Start \(launcherName), then continue with the next steps."
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

        let launcherInstalled = !model.snapshot.needsSetup
        let sessionLive = model.snapshot.wineSessionLive
        let launcherUp = model.launcherIsUpStable
        let launcherActionBusy = model.busy && ["steam", "setup"].contains(model.activity)
        // Starting = wineserver live, or Start Steam still in progress.
        let launcherStarting = (sessionLive || launcherActionBusy) && !launcherUp
        let signedIn = model.snapshot.isSignedIn

        if model.snapshot.needsSetup {
            splitStep(
                1,
                status: "\(launcherName) is not installed",
                done: false,
                actionTitle: "Install \(launcherName)",
                actionColor: StepColor.setup,
                enabled: model.backgroundReady
            ) {
                model.run(.setup)
            }
        } else if launcherUp {
            splitStep(
                1,
                status: "\(launcherName) is running",
                done: true,
                actionTitle: "Stop \(launcherName)",
                actionColor: StepColor.danger,
                enabled: true
            ) {
                model.stopLauncherSession()
            }
        } else if launcherStarting {
            splitStep(
                1,
                status: "\(launcherName) is starting…",
                done: false,
                actionTitle: "Stop \(launcherName)",
                actionColor: StepColor.danger,
                enabled: true
            ) {
                model.stopLauncherSession()
            }
        } else {
            splitStep(
                1,
                status: "\(launcherName) is installed",
                done: true,
                actionTitle: "Start \(launcherName)",
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
                actionTitle: "Sign out of \(launcherName)",
                actionColor: StepColor.danger,
                enabled: launcherUp
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
                enabled: launcherInstalled && launcherUp && !model.busy
            ) {
                model.run(.steam)
            }
        }

        if includeGame {
            if model.installInProgress || model.snapshot.stage == .downloading {
                // Stop ends the launcher session and cancels the install — not a running game.
                splitStep(
                    3,
                    status: "Installing…",
                    done: false,
                    actionTitle: "Cancel install",
                    actionColor: StepColor.danger,
                    enabled: true
                ) {
                    model.run(.stop)
                }
                splitStep(
                    4,
                    status: "Not ready to play",
                    done: false,
                    actionTitle: "Play",
                    actionColor: StepColor.play,
                    enabled: false
                ) {}
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
                    actionTitle: "Play",
                    actionColor: StepColor.play,
                    enabled: false
                ) {}
            } else if model.snapshot.isInstalled {
                splitStep(
                    3,
                    status: "Game is installed",
                    done: true,
                    actionTitle: "Uninstall",
                    actionColor: StepColor.danger,
                    enabled: launcherUp && signedIn
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
                        status: launcherUp ? "Ready to play" : "Start \(launcherName) to play",
                        done: false,
                        actionTitle: "Play",
                        actionColor: StepColor.play,
                        enabled: launcherUp
                    ) {
                        model.run(.play)
                    }
                }
            } else {
                let installReady = launcherUp && signedIn
                let installHint =
                    installReady
                    ? "Game is not installed"
                    : launcherStarting && !launcherUp
                        ? "Wait until the \(launcherName) window opens"
                        : launcherUp
                            ? "Sign in before you install"
                            : "Start \(launcherName) before you install"
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

    /// Steam or Battle.net, for a game that both sell. Each launcher has its own install of the game.
    private func launcherPicker(for recipe: Recipe) -> some View {
        Picker(
            "Launcher",
            selection: Binding(get: { recipe.launcherKind }, set: { model.chooseLauncher($0) })
        ) {
            ForEach(recipe.supportedLaunchers, id: \.self) { launcher in
                Text(launcher.displayName).tag(launcher)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize()
        .disabled(model.busy || model.snapshot.isRunning)
        .help("Use the launcher of the store where you bought the game. Each launcher installs its own copy.")
    }

    private static let stepFont = Font.title2.weight(.semibold)
    /// Keeps every action label the same width and the same font size.
    private static let widestActionTitle = "Sign out of Battle.net"

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

    /// The toolbar text. A game download beats the launcher log, and the log beats "starting".
    private var sessionProgressText: String {
        if model.installInProgress, let fraction = model.snapshot.downloadFraction {
            return "Downloading \(model.selected?.title ?? "the game")… \(Int((fraction * 100).rounded()))%"
        }
        if !model.launchProgress.detail.isEmpty { return model.launchProgress.detail }
        if model.installInProgress { return "Download is starting." }
        return "\(model.launcherName) is starting."
    }

    @ViewBuilder
    private var sessionProgress: some View {
        HStack(alignment: .center, spacing: 8) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .trailing, spacing: 2) {
                Text(sessionProgressText)
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
        .help(model.statusLines.last ?? "\(model.launcherName) session")
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

struct AppleLicensePopup: View {
    let licenseFile: URL
    let accept: () -> Void
    let decline: () -> Void

    private static let summary = """
        This game uses D3DMetal from Apple's Game Porting Toolkit. Read and accept Apple's licence to play. \
        You can use D3DMetal only to develop, test, or evaluate games, and only for non-commercial purposes.
        """

    private var licenseText: String {
        guard
            let data = try? Data(contentsOf: licenseFile),
            let text = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
        else { return "Could not read \(licenseFile.path)." }
        return text.string
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Apple D3DMetal licence")
                .font(.title2.bold())
            Text(Self.summary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                Text(licenseText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .border(.separator)
            HStack {
                Spacer()
                Button("Decline") { decline() }
                    .keyboardShortcut(.cancelAction)
                Button("Accept and Play") { accept() }
            }
        }
        .padding(24)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 480, idealHeight: 620)
    }
}
