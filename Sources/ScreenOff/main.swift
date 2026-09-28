import AppKit
import Combine
import CoreGraphics
import Darwin
import IOKit
import IOKit.pwr_mgt
import SwiftUI

private let interfaceLanguageDefaultsKey = "interfaceLanguage"

private func effectiveLocalizationID() -> String {
    let selected = UserDefaults.standard.string(forKey: interfaceLanguageDefaultsKey) ?? "system"
    if selected == "zh-Hans" || selected == "en" { return selected }
    let preferred = Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en"
    return preferred.lowercased().hasPrefix("zh") ? "zh-Hans" : "en"
}

private func localizationBundle() -> Bundle {
    let languageID = effectiveLocalizationID()
    guard let path = Bundle.main.path(forResource: languageID, ofType: "lproj"),
          let bundle = Bundle(path: path) else { return .main }
    return bundle
}

private func localized(_ key: String) -> String {
    localizationBundle().localizedString(forKey: key, value: key, table: nil)
}

private func localizedFormat(_ key: String, _ arguments: CVarArg...) -> String {
    String(format: localized(key), locale: Locale(identifier: effectiveLocalizationID()), arguments: arguments)
}

@MainActor
final class LanguageSettings: ObservableObject {
    @Published var selection: String {
        didSet { UserDefaults.standard.set(selection, forKey: interfaceLanguageDefaultsKey) }
    }

    init() {
        selection = UserDefaults.standard.string(forKey: interfaceLanguageDefaultsKey) ?? "system"
    }

    var locale: Locale { Locale(identifier: effectiveLocalizationID()) }
}

struct PowerHold: Identifiable {
    let id = UUID()
    let appName: String
    let pid: pid_t
    let type: String
    let assertionName: String
    let preventsDisplaySleep: Bool

    var readableReason: String {
        preventsDisplaySleep ? localized("正在阻止显示器自动熄灭") : localized("正在阻止电脑自动睡眠")
    }
}

@MainActor
final class ScreenSleepModel: ObservableObject {
    @Published private(set) var holds: [PowerHold] = []
    @Published private(set) var countdown: TimeInterval?
    @Published private(set) var message = localized("正在读取电源断言…")
    @Published private(set) var isKeepingAwakeAfterDisplayOff = false
    @Published var selectedMinutes = 30
    @Published var inactivityAutoOffEnabled: Bool {
        didSet {
            UserDefaults.standard.set(inactivityAutoOffEnabled, forKey: "inactivityAutoOffEnabled")
            if !inactivityAutoOffEnabled {
                hasClosedForCurrentIdlePeriod = false
            } else if isScreenLocked && lockScreenAutoOff && !hasClosedForCurrentLock {
                hasClosedForCurrentLock = true
                turnOffDisplayAutomatically()
            }
        }
    }
    @Published var lockScreenAutoOff: Bool {
        didSet {
            UserDefaults.standard.set(lockScreenAutoOff, forKey: "lockScreenAutoOff")
            if inactivityAutoOffEnabled && lockScreenAutoOff && isScreenLocked && !hasClosedForCurrentLock {
                hasClosedForCurrentLock = true
                turnOffDisplayAutomatically()
            }
        }
    }
    @Published var preventSleepAfterAutomaticOff: Bool {
        didSet {
            UserDefaults.standard.set(preventSleepAfterAutomaticOff, forKey: "preventSleepAfterAutomaticOff")
            if !preventSleepAfterAutomaticOff && keepAwakeAssertionSource == .automatic {
                releaseKeepAwakeAssertion(updateMessage: false)
            }
        }
    }
    @Published var inactivitySeconds: Int {
        didSet { UserDefaults.standard.set(inactivitySeconds, forKey: "inactivitySeconds") }
    }
    @Published private(set) var isScreenLocked = false

    private var refreshTimer: Timer?
    private var countdownTimer: Timer?
    private var inactivityTimer: Timer?
    private var keepAwakeAssertionID: IOPMAssertionID?
    private var keepAwakeAssertionSource: KeepAwakeAssertionSource?
    private var lockNotificationTokens: [NSObjectProtocol] = []
    private var hasClosedForCurrentLock = false
    private var hasClosedForCurrentIdlePeriod = false

    private enum KeepAwakeAssertionSource {
        case manual
        case automatic
    }

    init() {
        let defaults = UserDefaults.standard
        inactivityAutoOffEnabled = defaults.object(forKey: "inactivityAutoOffEnabled") as? Bool ?? false
        lockScreenAutoOff = defaults.object(forKey: "lockScreenAutoOff") as? Bool ?? false
        preventSleepAfterAutomaticOff = defaults.object(forKey: "preventSleepAfterAutomaticOff") as? Bool ?? false
        inactivitySeconds = defaults.object(forKey: "inactivitySeconds") as? Int ?? 300
        isScreenLocked = Self.readScreenLockedState()
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: true) { [weak self] _ in
            guard let model = self else { return }
            Task { @MainActor in model.refresh() }
        }
        observeLockState()
        inactivityTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let model = self else { return }
            Task { @MainActor in model.checkInactivity() }
        }
        if inactivityAutoOffEnabled && lockScreenAutoOff && isScreenLocked {
            hasClosedForCurrentLock = true
            turnOffDisplayAutomatically()
        }
    }

    var displayHolds: [PowerHold] { holds.filter(\.preventsDisplaySleep) }
    var systemSleepHolds: [PowerHold] { holds.filter { !$0.preventsDisplaySleep } }

    var countdownText: String? {
        guard let countdown else { return nil }
        let seconds = max(0, Int(countdown.rounded(.up)))
        return String(format: "%02d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    func refresh() {
        var raw: Unmanaged<CFDictionary>?
        let result = IOPMCopyAssertionsByProcess(&raw)
        guard result == kIOReturnSuccess, let dictionary = raw?.takeRetainedValue() else {
            holds = []
            message = localizedFormat("无法读取系统电源断言（错误码 %d）", result)
            return
        }

        var found: [PowerHold] = []
        let entries = dictionary as NSDictionary
        for (key, value) in entries {
            guard let number = key as? NSNumber, let assertions = value as? [[String: Any]] else { continue }
            let pid = number.int32Value
            let appName = processName(pid_t(pid))

            for assertion in assertions {
                guard let level = assertion[kIOPMAssertionLevelKey as String] as? NSNumber, level.intValue != 0,
                      let type = assertion[kIOPMAssertionTypeKey as String] as? String else { continue }
                let isDisplay = type == (kIOPMAssertionTypePreventUserIdleDisplaySleep as String)
                    || type == (kIOPMAssertionTypeNoDisplaySleep as String)
                let isSystemSleep = type == (kIOPMAssertionTypePreventUserIdleSystemSleep as String)
                guard isDisplay || isSystemSleep else { continue }
                let name = assertion[kIOPMAssertionNameKey as String] as? String ?? localized("（未提供用途）")
                found.append(PowerHold(
                    appName: appName,
                    pid: pid_t(pid),
                    type: isDisplay ? "阻止屏幕熄灭" : "阻止电脑自动睡眠",
                    assertionName: name,
                    preventsDisplaySleep: isDisplay
                ))
            }
        }
        holds = found.sorted {
            if $0.preventsDisplaySleep != $1.preventsDisplaySleep { return $0.preventsDisplaySleep }
            return $0.appName.localizedCaseInsensitiveCompare($1.appName) == .orderedAscending
        }
        message = localized("已更新 · 每 8 秒自动刷新")
    }

    func turnOffDisplay() {
        _ = requestDisplayOff()
    }

    func turnOffDisplayAndPreventSleep() {
        let createdAssertion = keepAwakeAssertionID == nil
        guard acquireKeepAwakeAssertion(source: .manual) else { return }
        if !requestDisplayOff(), createdAssertion {
            releaseKeepAwakeAssertion(updateMessage: false)
        }
    }

    func allowSystemSleep() {
        releaseKeepAwakeAssertion(updateMessage: true)
    }

    func turnOffDisplayAutomatically() {
        let shouldPreventSleep = preventSleepAfterAutomaticOff
        let createdAssertion = shouldPreventSleep && keepAwakeAssertionID == nil
        if shouldPreventSleep && !acquireKeepAwakeAssertion(source: .automatic) {
            let assertionError = message
            if requestDisplayOff() {
                message = localizedFormat("已请求 macOS 关闭显示器；防止自动睡眠未能开启（%@）", assertionError)
            }
            return
        }

        if !requestDisplayOff(), createdAssertion {
            releaseKeepAwakeAssertion(updateMessage: false)
        }
    }

    @discardableResult
    private func requestDisplayOff() -> Bool {
        message = localized("正在关闭显示器…")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                message = localized("已请求 macOS 关闭显示器")
                return true
            } else {
                message = localizedFormat("关闭失败，pmset 状态码：%d", process.terminationStatus)
                return false
            }
        } catch {
            message = localizedFormat("无法运行 pmset：%@", error.localizedDescription)
            return false
        }
    }

    private func acquireKeepAwakeAssertion(source: KeepAwakeAssertionSource) -> Bool {
        if keepAwakeAssertionID != nil {
            if source == .manual { keepAwakeAssertionSource = .manual }
            return true
        }

        var assertionID: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            localized("屏幕管理：关闭显示器并保持电脑运行") as CFString,
            &assertionID
        )
        guard result == kIOReturnSuccess else {
            message = localizedFormat("无法阻止电脑自动睡眠（错误码 %d）", result)
            return false
        }
        keepAwakeAssertionID = assertionID
        keepAwakeAssertionSource = source
        isKeepingAwakeAfterDisplayOff = true
        return true
    }

    private func releaseKeepAwakeAssertion(updateMessage: Bool) {
        guard let assertionID = keepAwakeAssertionID else { return }
        let result = IOPMAssertionRelease(assertionID)
        keepAwakeAssertionID = nil
        keepAwakeAssertionSource = nil
        isKeepingAwakeAfterDisplayOff = false
        if updateMessage {
            message = result == kIOReturnSuccess
                ? localized("已恢复系统自动睡眠")
                : localizedFormat("释放防睡眠断言失败（错误码 %d）", result)
        }
    }

    func startCountdown() {
        countdownTimer?.invalidate()
        countdown = TimeInterval(selectedMinutes * 60)
        message = selectedMinutes == 1
            ? localized("将在 1 分钟后关闭显示器")
            : localizedFormat("将在 %ld 分钟后关闭显示器", selectedMinutes)
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let model = self else { timer.invalidate(); return }
            Task { @MainActor in
                guard let remaining = model.countdown else {
                    model.countdownTimer?.invalidate()
                    model.countdownTimer = nil
                    return
                }
                if remaining <= 1 {
                    model.countdownTimer?.invalidate()
                    model.countdownTimer = nil
                    model.countdown = nil
                    model.turnOffDisplayAutomatically()
                } else {
                    model.countdown = remaining - 1
                }
            }
        }
    }

    func cancelCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdown = nil
        message = localized("已取消定时关闭")
    }

    func terminateProcesses(for requestedHolds: [PowerHold], force: Bool) {
        let targets = uniqueProcesses(in: requestedHolds)
        guard !targets.isEmpty else { return }

        // Refresh before signaling so a stale row cannot act on a PID that has been reused.
        refresh()
        let currentPIDs = Set(holds.map(\.pid))
        let activeTargets = targets.filter { currentPIDs.contains($0.pid) }
        guard !activeTargets.isEmpty else {
            message = localized("所选进程已不再持有电源断言，列表已更新")
            return
        }

        var acceptedPIDs = Set<pid_t>()
        var applications: [pid_t: NSRunningApplication] = [:]
        for hold in activeTargets {
            let accepted: Bool
            if let application = NSRunningApplication(processIdentifier: hold.pid) {
                applications[hold.pid] = application
                accepted = force ? application.forceTerminate() : application.terminate()
            } else {
                accepted = Darwin.kill(hold.pid, force ? SIGKILL : SIGTERM) == 0
            }
            if accepted { acceptedPIDs.insert(hold.pid) }
        }

        let acceptedCount = acceptedPIDs.count
        let failedCount = activeTargets.count - acceptedCount
        guard acceptedCount > 0 else {
            message = localized("系统未能结束所选进程，请检查权限或进程状态")
            refresh()
            return
        }

        message = force
            ? localizedFormat("已向 %ld 个进程发送强制结束请求", acceptedCount)
            : localizedFormat("已向 %ld 个进程请求正常退出", acceptedCount)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            let stillRunning = acceptedPIDs.filter { pid in
                if let application = applications[pid] { return !application.isTerminated }
                return Darwin.kill(pid, 0) == 0 || errno == EPERM
            }.count
            self.refresh()
            if stillRunning == 0 {
                self.message = failedCount > 0
                    ? localizedFormat("已关闭 %ld 个进程，%ld 个请求失败", acceptedCount, failedCount)
                    : localizedFormat("已关闭 %ld 个进程", acceptedCount)
            } else {
                self.message = localizedFormat("%ld 个进程仍在运行，可重试或强制结束", stillRunning)
            }
        }
    }

    private func uniqueProcesses(in source: [PowerHold]) -> [PowerHold] {
        var seen = Set<pid_t>()
        return source.filter { seen.insert($0.pid).inserted }
    }

    private func checkInactivity() {
        guard inactivityAutoOffEnabled else {
            hasClosedForCurrentIdlePeriod = false
            return
        }
        // CoreGraphics exposes kCGAnyInputEventType as a C macro, not a Swift-imported symbol.
        let anyInputEventType = unsafeBitCast(UInt32.max, to: CGEventType.self)
        let idleSeconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInputEventType
        )
        if idleSeconds < Double(inactivitySeconds) {
            hasClosedForCurrentIdlePeriod = false
        } else if !hasClosedForCurrentIdlePeriod {
            hasClosedForCurrentIdlePeriod = true
            turnOffDisplayAutomatically()
        }
    }

    private func observeLockState() {
        let center = DistributedNotificationCenter.default()
        let locked = center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let model = self else { return }
            Task { @MainActor in model.setScreenLocked(true) }
        }
        let unlocked = center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            guard let model = self else { return }
            Task { @MainActor in model.setScreenLocked(false) }
        }
        lockNotificationTokens = [locked, unlocked]
    }

    private func setScreenLocked(_ locked: Bool) {
        guard isScreenLocked != locked else { return }
        isScreenLocked = locked
        if locked {
            hasClosedForCurrentLock = false
            if inactivityAutoOffEnabled && lockScreenAutoOff {
                hasClosedForCurrentLock = true
                turnOffDisplayAutomatically()
            }
        } else {
            hasClosedForCurrentLock = false
            hasClosedForCurrentIdlePeriod = false
        }
    }

    private static func readScreenLockedState() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}

private func processName(_ pid: pid_t) -> String {
    if let name = NSRunningApplication(processIdentifier: pid)?.localizedName,
       !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return name
    }

    var buffer = [CChar](repeating: 0, count: 4_096)
    let count = proc_name(pid, &buffer, UInt32(buffer.count))
    if count > 0 {
        let name = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
    }

    if let executableURL = processExecutableURL(pid) {
        let executable = executableURL.lastPathComponent
        if !executable.isEmpty { return executable }
    }
    return localizedFormat("PID %d（名称不可读）", pid)
}

private func processExecutableURL(_ pid: pid_t) -> URL? {
    var buffer = [CChar](repeating: 0, count: 4_096)
    let pathLength = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard pathLength > 0 else { return nil }
    return URL(fileURLWithPath: String(cString: buffer))
}

@MainActor
final class MenuBarController: NSObject {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let model = ScreenSleepModel()
    private let languageSettings = LanguageSettings()
    private var processInfoWindows: [pid_t: ProcessInfoWindowController] = [:]
    private var inactiveObserver: NSObjectProtocol?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?

    override init() {
        super.init()
        popover.contentSize = NSSize(width: 390, height: 760)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ScreenOffView(
            model: model,
            languageSettings: languageSettings,
            closeAndTurnOff: { [weak self] in
                self?.closePopover()
                self?.model.turnOffDisplay()
            },
            closeAndKeepAwake: { [weak self] in
                self?.closePopover()
                self?.model.turnOffDisplayAndPreventSleep()
            },
            exitApp: { NSApp.terminate(nil) },
            showProcessInfo: { [weak self] hold in self?.showProcessInfo(for: hold) },
            revealProcessInFinder: { [weak self] hold in self?.revealProcessInFinder(hold) }
        ))
        inactiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            guard let appDelegate = self else { return }
            Task { @MainActor in appDelegate.hideApplicationWindows() }
        }
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
            guard let appDelegate = self else { return }
            Task { @MainActor in appDelegate.hideApplicationWindows() }
        }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            guard let appDelegate = self else { return }
            Task { @MainActor in appDelegate.hideApplicationWindows() }
        }
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display", accessibilityDescription: localized("屏幕管理"))
            button.toolTip = localized("屏幕管理：查看常亮来源、设置自动关闭")
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { closePopover() } else if let button = statusItem.button { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
    }

    private func closePopover() { popover.performClose(nil) }

    private func hideApplicationWindows() {
        closePopover()
        processInfoWindows.values.forEach { $0.hideWindow() }
    }

    private func showProcessInfo(for hold: PowerHold) {
        closePopover()
        let controller: ProcessInfoWindowController
        if let existing = processInfoWindows[hold.pid] {
            controller = existing
            controller.update(hold: hold)
        } else {
            controller = ProcessInfoWindowController(hold: hold, languageSettings: languageSettings) { [weak self] in
                self?.revealProcessInFinder(hold)
            }
            processInfoWindows[hold.pid] = controller
        }
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func revealProcessInFinder(_ hold: PowerHold) {
        let url = NSRunningApplication(processIdentifier: hold.pid)?.bundleURL
            ?? processExecutableURL(hold.pid)
        guard let url else {
            let alert = NSAlert()
            alert.messageText = localized("无法读取程序位置")
            alert.informativeText = localizedFormat("macOS 未提供 PID %d 的程序路径。", hold.pid)
            alert.runModal()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

@MainActor
struct ScreenOffView: View {
    @ObservedObject var model: ScreenSleepModel
    @ObservedObject var languageSettings: LanguageSettings
    let closeAndTurnOff: () -> Void
    let closeAndKeepAwake: () -> Void
    let exitApp: () -> Void
    let showProcessInfo: (PowerHold) -> Void
    let revealProcessInFinder: (PowerHold) -> Void
    @State private var showSystemSleepHolds = true
    @State private var isHoveringSystemSleepList = false
    @State private var showTerminationConfirmation = false
    @State private var selectedProcessIDs = Set<pid_t>()
    @State private var pendingBatchTermination: [PowerHold] = []
    @State private var inactivitySecondsText = ""
    @FocusState private var inactivitySecondsFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    HStack(spacing: 8) {
                        Button(action: closeAndTurnOff) {
                            Label("立即关屏", systemImage: "display")
                                .font(.system(.body, design: .rounded).weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .buttonStyle(.borderedProminent)

                        Button(action: closeAndKeepAwake) {
                            Label("关屏但不睡眠", systemImage: "moon.zzz.fill")
                                .font(.system(.callout, design: .rounded).weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .frame(height: 44)
                        }
                        .buttonStyle(.bordered)
                        .disabled(model.isKeepingAwakeAfterDisplayOff)
                        .help("关闭显示器，并阻止电脑因空闲自动睡眠")
                    }
                    if model.isKeepingAwakeAfterDisplayOff {
                        HStack(spacing: 6) {
                            Label("已阻止电脑自动睡眠", systemImage: "bolt.fill")
                                .foregroundStyle(.orange)
                            Spacer(minLength: 4)
                            Button("恢复自动睡眠") { model.allowSystemSleep() }
                                .buttonStyle(.borderless)
                        }
                        .font(.caption2)
                    }

                    scheduleSection
                    Divider()
                    automaticSection
                    Divider()
                    sourceSection
                }
                .padding(18)
            }
            .scrollDisabled(isHoveringSystemSleepList)
            Divider()
            HStack {
                Label("自动设置仅在应用运行时生效", systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button(action: exitApp) {
                    Label("退出", systemImage: "power")
                }
                .buttonStyle(.borderless)
                .help("退出屏幕管理")
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
        }
        .frame(width: 390, height: 760)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { inactivitySecondsText = String(model.inactivitySeconds) }
        .onChange(of: model.inactivitySeconds) { newValue in
            if !inactivitySecondsFocused { inactivitySecondsText = String(newValue) }
        }
        .onChange(of: inactivitySecondsFocused) { focused in
            if !focused { commitInactivitySeconds() }
        }
        .onChange(of: languageSettings.selection) { _ in model.refresh() }
        .environment(\.locale, languageSettings.locale)
        .confirmationDialog(
            pendingBatchTermination.count == 1
                ? localizedFormat("关闭 %@？", pendingBatchTermination.first?.appName ?? localized("此程序"))
                : localizedFormat("关闭所选的 %ld 个进程？", pendingBatchTermination.count),
            isPresented: $showTerminationConfirmation,
            titleVisibility: .visible
        ) {
            Button("请求正常退出") {
                model.terminateProcesses(for: pendingBatchTermination, force: false)
                pendingBatchTermination = []
            }
            Button("强制结束进程", role: .destructive) {
                model.terminateProcesses(for: pendingBatchTermination, force: true)
                pendingBatchTermination = []
            }
            Button("取消", role: .cancel) { pendingBatchTermination = [] }
        } message: {
            Text("先尝试正常退出；强制结束可能丢失所选程序中的未保存内容。")
        }
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "display")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 42, height: 42)
                .background(Color.accentColor.opacity(0.11), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text("屏幕管理").font(.title3.weight(.semibold))
                Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Menu {
                languageMenuItem("跟随系统", selection: "system")
                languageMenuItem("简体中文", selection: "zh-Hans")
                languageMenuItem("English", selection: "en")
            } label: {
                Image(systemName: "globe")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help(localized("选择界面语言"))
            .accessibilityLabel(localized("选择界面语言"))
            if model.isScreenLocked {
                Label("已锁屏", systemImage: "lock.fill")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color(nsColor: .quaternaryLabelColor).opacity(0.12), in: Capsule())
            }
        }
    }

    private func languageMenuItem(_ title: String, selection: String) -> some View {
        Button {
            languageSettings.selection = selection
        } label: {
            if languageSettings.selection == selection {
                Label(localized(title), systemImage: "checkmark")
            } else {
                Text(localized(title))
            }
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                sectionTitle("常亮来源", icon: "sun.max")
                Spacer()
                Button { model.refresh() } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .help("重新读取 macOS 电源断言")
            }

            if !uniqueProcessHolds.isEmpty {
                HStack(spacing: 8) {
                    Text(localizedFormat("已选 %ld / %ld", selectedProcessHolds.count, uniqueProcessHolds.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button(localized(selectedProcessHolds.count == uniqueProcessHolds.count ? "取消全选" : "全选")) {
                        toggleSelectAllProcesses()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    Button {
                        requestTermination(for: selectedProcessHolds)
                    } label: {
                        Label("批量关闭", systemImage: "power")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(selectedProcessHolds.isEmpty)
                }
            }

            if model.displayHolds.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("未发现阻止显示器熄灭的程序").font(.callout)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(localizedFormat("发现 %ld 个屏幕保持断言", model.displayHolds.count))
                            .font(.callout.weight(.medium))
                        Spacer(minLength: 0)
                    }
                    .padding(.bottom, 7)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(model.displayHolds) { hold in holdRow(hold) }
                        }
                    }
                    .frame(maxHeight: 132)
                }
                .padding(12)
                .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
            }

            if !model.systemSleepHolds.isEmpty {
                DisclosureGroup(isExpanded: $showSystemSleepHolds) {
                    ScrollView(.vertical, showsIndicators: model.systemSleepHolds.count > 5) {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(model.systemSleepHolds) { hold in holdRow(hold) }
                        }
                    }
                    .scrollDisabled(false)
                    .onHover { isHoveringSystemSleepList = $0 }
                    .frame(height: CGFloat(min(model.systemSleepHolds.count, 5)) * 46)
                    .padding(.top, 5)
                } label: {
                    Text(localizedFormat("阻止电脑自动睡眠 · %ld", model.systemSleepHolds.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }

    private var automaticSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("无操作自动关屏").font(.headline)
                    Text(localized(model.inactivityAutoOffEnabled ? "自动关闭已开启" : "按需开启，默认不自动关闭"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("无操作自动关屏", isOn: $model.inactivityAutoOffEnabled)
                    .labelsHidden()
                    .toggleStyle(CapsuleToggleStyle())
                    .accessibilityLabel("无操作自动关屏")
            }
            HStack(spacing: 7) {
                Text("无操作")
                TextField("秒数", text: $inactivitySecondsText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 76)
                .focused($inactivitySecondsFocused)
                .onChange(of: inactivitySecondsText) { newValue in
                    guard let seconds = Int(newValue), (10...86_400).contains(seconds) else { return }
                    model.inactivitySeconds = seconds
                }
                .onSubmit { commitInactivitySeconds() }
                Text("秒后关闭显示器")
                Spacer(minLength: 0)
            }
            .font(.callout)
            .disabled(!model.inactivityAutoOffEnabled)

            HStack(spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("锁屏后立即关屏").font(.callout)
                    Text("锁定时不等待无操作秒数").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("锁屏后立即关屏", isOn: $model.lockScreenAutoOff)
                    .labelsHidden()
                    .toggleStyle(CapsuleToggleStyle())
                    .accessibilityLabel("锁屏后立即关屏")
                    .disabled(!model.inactivityAutoOffEnabled)
            }
            .opacity(model.inactivityAutoOffEnabled ? 1 : 0.55)

            HStack(spacing: 8) {
                Image(systemName: "moon.zzz.fill")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text("自动关屏后阻止睡眠").font(.callout)
                    Text(automaticSleepPreventionDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("自动关屏后阻止睡眠", isOn: $model.preventSleepAfterAutomaticOff)
                    .labelsHidden()
                    .toggleStyle(CapsuleToggleStyle())
                    .accessibilityLabel("自动关屏后阻止睡眠")
                    .help("无操作、锁屏或定时关屏后，阻止电脑因空闲自动睡眠")
            }
        }
    }

    private var automaticSleepPreventionDescription: String {
        if model.isKeepingAwakeAfterDisplayOff { return localized("当前正在阻止电脑自动睡眠") }
        return model.preventSleepAfterAutomaticOff
            ? localized("无操作、锁屏或定时关屏后保持运行")
            : localized("自动关屏后允许电脑正常睡眠")
    }

    private var scheduleSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                sectionTitle("定时关屏", icon: "timer")
                Spacer()
                if let countdown = model.countdownText {
                    Text(countdown)
                        .font(.system(.callout, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            HStack {
                Text("在指定时间后关闭显示器")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Picker("关闭时间", selection: $model.selectedMinutes) {
                    ForEach([1, 5, 10, 15, 30, 45, 60, 90, 120], id: \.self) { minutes in
                        Text(scheduleDurationLabel(minutes)).tag(minutes)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                if model.countdown == nil {
                    Button("开始") { model.startCountdown() }
                        .buttonStyle(.bordered)
                } else {
                    Button("取消") { model.cancelCountdown() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(localized(title), systemImage: icon)
            .font(.subheadline.weight(.semibold))
    }

    private func scheduleDurationLabel(_ minutes: Int) -> String {
        if minutes < 60 { return localizedFormat("%ld 分钟", minutes) }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0
            ? localizedFormat("%ld 小时", hours)
            : localizedFormat("%ld 小时 %ld 分钟", hours, remainder)
    }

    private func holdRow(_ hold: PowerHold) -> some View {
        HStack(spacing: 9) {
            Toggle(localizedFormat("选择 %@", hold.appName), isOn: Binding(
                get: { selectedProcessIDs.contains(hold.pid) },
                set: { isSelected in
                    if isSelected { selectedProcessIDs.insert(hold.pid) }
                    else { selectedProcessIDs.remove(hold.pid) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .accessibilityLabel(localizedFormat("选择 %@（PID %d）", hold.appName, hold.pid))
            Image(systemName: "app.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(hold.appName).font(.callout.weight(.medium))
                Text(hold.readableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(localizedFormat("macOS 原始断言：%@", hold.assertionName))
            }
            Spacer(minLength: 4)
            Text("PID \(hold.pid)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            Button {
                requestTermination(for: [hold])
            } label: {
                Label("退出", systemImage: "power")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("先请求正常退出，也可确认后强制结束")
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button {
                showProcessInfo(hold)
            } label: {
                Label("查看进程信息", systemImage: "info.circle")
            }
            Button {
                revealProcessInFinder(hold)
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }
            Divider()
            Button {
                requestTermination(for: [hold])
            } label: {
                Label("请求正常退出", systemImage: "rectangle.portrait.and.arrow.right")
            }
            Button(role: .destructive) {
                requestTermination(for: [hold])
            } label: {
                Label("强制结束进程…", systemImage: "xmark.circle")
            }
        }
    }

    private var uniqueProcessHolds: [PowerHold] {
        var seen = Set<pid_t>()
        return model.holds.filter { seen.insert($0.pid).inserted }
    }

    private var selectedProcessHolds: [PowerHold] {
        uniqueProcessHolds.filter { selectedProcessIDs.contains($0.pid) }
    }

    private func toggleSelectAllProcesses() {
        let allIDs = Set(uniqueProcessHolds.map(\.pid))
        if selectedProcessIDs.isSuperset(of: allIDs) {
            selectedProcessIDs.subtract(allIDs)
        } else {
            selectedProcessIDs.formUnion(allIDs)
        }
    }

    private func requestTermination(for holds: [PowerHold]) {
        guard !holds.isEmpty else { return }
        pendingBatchTermination = holds
        showTerminationConfirmation = true
    }

    private func commitInactivitySeconds() {
        let parsed = Int(inactivitySecondsText) ?? model.inactivitySeconds
        let clamped = min(max(parsed, 10), 86_400)
        model.inactivitySeconds = clamped
        inactivitySecondsText = String(clamped)
    }
}

struct CapsuleToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            HStack(spacing: 10) {
                configuration.label
                Capsule()
                    .fill(configuration.isOn ? Color.accentColor : Color.gray.opacity(0.4))
                    .frame(width: 38, height: 22)
                    .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 16, height: 16)
                            .padding(3)
                    }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(configuration.isOn ? .isSelected : [])
    }
}

@MainActor
private final class ProcessInfoWindowController: NSWindowController, NSWindowDelegate {
    private let revealInFinder: () -> Void
    private let languageSettings: LanguageSettings
    private var currentHold: PowerHold
    private var languageObserver: AnyCancellable?

    init(hold: PowerHold, languageSettings: LanguageSettings, revealInFinder: @escaping () -> Void) {
        self.currentHold = hold
        self.languageSettings = languageSettings
        self.revealInFinder = revealInFinder
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = localizedFormat("%@ · 进程信息", hold.appName)
        window.minSize = NSSize(width: 440, height: 400)
        window.level = .floating
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: ProcessInformationView(hold: hold, languageSettings: languageSettings, revealInFinder: revealInFinder)
        )
        window.center()
        languageObserver = languageSettings.$selection.dropFirst().sink { [weak self] _ in
            guard let view = self else { return }
            Task { @MainActor in
                view.update(hold: view.currentHold)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(hold: PowerHold) {
        currentHold = hold
        window?.title = localizedFormat("%@ · 进程信息", hold.appName)
        window?.contentViewController = NSHostingController(
            rootView: ProcessInformationView(hold: hold, languageSettings: languageSettings, revealInFinder: revealInFinder)
        )
    }

    func hideWindow() {
        window?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        hideWindow()
    }
}

@MainActor
private struct ProcessInformationView: View {
    let hold: PowerHold
    @ObservedObject var languageSettings: LanguageSettings
    let revealInFinder: () -> Void

    private var executableURL: URL? { processExecutableURL(hold.pid) }
    private var runningApplication: NSRunningApplication? {
        NSRunningApplication(processIdentifier: hold.pid)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(hold.appName, systemImage: "app.fill")
                .font(.title3.weight(.semibold))
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                infoRow("进程 ID", value: String(hold.pid))
                infoRow("运行状态", value: runningApplication == nil ? localized("已退出或不可访问") : localized("正在运行"))
                infoRow("断言类型", value: localized(hold.type))
                infoRow("断言名称", value: hold.assertionName)
                infoRow("程序路径", value: executableURL?.path ?? localized("不可读取"))
                infoRow("Bundle ID", value: runningApplication?.bundleIdentifier ?? localized("不可读取"))
                infoRow("应用位置", value: runningApplication?.bundleURL?.path ?? localized("不可读取"))
                infoRow("启动时间", value: launchDateText)
            }
            Divider()
            HStack {
                Text(hold.readableReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    revealInFinder()
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                }
                .disabled(executableURL == nil && runningApplication?.bundleURL == nil)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .textSelection(.enabled)
        .environment(\.locale, languageSettings.locale)
    }

    private var launchDateText: String {
        guard let launchDate = runningApplication?.launchDate else { return localized("不可读取") }
        return launchDate.formatted(Date.FormatStyle(
            date: .abbreviated,
            time: .standard,
            locale: languageSettings.locale
        ))
    }

    private func infoRow(_ title: String, value: String) -> some View {
        GridRow(alignment: .top) {
            Text(localized(title))
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value.isEmpty ? localized("不可读取") : value)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        controller = MenuBarController()
    }

}

@main
struct ScreenOffApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
