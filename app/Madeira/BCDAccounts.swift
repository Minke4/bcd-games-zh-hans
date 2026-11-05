// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import SwiftUI
import UIKit

// Settings › Accounts: the stores BCD signs in to. Steam (the signed-in account, sign out
// after a question, BCD's own sign-in page, Steam Cloud saves), Epic Games and GOG (sign in on
// the store's own page, sign out after a question). The section names no engine type: it reads and asks through
// BCDAccountsBackend, which BCDAccountsLive.swift carries out on the app's own Steam sign-in
// and the preview app on sample data (docs/BCD-UI-ARCHITECTURE.md).

// MARK: - What the section shows and asks for

/// The Steam account as the section shows it.
struct BCDSteamAccount: Equatable {
    /// Steam sign-in is part of this copy of BCD (the advanced settings can switch it off).
    var available = true
    /// The account name; nil when nobody is signed in.
    var accountName: String?
    /// Steam's public profile name and picture, when the backend has them.
    var personaName: String?
    var avatar: UIImage?
    /// Steam Cloud saves can be switched in this copy, and whether they are on.
    var cloudAvailable = false
    var cloudOn = true
    /// First-run setup can be opened again.
    var setupAvailable = false
}

/// What Steam Guard asks for after the password: a code (from the Steam app or an email),
/// an approval in the Steam app, or either.
struct BCDSteamGuard: Equatable {
    enum Code: Equatable {
        case steamApp
        /// Steam's hint for the address, which may be empty.
        case email(hint: String)
    }
    var code: Code?
    var canApprove: Bool
}

/// Where a sign-in stands.
struct BCDSteamSignIn: Equatable {
    var busy = false
    var steamGuard: BCDSteamGuard?
    var qrImage: UIImage?
    /// Opens the Steam app on this device at the same request, when Steam gave one.
    var qrLink: URL?
    var error: String?
}

@MainActor protocol BCDAccountsBackend: ObservableObject {
    var steam: BCDSteamAccount { get }
    var signInProgress: BCDSteamSignIn { get }
    func refresh()
    /// Starts a password sign-in. The password goes straight on to Steam's sign-in and is
    /// never kept or written to a log, here or in the backend.
    func signIn(account: String, password: String)
    func submitGuardCode(_ code: String)
    func beginQR()
    func cancelSignIn()
    func clearSignInError()
    func signOut()
    func setCloud(_ on: Bool)
    func runSetup()
    /// GOG's account: `name` nil while signed out, `available` false when this copy has no GOG.
    var gogAccount: BCDAccount { get }
    /// Opens GOG's own sign-in page.
    func signInGOG()
    func signOutGOG()
    /// Epic Games' account: `name` nil while signed out, `available` false when this copy has no Epic.
    var epicAccount: BCDAccount { get }
    /// Opens Epic's own sign-in page.
    func signInEpic()
    func signOutEpic()
}

enum BCDAccountsPage: Equatable {
    case main
    /// BCD's Steam sign-in page; `qr` opens it on the QR code.
    case signIn(qr: Bool)
}

// MARK: - The section

/// Settings › Accounts. On the sign-in page and while a question shows, B closes those
/// first. A host that scrolls and runs the buttons itself (Settings) passes `scrolls: false`
/// and `backHook` (BCDSectionKit.BackHook); on its own, `back` is what B does on the first page.
struct BCDAccountsSection<Backend: BCDAccountsBackend>: View {
    @ObservedObject var backend: Backend
    var showsTitle = true
    var scrolls = true
    var back: (() -> Void)? = nil
    var backHook: BCDSectionKit.BackHook? = nil
    @EnvironmentObject private var focus: BCDFocus
    @State private var page: BCDAccountsPage
    @State private var confirmingSignOut = false
    @State private var confirmingGOGSignOut = false
    @State private var confirmingEpicSignOut = false

    init(backend: Backend, showsTitle: Bool = true, scrolls: Bool = true, startOn page: BCDAccountsPage = .main,
         back: (() -> Void)? = nil, backHook: BCDSectionKit.BackHook? = nil) {
        self.backend = backend
        self.showsTitle = showsTitle
        self.scrolls = scrolls
        self.back = back
        self.backHook = backHook
        _page = State(initialValue: page)
    }

    private static var prefix: String { "settings.accounts." }

    var body: some View {
        Group {
            switch page {
            case .main:
                main
            case .signIn(let qr):
                BCDSteamSignInPage(backend: backend, startWithQR: qr, scrolls: scrolls) {
                    show(.main, focusing: Self.prefix + (backend.steam.accountName == nil ? "steam.signin" : "steam.signout"))
                }
            }
        }
        .modifier(BCDSectionKit.Buttons(focus: focus, key: "\(page)-\(confirmingSignOut)-\(confirmingGOGSignOut)-\(confirmingEpicSignOut)",
                                        inner: closeInner, back: back, hook: backHook))
        .onAppear { backend.refresh() }
        .onChange(of: backend.steam.accountName) { _, name in
            if name == nil { confirmingSignOut = false }
        }
        .onChange(of: backend.gogAccount.name) { _, name in
            if name == nil { confirmingGOGSignOut = false }
        }
        .onChange(of: backend.epicAccount.name) { _, name in
            if name == nil { confirmingEpicSignOut = false }
        }
    }

    /// B inside the section: the question closes, then the sign-in page. False: nothing was open.
    private func closeInner() -> Bool {
        if confirmingEpicSignOut {
            confirmingEpicSignOut = false
            if focus.controllerActive { focus.focused = Self.prefix + "epic.signout" }
            return true
        }
        if confirmingGOGSignOut {
            confirmingGOGSignOut = false
            if focus.controllerActive { focus.focused = Self.prefix + "gog.signout" }
            return true
        }
        if confirmingSignOut {
            confirmingSignOut = false
            if focus.controllerActive { focus.focused = Self.prefix + "steam.signout" }
            return true
        }
        if page != .main {
            backend.cancelSignIn()
            show(.main, focusing: Self.prefix + (backend.steam.accountName == nil ? "steam.signin" : "steam.signout"))
            return true
        }
        return false
    }

    private func show(_ next: BCDAccountsPage, focusing id: String? = nil) {
        page = next
        if focus.controllerActive, let id { focus.focused = id }
    }

    // MARK: First page

    private var main: some View {
        BCDSectionKit.Page(title: "账号", subtitle: "BCD 为你的游戏登录的商店。",
                           showsTitle: showsTitle, scrolls: scrolls, focusPrefix: Self.prefix) {
            BCDSectionKit.Columns {
                steamCard
            } right: {
                epicCard
                gogCard
                keptNote
            }
        }
    }

    private var steamCard: some View {
        BCDSectionKit.Card(eyebrow: "Steam", symbol: "person.crop.circle", accent: backend.steam.accountName == nil && backend.steam.available) {
            let steam = backend.steam
            if !steam.available {
                BCDSectionKit.Note(text: "此副本的 BCD 已关闭 Steam 登录。", symbol: "nosign")
            } else if let name = steam.accountName {
                signedIn(name: name, steam: steam)
            } else {
                signedOut
            }
            if steam.available && steam.cloudAvailable {
                Divider().overlay(BCDStyle.stroke)
                BCDSectionKit.SwitchRow(title: "Steam 云存档", detail: cloudDetail(steam), isOn: steam.cloudOn,
                                        id: Self.prefix + "steam.cloud") { backend.setCloud($0) }
            }
            if steam.setupAvailable {
                BCDSectionKit.ActionButton(title: "重新运行设置", symbol: "wand.and.stars", kind: .quiet,
                                           id: Self.prefix + "setup") { backend.runSetup() }
            }
        }
    }

    private func cloudDetail(_ steam: BCDSteamAccount) -> String {
        if !steam.cloudOn { return "Off. Saves stay on this device and Steam's copies are left alone." }
        return steam.accountName == nil
            ? "Starts working once you sign in."
            : "Your saves sync with your Steam account when BCD starts and before a game starts."
    }

    private func signedIn(name: String, steam: BCDSteamAccount) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                avatar(steam.avatar, name: steam.personaName ?? name)
                VStack(alignment: .leading, spacing: 3) {
                    Text(steam.personaName ?? name).bcdFont(.heading, 19).lineLimit(1)
                    Text(steam.personaName == nil ? "账号名称" : "Account: \(name)")
                        .bcdFont(.body, 14).foregroundStyle(BCDStyle.textSoft).lineLimit(1)
                }
                Spacer(minLength: 8)
                BCDStatusChip(text: "已登录", color: BCDStyle.mint)
            }
            .accessibilityElement(children: .combine)
            if confirmingSignOut {
                signOutQuestion
            } else {
                BCDSectionKit.ActionButton(title: "退出登录", symbol: "rectangle.portrait.and.arrow.right", kind: .danger,
                                           id: Self.prefix + "steam.signout") {
                    confirmingSignOut = true
                    if focus.controllerActive { focus.focused = Self.prefix + "steam.signout.cancel" }
                }
            }
        }
    }

    /// Sign out happens only from here, after the question.
    private var signOutQuestion: some View {
        BCDSectionKit.Confirm(
            title: "退出 Steam 登录？",
            message: "BCD removes your Steam sign-in from this \(BCDSectionKit.deviceWord), pauses Steam downloads and forgets the list of your Steam games. Installed games stay. To download Steam games or start them through BCD Dock, sign in again.",
            choices: [
                .init(title: "退出登录", kind: .danger, id: Self.prefix + "steam.signout.confirm") {
                    confirmingSignOut = false
                    backend.signOut()
                    if focus.controllerActive { focus.focused = Self.prefix + "steam.signin" }
                },
                .init(title: "取消", kind: .outline, id: Self.prefix + "steam.signout.cancel") {
                    confirmingSignOut = false
                    if focus.controllerActive { focus.focused = Self.prefix + "steam.signout" }
                },
            ])
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                avatar(nil, name: nil)
                VStack(alignment: .leading, spacing: 3) {
                    Text("未登录").bcdFont(.heading, 19)
                    Text("登录以查看你的 Steam 游戏、下载并通过 BCD Dock 游玩。")
                        .bcdFont(.body, 14).foregroundStyle(BCDStyle.textSoft)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            BCDSectionKit.ActionButton(title: "登录 Steam", symbol: "person.crop.circle.badge.plus", kind: .primary, fill: true,
                                       id: Self.prefix + "steam.signin") {
                show(.signIn(qr: focus.controllerActive || UIDevice.current.userInterfaceIdiom == .pad),
                     focusing: Self.prefix + "signin.mode.0")
            }
        }
    }

    /// The account's picture, or its first letter on the logo's colours.
    private func avatar(_ image: UIImage?, name: String?) -> some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let initial = name?.first {
                Circle().fill(BCDStyle.glow)
                Text(String(initial).uppercased()).font(.system(size: 22, weight: .heavy, design: .rounded)).foregroundStyle(.white)
            } else {
                Circle().fill(BCDStyle.surfaceRaised)
                Image(systemName: "person.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(BCDStyle.textSoft)
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(BCDStyle.stroke, lineWidth: 1))
        .accessibilityHidden(true)
    }

    // MARK: GOG

    private var gogCard: some View {
        BCDSectionKit.Card(eyebrow: "GOG", symbol: "bag") {
            let gog = backend.gogAccount
            if !gog.available {
                BCDSectionKit.Note(text: "此副本的 BCD 已关闭 GOG。", symbol: "nosign")
            } else if let name = gog.name {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        avatar(nil, name: name)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).bcdFont(.heading, 19).lineLimit(1)
                            Text("账号名称").bcdFont(.body, 14).foregroundStyle(BCDStyle.textSoft).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        BCDStatusChip(text: "已登录", color: BCDStyle.mint)
                    }
                    .accessibilityElement(children: .combine)
                    if confirmingGOGSignOut {
                        gogSignOutQuestion
                    } else {
                        BCDSectionKit.ActionButton(title: "退出登录", symbol: "rectangle.portrait.and.arrow.right", kind: .danger,
                                                   id: Self.prefix + "gog.signout") {
                            confirmingGOGSignOut = true
                            if focus.controllerActive { focus.focused = Self.prefix + "gog.signout.cancel" }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        avatar(nil, name: nil)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("未登录").bcdFont(.heading, 19)
                            Text("登录以查看你的 GOG 游戏、下载并在 BCD 中游玩。")
                                .bcdFont(.body, 14).foregroundStyle(BCDStyle.textSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    BCDSectionKit.ActionButton(title: "登录 GOG", symbol: "person.crop.circle.badge.plus", kind: .primary,
                                               fill: true, id: Self.prefix + "gog.signin") { backend.signInGOG() }
                    BCDSectionKit.Note(text: "使用 Google 登录？Google 可能会在 BCD 中拒绝该页面；此时请点 GOG 登录页顶部的「使用 Safari」。",
                                       symbol: "safari")
                }
            }
        }
    }

    /// GOG's sign-out happens only from here, after the question.
    private var gogSignOutQuestion: some View {
        BCDSectionKit.Confirm(
            title: "退出 GOG 登录？",
            message: "BCD 会忘记你的 GOG 登录状态。GOG 无法从外部注销；它会自行过期。已安装的游戏会保留。",
            choices: [
                .init(title: "退出登录", kind: .danger, id: Self.prefix + "gog.signout.confirm") {
                    confirmingGOGSignOut = false
                    backend.signOutGOG()
                    if focus.controllerActive { focus.focused = Self.prefix + "gog.signin" }
                },
                .init(title: "取消", kind: .outline, id: Self.prefix + "gog.signout.cancel") {
                    confirmingGOGSignOut = false
                    if focus.controllerActive { focus.focused = Self.prefix + "gog.signout" }
                },
            ])
    }

    // MARK: Epic Games

    private var epicCard: some View {
        BCDSectionKit.Card(eyebrow: "Epic Games", symbol: "gamecontroller") {
            let epic = backend.epicAccount
            if !epic.available {
                BCDSectionKit.Note(text: "此副本的 BCD 已关闭 Epic Games。", symbol: "nosign")
            } else if let name = epic.name {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        avatar(nil, name: name)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(name).bcdFont(.heading, 19).lineLimit(1)
                            Text("Epic 账号").bcdFont(.body, 14).foregroundStyle(BCDStyle.textSoft).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        BCDStatusChip(text: "已登录", color: BCDStyle.mint)
                    }
                    .accessibilityElement(children: .combine)
                    BCDSectionKit.Note(text: "你的 Epic 游戏已在游戏库中。BCD 会安装能运行的，并在无法运行时说明原因。", symbol: "info.circle")
                    if confirmingEpicSignOut {
                        epicSignOutQuestion
                    } else {
                        BCDSectionKit.ActionButton(title: "退出登录", symbol: "rectangle.portrait.and.arrow.right", kind: .danger,
                                                   id: Self.prefix + "epic.signout") {
                            confirmingEpicSignOut = true
                            if focus.controllerActive { focus.focused = Self.prefix + "epic.signout.cancel" }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        avatar(nil, name: nil)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("未登录").bcdFont(.heading, 19)
                            Text("登录以查看你在 Epic Games 拥有的游戏并安装它们。")
                                .bcdFont(.body, 14).foregroundStyle(BCDStyle.textSoft)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    BCDSectionKit.ActionButton(title: "登录 Epic Games", symbol: "person.crop.circle.badge.plus", kind: .primary,
                                               fill: true, id: Self.prefix + "epic.signin") { backend.signInEpic() }
                    BCDSectionKit.Note(text: "You sign in on Epic's own page: BCD never sees your password. Signing in with Google, Apple or a console account? Epic's page may turn it away inside BCD; then tap Use Safari at the top of Epic's sign-in page.",
                                       symbol: "safari")
                }
            }
        }
    }

    /// Epic's sign-out happens only from here, after the question.
    private var epicSignOutQuestion: some View {
        BCDSectionKit.Confirm(
            title: "退出 Epic Games 登录？",
            message: "BCD ends its Epic sign-in on this \(BCDSectionKit.deviceWord) and forgets the list of your Epic games.",
            choices: [
                .init(title: "退出登录", kind: .danger, id: Self.prefix + "epic.signout.confirm") {
                    confirmingEpicSignOut = false
                    backend.signOutEpic()
                    if focus.controllerActive { focus.focused = Self.prefix + "epic.signin" }
                },
                .init(title: "取消", kind: .outline, id: Self.prefix + "epic.signout.cancel") {
                    confirmingEpicSignOut = false
                    if focus.controllerActive { focus.focused = Self.prefix + "epic.signout" }
                },
            ])
    }

    private var keptNote: some View {
        BCDSectionKit.Card(eyebrow: "What BCD keeps", symbol: "lock.fill") {
            Text("Your password goes to Steam and nowhere else; BCD never saves it. Once you're in, BCD keeps Steam's sign-in token in this \(BCDSectionKit.deviceWord)'s Keychain until you sign out.")
                .bcdFont(.body, 14).foregroundStyle(BCDStyle.textSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - BCD's Steam sign-in page

/// Sign in to Steam with the account name and password (then Steam Guard: a code, or an
/// approval in the Steam app), or with a QR code scanned by the Steam app. The password
/// lives only in this page's field: it goes to the backend once, on Sign in, and the field
/// is emptied at once.
struct BCDSteamSignInPage<Backend: BCDAccountsBackend>: View {
    @ObservedObject var backend: Backend
    let scrolls: Bool
    let done: () -> Void
    @EnvironmentObject private var focus: BCDFocus
    @State private var qr: Bool
    @State private var account = ""
    @State private var password = ""
    @State private var code = ""
    @FocusState private var field: Field?
    private enum Field { case account, password, code }

    init(backend: Backend, startWithQR: Bool, scrolls: Bool = true, done: @escaping () -> Void) {
        self.backend = backend
        self.scrolls = scrolls
        self.done = done
        _qr = State(initialValue: startWithQR)
    }

    private static var prefix: String { "settings.accounts.signin." }

    var body: some View {
        BCDSectionKit.Page(title: "登录 Steam",
                           subtitle: "BCD 直接与 Steam 通信。请选择适合你的方式。",
                           scrolls: scrolls, focusPrefix: "settings.accounts.", back: leave) {
            let progress = backend.signInProgress
            if let steamGuard = progress.steamGuard {
                BCDSectionKit.Columns {
                    guardCard(steamGuard, busy: progress.busy)
                } right: {
                    errorAndNote(progress.error)
                }
            } else {
                BCDSectionKit.Segments(options: [(value: false, title: "账号名称"), (value: true, title: "二维码")],
                                       selected: qr, idPrefix: Self.prefix + "mode.") { switchTo(qr: $0) }
                    .frame(maxWidth: 420)
                if qr {
                    // The code and its steps take the page's width, side by side when there is room.
                    qrCard(progress)
                    errorAndNote(progress.error)
                } else {
                    BCDSectionKit.Columns {
                        passwordCard(busy: progress.busy)
                    } right: {
                        errorAndNote(progress.error)
                    }
                }
            }
        }
        .onAppear {
            backend.clearSignInError()
            guard backend.steam.accountName == nil else { return }
            if qr { backend.beginQR() } else { putCursorInAccountField() }
        }
        .onDisappear {
            password = ""
            code = ""
            if backend.steam.accountName == nil { backend.cancelSignIn() }
        }
        .onChange(of: backend.steam.accountName) { _, name in
            if name != nil { done() }
        }
        .onChange(of: backend.signInProgress.steamGuard) { _, steamGuard in
            if steamGuard?.code != nil {
                field = .code
                if focus.controllerActive { focus.focused = Self.prefix + "code" }
            }
        }
    }

    private func leave() {
        password = ""
        backend.cancelSignIn()
        done()
    }

    private func switchTo(qr wanted: Bool) {
        guard wanted != qr else { return }
        qr = wanted
        backend.clearSignInError()
        if wanted {
            password = ""
            field = nil
            backend.beginQR()
        } else {
            backend.cancelSignIn()
            putCursorInAccountField()
        }
    }

    /// With touch, the cursor waits in the account name, as a sign-in form should. With a
    /// controller the keyboard stays down until A on the field asks for it.
    private func putCursorInAccountField() {
        guard !focus.controllerActive else { return }
        DispatchQueue.main.async { field = .account }
    }

    // MARK: Account name and password

    private func passwordCard(busy: Bool) -> some View {
        BCDSectionKit.Card(eyebrow: "Your Steam account", symbol: "person.fill") {
            BCDSectionKit.FieldBox(id: Self.prefix + "account", activate: { field = .account }) {
                TextField("", text: $account, prompt: Text("账号名称").foregroundStyle(BCDStyle.textSoft))
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($field, equals: .account)
                    .submitLabel(.next)
                    .onSubmit { field = .password }
            }
            BCDSectionKit.FieldBox(id: Self.prefix + "password", activate: { field = .password }) {
                SecureField("", text: $password, prompt: Text("密码").foregroundStyle(BCDStyle.textSoft))
                    .textContentType(.password)
                    .focused($field, equals: .password)
                    .submitLabel(.go)
                    .onSubmit(submit)
            }
            Text("这是你登录 Steam 所用的名称，通常不是你的电子邮箱地址。")
                .bcdFont(.body, 13).foregroundStyle(BCDStyle.textSoft)
                .fixedSize(horizontal: false, vertical: true)
            BCDSectionKit.ActionButton(title: busy ? "Signing in…" : "登录", symbol: busy ? "hourglass" : "arrow.right",
                                       kind: .primary, fill: true, id: Self.prefix + "submit",
                                       enabled: canSubmit && !busy, action: submit)
        }
    }

    private var canSubmit: Bool {
        !account.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !password.isEmpty
    }

    /// The only place the password leaves this page: once, to the backend, then it is gone.
    private func submit() {
        guard canSubmit, !backend.signInProgress.busy else { return }
        let name = account.trimmingCharacters(in: .whitespacesAndNewlines)
        backend.signIn(account: name, password: password)
        password = ""
        field = nil
    }

    // MARK: Steam Guard

    private func guardCard(_ steamGuard: BCDSteamGuard, busy: Bool) -> some View {
        BCDSectionKit.Card(eyebrow: "Steam Guard", symbol: "checkmark.shield", accent: true) {
            if let kind = steamGuard.code {
                Text(guardText(kind)).bcdFont(.body, 16).fixedSize(horizontal: false, vertical: true)
                BCDSectionKit.FieldBox(id: Self.prefix + "code", activate: { field = .code }) {
                    TextField("", text: $code, prompt: Text("代码").foregroundStyle(BCDStyle.textSoft))
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .focused($field, equals: .code)
                        .submitLabel(.go)
                        .onSubmit(sendCode)
                }
                BCDSectionKit.ActionButton(title: busy ? "检查中…" : "继续", symbol: busy ? "hourglass" : "arrow.right",
                                           kind: .primary, fill: true, id: Self.prefix + "code.submit",
                                           enabled: codeReady && !busy, action: sendCode)
                if steamGuard.canApprove {
                    BCDSectionKit.Note(text: "或在 Steam App 中确认登录。确认后 BCD 会自动继续。",
                                       symbol: "iphone")
                }
            } else {
                BCDSectionKit.Headline(text: "在 Steam App 中确认", symbol: "iphone", tone: .info,
                                       detail: "Steam sent this sign-in to the Steam app on your phone. Approve it there and BCD carries on by itself.")
            }
            BCDSectionKit.ActionButton(title: "重新开始", symbol: "arrow.uturn.backward", kind: .quiet,
                                       id: Self.prefix + "restart") {
                code = ""
                backend.cancelSignIn()
                if focus.controllerActive { focus.focused = Self.prefix + "mode.0" }
            }
        }
    }

    private func guardText(_ kind: BCDSteamGuard.Code) -> String {
        switch kind {
        case .steamApp:
            return "Open the Steam app on your phone and type the code it shows."
        case .email(let hint):
            return hint.isEmpty ? "Steam emailed you a code. Type it here."
                                : "Steam emailed a code to your address at \(hint). Type it here."
        }
    }

    private var codeReady: Bool { code.trimmingCharacters(in: .whitespaces).count >= 5 }

    private func sendCode() {
        guard codeReady, !backend.signInProgress.busy else { return }
        backend.submitGuardCode(code.trimmingCharacters(in: .whitespaces))
    }

    // MARK: QR code

    private func qrCard(_ progress: BCDSteamSignIn) -> some View {
        BCDSectionKit.Card(eyebrow: "Sign in with your phone", symbol: "qrcode") {
            if let image = progress.qrImage {
                BCDSectionKit.ColumnsLayout(spacing: 18, minimumWide: 440) {
                    Image(uiImage: image)
                        .interpolation(.none).resizable().scaledToFit()
                        .frame(width: 180, height: 180)
                        .padding(12)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("登录 Steam 的二维码")
                    VStack(alignment: .leading, spacing: 14) {
                        BCDSectionKit.Steps(steps: [
                            .init(id: 1, text: "在手机上打开 **Steam** App。"),
                            .init(id: 2, text: "点 **Steam Guard**，然后扫描此二维码。"),
                            .init(id: 3, text: "确认登录后，BCD 会自动继续。"),
                        ])
                        if let link = progress.qrLink {
                            BCDSectionKit.ActionButton(title: "Use the Steam app on this \(BCDSectionKit.deviceWord)",
                                                       symbol: "arrow.up.forward.app", kind: .outline, fill: true,
                                                       id: Self.prefix + "qr.app") {
                                UIApplication.shared.open(link)
                            }
                        }
                        BCDSectionKit.Note(text: "正在等待 Steam App…", symbol: "hourglass")
                    }
                }
            } else if progress.busy {
                BCDSectionKit.Note(text: "正在向 Steam 请求验证码…", symbol: "hourglass")
            } else {
                Text("代码尚未就绪或已超时。").bcdFont(.body, 15).foregroundStyle(BCDStyle.textSoft)
                BCDSectionKit.ActionButton(title: "获取新代码", symbol: "arrow.clockwise", kind: .primary, fill: true,
                                           id: Self.prefix + "qr.again") { backend.beginQR() }
            }
        }
    }

    // MARK: Beside the form

    @ViewBuilder private func errorAndNote(_ error: String?) -> some View {
        if let error {
            BCDSectionKit.Card(eyebrow: "That didn't work", symbol: "exclamationmark.triangle.fill") {
                BCDSectionKit.Note(text: error, symbol: "exclamationmark.triangle.fill", tone: .bad)
            }
        }
        BCDSectionKit.Card(eyebrow: "What BCD keeps", symbol: "lock.fill") {
            Text("Your password goes to Steam and nowhere else; BCD never saves it. Once you're in, BCD keeps Steam's sign-in token in this \(BCDSectionKit.deviceWord)'s Keychain until you sign out.")
                .bcdFont(.body, 14).foregroundStyle(BCDStyle.textSoft)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
