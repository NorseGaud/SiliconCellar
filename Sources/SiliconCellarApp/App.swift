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

    var selected: Recipe? { recipes.first { $0.id == selectedID } }
    var sessionBusy: Bool { busy || homebrewBusy || snapshot.wineSessionLive }

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
    var showsSessionProgress: Bool {
        snapshot.wineSessionLive || sessionBusy || !launchProgress.detail.isEmpty
    }

    /// Sync disk status for the selected game so steps do not flash the wrong action.
    func applySelectedFileStatus() {
        guard let library else {
            detailStatusReady = false
            return
        }
        let recipe = selected ?? Recipe.onboarding
        let keepLive = snapshot.wineSessionLive
        let keepGame = snapshot.gameRunning
        snapshot = LibrarySnapshot.display(
            library.runtime(for: recipe).fileSnapshot(wineSessionLive: keepLive, gameRunning: keepGame),
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
        let keepGame = snapshot.gameRunning
        DispatchQueue.global(qos: .utility).async {
            let filesOnly = runtime.fileSnapshot(wineSessionLive: keepWineLive, gameRunning: keepGame)
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
                    if action == .play, let selected = self.selected, selected.launchesDirectly {
                        WorkspaceFrontmost().bringGameWindowToFront(
                            executable: library.wine,
                            windowName: selected.title,
                            timeout: 5
                        )
                    } else if [.steam, .play, .setup, .install].contains(action) {
                        WorkspaceFrontmost().bringToFront(executable: library.wine)
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

    var showsStatusBar: Bool { sessionBusy || !statusLines.isEmpty }

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
        } else if !model.snapshot.isSignedIn {
            Text(
                title.map {
                    "Open Steam and sign in with an account that owns \($0)."
                } ?? "Open Steam and sign in in the Steam window."
            )
            .foregroundStyle(.secondary)
        } else if !includeGame {
            Text("Steam sign-in is complete. Select a game in the list.")
                .foregroundStyle(.secondary)
        }

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
        } else if model.snapshot.wineSessionLive {
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

        if model.snapshot.isSignedIn {
            splitStep(
                2,
                status: "Signed in",
                done: true,
                actionTitle: "Sign out of Steam",
                actionColor: StepColor.danger,
                enabled: true
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
                enabled: !model.snapshot.needsSetup && !model.busy
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
                splitStep(
                    4,
                    status: "Game is not running",
                    done: false,
                    actionTitle: "Stop",
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
                    status: "Game is not running",
                    done: false,
                    actionTitle: "Stop",
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
                    enabled: true
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
                        status: "Ready to play",
                        done: false,
                        actionTitle: "Play",
                        actionColor: StepColor.play,
                        enabled: true
                    ) {
                        model.run(.play)
                    }
                }
            } else {
                splitStep(
                    3,
                    status: "Game is not installed",
                    done: false,
                    actionTitle: "Install game",
                    actionColor: StepColor.install,
                    enabled: model.snapshot.isSignedIn
                ) {
                    model.run(.install)
                }
                if model.snapshot.wineSessionLive {
                    splitStep(
                        4,
                        status: "Game is not running",
                        done: false,
                        actionTitle: "Stop",
                        actionColor: StepColor.danger,
                        enabled: true
                    ) {
                        model.run(.stop)
                    }
                } else {
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
            if model.sessionBusy || model.snapshot.wineSessionLive {
                ProgressView()
                    .controlSize(.small)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(
                    model.launchProgress.detail.isEmpty
                        ? "Steam is running."
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
