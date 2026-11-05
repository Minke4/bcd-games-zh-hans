// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import SwiftUI

// Settings › BCD Dock: what Dock is, whether it is ready, Valve's client files it needs
// (download, size, progress) and each game's one-time installs, with their reset. The
// section names no engine type: it reads and asks through BCDDockBackend, which
// BCDDockLive.swift carries out on the app's Dock model and the preview app on sample data
// (docs/BCD-UI-ARCHITECTURE.md).

// MARK: - What the section shows and asks for

/// A request a game's next Dock start carries out, before Valve's client starts.
enum BCDDockRequest: String, Equatable {
    /// Mark the game's one-time install programs as done without running them.
    case record
    /// Take out what they installed (into a backup), then run them again.
    case reset
    /// The same, and remove the Rockstar sign-in too.
    case resetAndSignOut
}

/// A Steam game Valve's client installed on this device, which Dock can start.
struct BCDDockGame: Identifiable, Equatable {
    /// The Steam App ID.
    var id: Int
    var name: String
    /// Steam's install record says the install is complete.
    var installed: Bool
}

/// An installed Steam game whose install script has one-time programs.
struct BCDDockInstallGame: Identifiable, Equatable {
    /// The Steam App ID.
    var id: Int
    var name: String
    var programs: Int
    /// The next Dock start runs them (else it skips them).
    var runNext: Bool
    var pending: BCDDockRequest?
}

/// Valve's Steam client files Dock needs.
struct BCDDockComponents: Equatable {
    var installed = false
    /// How much the download is.
    var downloadBytes: Int64 = 0
    var working = false
    /// What the download is doing, in words, and as a step of `steps` when known.
    var step: String?
    var stepIndex: Int?
    var steps = 0
    var error: String?
}

struct BCDDockSectionState: Equatable {
    /// This copy of BCD was built with Dock.
    var inBuild = true
    /// Dock is not switched off in the advanced settings.
    var switchedOn = true
    /// The Steam account Dock signs in with; nil when nobody is signed in.
    var accountName: String?
    var components = BCDDockComponents()
    /// Each game's one-time installs can be chosen (else every start runs what is pending).
    var installsChoice = true
    var installGames: [BCDDockInstallGame] = []
    /// The games Valve's client installed on this device.
    var games: [BCDDockGame] = []
    /// Dock starts use the smaller JIT pool (512 MB) until BCD closes.
    var compactPool = false
    /// How the last Dock start went, in words.
    var lastResult: String?
}

@MainActor protocol BCDDockBackend: ObservableObject {
    var state: BCDDockSectionState { get }
    func refresh()
    func downloadComponents()
    /// Starts the game through Dock, as the rest of the interface starts a Steam game.
    func start(_ appID: Int)
    func setCompactPool(_ on: Bool)
    func setRunsInstalls(_ appID: Int, _ run: Bool)
    /// Saves a request for the game's next Dock start; nil cancels the saved one.
    func setRequest(_ appID: Int, _ request: BCDDockRequest?)
}

// MARK: - The section

/// Settings › BCD Dock. While a question shows, B closes it first. A host that scrolls and
/// runs the buttons itself (Settings) passes `scrolls: false` and `backHook`; on its own,
/// `back` is what B does here. `signIn` opens the Steam sign-in (Accounts' sign-in page).
struct BCDDockSection<Backend: BCDDockBackend>: View {
    @ObservedObject var backend: Backend
    var showsTitle = true
    var scrolls = true
    var back: (() -> Void)? = nil
    var backHook: BCDSectionKit.BackHook? = nil
    var signIn: (() -> Void)? = nil
    @EnvironmentObject private var focus: BCDFocus
    /// The question on screen: record or reset, for a game.
    @State private var asking: Question?

    private struct Question: Equatable {
        enum Kind { case record, reset }
        let kind: Kind
        let appID: Int
    }

    private static var prefix: String { "settings.dock." }
    private var state: BCDDockSectionState { backend.state }

    var body: some View {
        BCDSectionKit.Page(title: "BCD Dock", subtitle: "BCD 启动 Steam 游戏的方式。",
                           showsTitle: showsTitle, scrolls: scrolls, focusPrefix: Self.prefix) {
            BCDSectionKit.Columns {
                aboutCard
                componentsCard
                gamesCard
            } right: {
                installsCard
                if let result = state.lastResult {
                    BCDSectionKit.Card(eyebrow: "Last Dock start", symbol: "clock.arrow.circlepath") {
                        Text(result).bcdFont(.body, 14).foregroundStyle(BCDStyle.textSoft)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .modifier(BCDSectionKit.Buttons(focus: focus, key: asking, inner: closeQuestion, back: back, hook: backHook))
        .onAppear { backend.refresh() }
    }

    /// B inside the section: the question closes. False: none was open.
    private func closeQuestion() -> Bool {
        guard let question = asking else { return false }
        asking = nil
        focusButton(question.kind == .record ? "录制" : "已重置", question.appID)
        return true
    }

    private func focusButton(_ name: String, _ appID: Int) {
        if focus.controllerActive { focus.focused = Self.prefix + "installs.\(appID).\(name)" }
    }

    // MARK: What Dock is, and whether it is ready

    private var aboutCard: some View {
        BCDSectionKit.Card(accent: !ready) {
            readiness
            if state.inBuild && state.switchedOn && state.accountName == nil, let signIn {
                BCDSectionKit.ActionButton(title: "登录 Steam", symbol: "person.crop.circle.badge.plus", kind: .primary,
                                           fill: true, id: Self.prefix + "signin", action: signIn)
            }
            Text("BCD Dock 使用 Valve 自家的 Steam 客户端启动你已安装的 Steam 游戏，客户端在 BCD 内部隐藏运行，不打开桌面窗口。客户端以你的身份登录并核对每个游戏是否属于你，因此是否允许启动完全由 Steam 决定。")
                .bcdFont(.body, 14).foregroundStyle(BCDStyle.textSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Dock can start a game now.
    private var ready: Bool {
        state.inBuild && state.switchedOn && state.components.installed && state.accountName != nil
    }

    @ViewBuilder private var readiness: some View {
        if !state.inBuild {
            BCDSectionKit.Headline(text: "此副本的 BCD 中没有", symbol: "shippingbox", tone: .soft,
                                   detail: "This build of BCD came without BCD Dock.")
        } else if !state.switchedOn {
            BCDSectionKit.Headline(text: "已关闭", symbol: "pause.circle", tone: .soft,
                                   detail: "BCD Dock is turned off in the advanced settings.")
        } else if state.components.working {
            BCDSectionKit.Headline(text: "正在获取 Valve 客户端文件", symbol: "arrow.down.circle", tone: .info,
                                   detail: "Dock is ready as soon as they're in place.")
        } else if !state.components.installed {
            BCDSectionKit.Headline(text: "需要 Valve 的客户端文件", symbol: "arrow.down.circle", tone: .warn,
                                   detail: "Download them below once; Dock is ready after that.")
        } else if let name = state.accountName {
            let count = state.games.filter(\.installed).count
            BCDSectionKit.Headline(text: "就绪", symbol: "checkmark.circle.fill", tone: .good,
                                   detail: count == 1 ? "Signs in as \(name). 1 Steam game installed."
                                                      : "Signs in as \(name). \(count) Steam games installed.")
        } else {
            BCDSectionKit.Headline(text: "请先登录 Steam", symbol: "person.crop.circle.badge.exclamationmark", tone: .warn,
                                   detail: signIn == nil ? "Dock signs in with your Steam account. Sign in under Accounts."
                                                         : "Dock signs in with your Steam account.")
        }
    }

    // MARK: Valve's client files

    @ViewBuilder private var componentsCard: some View {
        if state.inBuild && state.switchedOn {
            let parts = state.components
            BCDSectionKit.Card(eyebrow: "Valve's client files", symbol: "shippingbox") {
                if parts.installed {
                    BCDSectionKit.Note(text: "已安装并已校验。", symbol: "checkmark.circle.fill", tone: .good)
                    Text("Dock 只使用它所知的客户端版本；其他版本会被拒绝。")
                        .bcdFont(.body, 13).foregroundStyle(BCDStyle.textSoft).fixedSize(horizontal: false, vertical: true)
                } else if parts.working {
                    if let index = parts.stepIndex, parts.steps > 0 {
                        BCDSectionKit.StepBar(lit: index, of: parts.steps)
                    }
                    BCDSectionKit.Note(text: parts.step ?? "Starting…", symbol: "arrow.down.circle", tone: .info)
                    Text("你可以离开此页面，下载仍会继续。")
                        .bcdFont(.body, 13).foregroundStyle(BCDStyle.textSoft)
                } else {
                    Text("About \(BCDFormat.bytes(parts.downloadBytes)) from Valve's own update servers, once. Every file is checked against a fixed SHA-256 before BCD uses it.")
                        .bcdFont(.body, 14).foregroundStyle(BCDStyle.textSoft)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = parts.error {
                        BCDSectionKit.Note(text: error, symbol: "exclamationmark.triangle.fill", tone: .bad)
                    }
                    BCDSectionKit.ActionButton(title: parts.error == nil ? "Download (\(BCDFormat.bytes(parts.downloadBytes)))" : "重试",
                                               symbol: "arrow.down.circle.fill", kind: .primary, fill: true,
                                               id: Self.prefix + "download") { backend.downloadComponents() }
                }
            }
        }
    }

    // MARK: Installed games

    /// The games Valve's client installed here, each started through Dock, and the pool switch.
    @ViewBuilder private var gamesCard: some View {
        if state.inBuild && state.switchedOn {
            BCDSectionKit.Card(eyebrow: "Installed Steam games", symbol: "gamecontroller") {
                if state.games.isEmpty {
                    BCDSectionKit.Note(text: "Valve's client hasn't installed a Steam game on this \(BCDSectionKit.deviceWord) yet.",
                                       symbol: "tray")
                } else {
                    ForEach(state.games) { game in gameRow(game) }
                }
                Divider().overlay(BCDStyle.stroke)
                BCDSectionKit.SwitchRow(title: "较小的 JIT 池（512 MB）",
                                        detail: "Dock starts until BCD closes use a 512 MB JIT pool instead of the usual one, which leaves more memory to the game.",
                                        isOn: state.compactPool, id: Self.prefix + "pool") { backend.setCompactPool($0) }
            }
        }
    }

    private func gameRow(_ game: BCDDockGame) -> some View {
        let startable = game.installed && state.components.installed && state.accountName != nil
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(game.name).bcdFont(.heading, 16).lineLimit(2)
                if !game.installed {
                    Text("未完全安装").bcdFont(.body, 13).foregroundStyle(BCDStyle.textSoft)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            BCDSectionKit.ActionButton(title: "开始", symbol: "play.fill", kind: .outline, id: Self.prefix + "game.\(game.id)",
                                       enabled: startable) { backend.start(game.id) }
        }
    }

    // MARK: One-time installs

    @ViewBuilder private var installsCard: some View {
        if state.inBuild && state.switchedOn {
            BCDSectionKit.Card(eyebrow: "一次性安装", symbol: "square.stack.3d.down.right") {
                Text("有些游戏会要求 Steam 在首次启动前运行一次性安装程序（如运行库）。Dock 会在 Valve 客户端启动前运行尚未完成的部分，然后把游戏设为「跳过」。")
                    .bcdFont(.body, 14).foregroundStyle(BCDStyle.textSoft)
                    .fixedSize(horizontal: false, vertical: true)
                if !state.installsChoice {
                    BCDSectionKit.Note(text: "每次 Dock 启动都会运行所有未完成项。", symbol: "info.circle")
                } else if state.installGames.isEmpty {
                    BCDSectionKit.Note(text: "你已安装的 Steam 游戏都没有一次性安装项。", symbol: "checkmark.circle")
                } else {
                    ForEach(state.installGames) { game in
                        Divider().overlay(BCDStyle.stroke)
                        installRow(game)
                    }
                }
            }
        }
    }

    private func installRow(_ game: BCDDockInstallGame) -> some View {
        let id = Self.prefix + "installs.\(game.id)."
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(game.name).bcdFont(.heading, 16).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(game.programs == 1 ? "1 program" : "\(game.programs) programs")
                    .bcdFont(.body, 13).foregroundStyle(BCDStyle.textSoft)
            }
            BCDSectionKit.Segments(options: [(value: true, title: "下次启动时运行"), (value: false, title: "跳过")],
                                   selected: game.runNext, idPrefix: id + "run.") { backend.setRunsInstalls(game.id, $0) }
            if let pending = game.pending {
                HStack(alignment: .center, spacing: 8) {
                    BCDSectionKit.Note(text: pendingText(pending), symbol: "clock", tone: .info)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    BCDSectionKit.ActionButton(title: "取消", kind: .quiet, id: id + "取消") {
                        backend.setRequest(game.id, nil)
                        focusButton("已重置", game.id)
                    }
                }
            } else if asking == Question(kind: .record, appID: game.id) {
                recordQuestion(game)
            } else if asking == Question(kind: .reset, appID: game.id) {
                resetQuestion(game)
            } else {
                BCDSectionKit.Flow {
                    BCDSectionKit.ActionButton(title: "标记为已完成…", symbol: "checkmark.circle", kind: .quiet, id: id + "录制") {
                        ask(.record, game.id)
                    }
                    BCDSectionKit.ActionButton(title: "重置…", symbol: "arrow.counterclockwise", kind: .danger, id: id + "已重置") {
                        ask(.reset, game.id)
                    }
                }
            }
        }
    }

    private func ask(_ kind: Question.Kind, _ appID: Int) {
        asking = Question(kind: kind, appID: appID)
        if focus.controllerActive { focus.focused = Self.prefix + "installs.\(appID).no" }
    }

    private func pendingText(_ request: BCDDockRequest) -> String {
        switch request {
        case .record: return "At the next start: mark the one-time installs as done."
        case .reset: return "At the next start: take out what the one-time installs added, then run them again."
        case .resetAndSignOut: return "At the next start: take out what the one-time installs added and the Rockstar sign-in, then run them again."
        }
    }

    /// Record as done is saved only from here, after the question.
    private func recordQuestion(_ game: BCDDockInstallGame) -> some View {
        let id = Self.prefix + "installs.\(game.id)."
        return BCDSectionKit.Confirm(
            title: "Record \(game.name)'s one-time installs as done?",
            message: "针对已完成工作但窗口一直未关闭的安装程序，BCD 始终没看到它结束。下次启动时 BCD 会把此游戏的安装程序标记为已完成（如同正常跑完），它们不会再运行。不会安装或移除任何内容。",
            choices: [
                .init(title: "标记为已完成", kind: .outline, id: id + "yes") {
                    asking = nil
                    backend.setRequest(game.id, .record)
                    focusButton("取消", game.id)
                },
                .init(title: "取消", kind: .quiet, id: id + "no") {
                    asking = nil
                    focusButton("录制", game.id)
                },
            ])
    }

    /// A reset is saved only from here, after the question. The game's next Dock start
    /// carries it out, through the same reset the Dock has always used.
    private func resetQuestion(_ game: BCDDockInstallGame) -> some View {
        let id = Self.prefix + "installs.\(game.id)."
        return BCDSectionKit.Confirm(
            title: "Reset \(game.name)'s one-time installs?",
            message: "At this game's next start through Dock, BCD moves what the one-time installs added to Windows (the Rockstar Games Launcher, Social Club, the Visual C++ 2015-2022 runtimes and the Vulkan runtime) into a backup folder in BCD's Documents, then runs only the installers, as on a new device. Restart BCD after that to play. Other games that share these installs set them up again at their next start. Your game files and saves stay.",
            choices: [
                .init(title: "重置", kind: .danger, id: id + "yes") {
                    asking = nil
                    backend.setRequest(game.id, .reset)
                    focusButton("取消", game.id)
                },
                .init(title: "重置并退出 Rockstar 登录", kind: .danger, id: id + "signout") {
                    asking = nil
                    backend.setRequest(game.id, .resetAndSignOut)
                    focusButton("取消", game.id)
                },
                .init(title: "取消", kind: .quiet, id: id + "no") {
                    asking = nil
                    focusButton("已重置", game.id)
                },
            ])
    }
}
