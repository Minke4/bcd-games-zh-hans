// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// A game's save backups on its page (round 603): the section "存档备份" of Options, in BCD's words. No views and no engine
// types, like BCDGameDLC.swift: the live backend (BCDSaveBackups/BCDGamePageLiveSaves.swift) fills the state in, the page's own
// lists draw the section from the settings below, and the preview app can build it from sample rows.
//
// What the section offers: Back up now; Back up when the game closes (off unless the player turns it on, and it asks first,
// because it replaces the oldest automatic backup once the newest N exist); Find where it saves; where it saves, as the
// player reads it (never the Windows user's name); and one row per backup, which puts it back after a question.
// Nothing here deletes or overwrites a file without the question having been answered yes.

/// One backup in the game's folder.
struct BCDSaveBackupItem: Equatable, Identifiable {
    /// The file's name, which names the backup.
    var id: String
    var date: Date
    /// "Manual", "Automatic" or "Before restore".
    var kind: String
    var bytes: Int64
}

/// What the section shows, filled in by the live backend.
struct BCDSaveBackupsState: Equatable {
    /// The places the game saves, as "Documents › My Games › Foo"; a Steam Cloud entry says so.
    var places: [String] = []
    /// The newest backups (the page shows at most `BCDGameSaves.listLimit`) and how many older ones the folder holds.
    var backups: [BCDSaveBackupItem] = []
    var older = 0
    var automatic = false
    var keep = 5
    /// "Save Backups › Game name", where Files shows the backups.
    var folder = ""
    /// The game has run before, so there is a last session to look at.
    var sessionKnown = false
    /// What an action last said, by setting id.
    var notes: [String: String] = [:]
    /// Setting ids whose work is not finished.
    var busy: Set<String> = []
}

enum BCDGameSaves {
    static let groupID = "savebackups"
    static let now = "savebackups.now"
    static let auto = "savebackups.auto"
    static let find = "savebackups.find"
    static let forget = "savebackups.forget"
    static let places = "savebackups.places"
    static let older = "savebackups.older"
    static let restorePrefix = "savebackups.restore."
    static let listLimit = 20

    static func restoreID(_ name: String) -> String { restorePrefix + name }
    static func backupName(ofRestore id: String) -> String? { id.hasPrefix(restorePrefix) ? String(id.dropFirst(restorePrefix.count)) : nil }

    /// The question before a restore: what is replaced, and what keeps the way back.
    static func restoreQuestion(_ item: BCDSaveBackupItem) -> BCDGameQuestion {
        BCDGameQuestion(title: "Put back the saves from \(BCDFormat.dateTime(item.date))?",
                        message: "此备份中的存档文件会替换游戏存档位置里的同名文件。备份中没有的文件保持不变。BCD 会先为当前内容创建一个「恢复前」备份，以便随时回退。",
                        confirm: "还原", destructive: true)
    }

    /// The question before the backup on close is turned on.
    static func autoQuestion(keep: Int, folder: String) -> BCDGameQuestion {
        BCDGameQuestion(title: "游戏关闭时备份其存档？",
                        message: "After a session in which the game changed its saves, BCD makes an Automatic backup in Files › BCD › \(folder). It keeps the newest \(keep) automatic backups and replaces the oldest one when it makes the next. Backups you make yourself, and the ones made before a restore, are never removed. BCD makes none after the game ended with an error.",
                        confirm: "Turn on", destructive: false)
    }

    static let forgetQuestion = BCDGameQuestion(
        title: "忘记此游戏的存档位置？",
        message: "只会清除 BCD 的记忆，备份会保留。BCD 会在游戏下次运行时重新学习这些位置，或在你选择「查找存档位置」时学习。",
        confirm: "忘记", destructive: true)

    static func headline(_ s: BCDSaveBackupsState) -> String {
        let total = s.backups.count + s.older
        var line = total == 0 ? "No backups yet" : "\(total) backup\(total == 1 ? "" : "s")"
        if s.automatic { line += " · on close" }
        return line
    }

    static func group(_ s: BCDSaveBackupsState) -> BCDGameSettingGroup {
        func note(_ id: String, _ fallback: String) -> String { s.notes[id] ?? fallback }
        var list: [BCDGameSetting] = []

        list.append(BCDGameSetting(
            id: now, title: "立即备份", kind: .action,
            note: note(now, s.busy.contains(now) ? "Packing the saves…"
                       : s.places.isEmpty ? "BCD does not know where this game keeps its saves yet. Play it, save in it and close it, then choose Find where it saves."
                       : "Copies the saves in \(s.places.count) place\(s.places.count == 1 ? "" : "s") into Files › BCD › \(s.folder).")))
        list.append(BCDGameSetting(
            id: auto, title: "游戏关闭时备份",
            kind: .choice([BCDGameChoice(value: "0", label: "关闭"),
                           BCDGameChoice(value: "1", label: "On: keep the newest \(s.keep)", question: autoQuestion(keep: s.keep, folder: s.folder))]),
            value: s.automatic ? "1" : "0", defaultValue: "0",
            note: note(auto, "Looks at the files the game changed while it ran and, when its saves are new, makes an Automatic backup. Nothing runs while you play, and a game that ended with an error is not backed up.")))
        list.append(BCDGameSetting(
            id: find, title: "查找存档位置", kind: .action,
            note: note(find, s.busy.contains(find) ? "Looking at the files the game changed…"
                       : s.sessionKnown ? "Looks for the files this game changed in its last session and remembers their folders."
                       : "Play the game once, save in it and close it. Then BCD can see which files it wrote.")))
        list.append(BCDGameSetting(
            id: places, title: "存档位置", kind: .info,
            value: s.places.isEmpty ? "Not known yet" : s.places.joined(separator: "\n"),
            note: s.places.isEmpty ? nil : "A backup holds every file in these places."))
        if !s.places.isEmpty {
            list.append(BCDGameSetting(id: forget, title: "忘记这些位置", kind: .action,
                                       note: s.notes[forget], question: forgetQuestion, destructive: true))
        }

        if s.backups.isEmpty {
            list.append(BCDGameSetting(id: "savebackups.none", title: "备份", kind: .info, value: "None yet",
                                       note: "点击「立即备份」即可创建第一个备份。", heading: "备份"))
        }
        for (index, item) in s.backups.prefix(listLimit).enumerated() {
            let detail = "\(item.kind) · \(BCDFormat.bytes(item.bytes))"
            list.append(BCDGameSetting(
                id: restoreID(item.id), title: BCDFormat.dateTime(item.date), kind: .action,
                note: s.notes[restoreID(item.id)] ?? (s.busy.contains(restoreID(item.id)) ? "Putting the saves back…" : detail + " · choose it to put it back"),
                question: restoreQuestion(item), heading: index == 0 ? "备份" : nil))
        }
        if s.older > 0 {
            list.append(BCDGameSetting(id: older, title: "较早的备份", kind: .info, value: "\(s.older) more",
                                       note: "They stay in Files › BCD › \(s.folder)."))
        }
        return BCDGameSettingGroup(id: groupID, title: "存档备份", symbol: "clock.arrow.circlepath", settings: list,
                                   headline: headline(s))
    }
}
