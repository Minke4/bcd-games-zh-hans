// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import SwiftUI
import UniformTypeIdentifiers

// Settings › Storage › Windows prefix (round 604): copies of the prefix's own part, an export to Files, an import, a fresh registry and
// Wine's system files put back. The words and rows are here and know nothing of the engine: the live backend
// (BCDGameSetup/BCDPrefixToolsLive.swift) does the work (BCDGameSetup/BCDPrefixKit.swift says what the "own part" is), and the preview
// app can show the group from a sample backend.
//
// What every row says it does is what it does: nothing here touches a game, and nothing runs while a game does. Every action that
// replaces something asks first, and makes a copy of what it replaces first ("Before ...") that stays in Files › BCD › Prefix Copies.

struct BCDPrefixCopyItem: Identifiable, Equatable {
    var id: String
    var made: Date?
}

@MainActor protocol BCDPrefixBackend: ObservableObject {
    var busy: Bool { get }
    var message: String? { get }
    var copies: [BCDPrefixCopyItem] { get }
    /// Why the tools cannot run now (a game is running or starting), or nil.
    var blocked: String? { get }
    func refresh()
    func makeCopy()
    func putBack(_ id: String)
    func deleteCopy(_ id: String)
    func exportKit()
    /// What the zip holds ("made on ..., 1 user, 312 files"), or why it is not one BCD's export made.
    func describeImport(_ url: URL) -> String
    func importKit(from url: URL)
    func reconfigure()
    func reinstallSystemFiles()
}

enum BCDPrefixWords {
    static let groupFooter = "A copy keeps the part of the prefix that is yours: the registry, the users' folders and C:\\ProgramData, without caches. Games and Wine's own files are not in it. Everything here waits while a game runs, and each change that replaces something first makes a \"Before\" copy that stays in Files › BCD › Prefix Copies."

    static func copyQuestion(_ item: BCDPrefixCopyItem) -> (title: String, message: String) {
        ("Put back the copy \"\(item.id)\"?",
         "The registry and the users' files in the copy replace the files with the same names in the prefix. Files the copy does not hold stay. BCD makes a \"Before put back\" copy of what is there now first. Games are not touched.")
    }

    static let reconfigureQuestion = (
        title: "使用全新的注册表启动？",
        message: "The three registry files go back to what BCD ships: Wine's defaults, without what installers and games added (their settings in the registry, installed runtimes' entries). Users' folders, saves, games and Wine's files stay. BCD makes a \"Before reconfigure\" copy first, and refuses when this prefix's Windows user is not the one the fresh registry names.")

    static let reinstallQuestion = (
        title: "还原 Wine 的系统文件？",
        message: "BCD 自带且在前缀中缺失或为空的 C:\\windows 文件会被恢复（字体、inf 文件、win.ini 等）。已存在的文件不会被替换，注册表保持不变。Wine 的 DLL 本来每次启动都会重新链接。")

    static func importQuestion(_ summary: String) -> (title: String, message: String) {
        ("Import this prefix export?",
         summary + "\n\nIts registry files and users' files replace the files with the same names in the prefix; other files stay. BCD makes a \"Before import\" copy first. Games are not part of an export.")
    }
}

struct BCDPrefixToolsGroup<Backend: BCDPrefixBackend>: View {
    @ObservedObject var backend: Backend
    @EnvironmentObject private var model: BCDSettingsModel
    @State private var importing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BCDSettingsGroup(title: "Windows 前缀", footer: BCDPrefixWords.groupFooter) {
                BCDSettingsActionRow(id: BCDSettingsID.control(.storage, "prefix-copy"), title: backend.busy ? "Working…" : "Make a copy now",
                                     note: backend.blocked ?? backend.message, symbol: "doc.on.doc", enabled: enabled) { backend.makeCopy() }
                ForEach(backend.copies) { item in copyRow(item) }
                BCDSettingsActionRow(id: BCDSettingsID.control(.storage, "prefix-export"), title: "导出到「文件」",
                                     note: "同一部分的 zip 包，供其他设备使用，位于「文件 › BCD › Prefix Exports」。", symbol: "square.and.arrow.up", enabled: enabled) {
                    backend.exportKit()
                }
                BCDSettingsActionRow(id: BCDSettingsID.control(.storage, "prefix-import"), title: "导入导出包",
                                     note: "选择一个由 BCD 导出的 zip。", symbol: "square.and.arrow.down", enabled: enabled) { importing = true }
                BCDSettingsActionRow(id: BCDSettingsID.control(.storage, "prefix-reconfigure"), title: "使用全新的注册表启动",
                                     note: "下次启动时将使用 BCD 内置的注册表。", symbol: "arrow.counterclockwise", enabled: enabled) {
                    let q = BCDPrefixWords.reconfigureQuestion
                    model.ask(BCDSettingsConfirm(title: q.title, message: q.message, choices: [.init(title: "全新开始", destructive: true) { backend.reconfigure() }]))
                }
                BCDSettingsActionRow(id: BCDSettingsID.control(.storage, "prefix-system"), title: "还原 Wine 的系统文件",
                                     note: "恢复 C:\\windows 中缺失或为空的文件。", symbol: "wrench.and.screwdriver", enabled: enabled) {
                    let q = BCDPrefixWords.reinstallQuestion
                    model.ask(BCDSettingsConfirm(title: q.title, message: q.message, choices: [.init(title: "还原") { backend.reinstallSystemFiles() }]))
                }
            }
        }
        .onAppear { backend.refresh() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
            guard case .success(let url) = result else { return }
            let summary = backend.describeImport(url)
            let q = BCDPrefixWords.importQuestion(summary)
            model.ask(BCDSettingsConfirm(title: q.title, message: q.message, choices: [.init(title: "导入", destructive: true) { backend.importKit(from: url) }]))
        }
    }

    private var enabled: Bool { !backend.busy && backend.blocked == nil }

    private func copyRow(_ item: BCDPrefixCopyItem) -> some View {
        BCDSettingsActionRow(id: BCDSettingsID.control(.storage, "prefix-copy." + item.id), title: item.id,
                             note: "前缀自身部分的副本。选中即可还原或删除。", detail: item.made.map { BCDFormat.dateTime($0) },
                             symbol: "clock.arrow.circlepath", enabled: enabled) {
            let q = BCDPrefixWords.copyQuestion(item)
            model.ask(BCDSettingsConfirm(title: q.title, message: q.message, choices: [
                .init(title: "还原此副本", destructive: true) { backend.putBack(item.id) },
                .init(title: "删除此副本", destructive: true) { backend.deleteCopy(item.id) },
            ]))
        }
    }
}
