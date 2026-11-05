// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// A game's setup on its page (round 604): the sections "Windows", "组件", "CPU 指令翻译", "游戏修复" and "Wine 桌面"
// of Options, in BCD's words. No views and no engine types, like the save backups page: the live backend
// (BCDGameSetup/BCDGamePageLiveSetup.swift) fills the state in from the game's own file and the folder, the page's own lists draw
// the sections from the settings below, and the preview app can build them from sample states.
//
// Every row is a line of the game's own file, so nothing here changes how a game that was never set up starts: a section's
// default is "no line". Rows that change what a start does say when they take effect (the next start).

/// One game fix as the page lists it.
struct BCDSetupFixItem: Equatable, Identifiable {
    var number: Int
    var enabled: Bool
    var summary: String
    /// Why the fix cannot run, or nil.
    var problem: String?
    var id: Int { number }
}

/// What the Components section shows.
struct BCDSetupDllState: Equatable {
    /// The names (lower case) the game's file lists in env.MADEIRA_APP_DLL_SHADOW.
    var shadow: [String] = []
    /// The DLLs of the components that the game's own folder holds, as the disk spells them.
    var shipped: [String] = []
    /// The DLLs the file switches off (env.WINEDLLOVERRIDES entries with no mode).
    var off: [String] = []
    /// What BCD's Runtimes installer says is installed (BCDRuntimes status file), or nil when it never ran.
    var runtimes: [String]?
}

/// What the Wine desktop section shows.
struct BCDSetupDesktopState: Equatable {
    var dpi = ""
    var theme = ""
    var wallpaper = ""
}

/// One save folder BCD knows for the game, and where it is.
struct BCDSetupSaveItem: Equatable, Identifiable {
    enum Place: Equatable {
        /// A folder inside the prefix, where Windows programs expect it.
        case prefix
        /// Moved to Files › BCD › Game Saves; a link stands in the prefix.
        case files
        /// Moved, and the prefix lost its link (it was reset): the next start of the game makes it again.
        case needsLink
        /// Not in the prefix (yet).
        case missing
    }
    /// The folder, relative to drive_c.
    var path: String
    /// "Documents › My Games › Foo", never the Windows user's name.
    var label: String
    var place: Place
    var id: String { path }
}

/// Everything the sections need.
struct BCDGameSetupState: Equatable {
    var windowsVersion = ""
    var is64Bit = false
    var fixes: [BCDSetupFixItem] = []
    var fixProblems: [String] = []
    var fexPreset = ""
    var smcFull = false
    var dll = BCDSetupDllState()
    /// nil: this game does not start as a Wine desktop (the section is left out).
    var desktop: BCDSetupDesktopState?
    /// The folders BCD found the game saving in that can live outside the prefix (BCDSaveRedirect.isEligible).
    var saves: [BCDSetupSaveItem] = []
    /// Why a save folder cannot be moved now (a game is running), or nil.
    var savesBlocked: String?
    /// What an action last said, by setting id.
    var notes: [String: String] = [:]
}

enum BCDGameSetupPage {
    static let windowsGroup = "windows"
    static let componentsGroup = "components"
    static let fexGroup = "fex"
    static let fixesGroup = "fixes"
    static let desktopGroup = "desktop"

    static let version = "setup.version"
    static let componentsPrefix = "setup.dll."
    static let dllOff = "setup.dll-off"
    static let dll32 = "setup.dll-32bit"
    static let runtimes = "setup.runtimes"
    static let fex = "setup.fex"
    static let smc = "setup.fex-smc"
    static let fixAdd = "setup.fix-add"
    static let fixPrefix = "setup.fix."
    static let saveGroup = "saveplace"
    static let savePrefix = "setup.saves:"
    static let exeIcon = "setup.exeicon"
    static let desktopDPI = "setup.desktop-dpi"
    static let desktopTheme = "setup.desktop-theme"
    static let desktopWallpaper = "setup.desktop-wallpaper"
    static let wallpaperPicture = "setup.desktop-picture"

    static func fixID(_ number: Int) -> String { fixPrefix + String(number) }
    static func fixNumber(_ id: String) -> Int? { id.hasPrefix(fixPrefix) ? Int(id.dropFirst(fixPrefix.count)) : nil }

    // MARK: Windows

    static func windowsSection(_ s: BCDGameSetupState) -> BCDGameSettingGroup {
        var versions = BCDWindowsVersion.all.map { BCDGameChoice(value: $0.id, label: $0.label) }
        if !versions.contains(where: { $0.value == s.windowsVersion }) { versions.append(BCDGameChoice(value: s.windowsVersion, label: s.windowsVersion)) }
        let components = componentsSummary(s.dll)
        let list: [BCDGameSetting] = [
            BCDGameSetting(id: version, title: "Windows 版本", kind: .choice(versions), value: s.windowsVersion, defaultValue: "",
                           note: s.notes[version] ?? "The Windows version this game's programs are told they run on. Older games often ask for XP or 7. It reaches the programs the game starts from its folder, from the next start."),
            BCDGameSetting(id: "setup.components", title: "组件", kind: .opens(.section(componentsGroup)), value: components, defaultValue: "As the games have them",
                           note: "游戏使用哪些 DLL：其自带副本，还是 BCD 提供的副本。"),
        ]
        let name = BCDWindowsVersion.entry(s.windowsVersion)?.label ?? s.windowsVersion
        return BCDGameSettingGroup(id: windowsGroup, title: "Windows", symbol: "macwindow", settings: list,
                                   headline: s.windowsVersion.isEmpty ? "Windows 10" : name)
    }

    static func componentsSummary(_ d: BCDSetupDllState) -> String {
        let wines = BCDDllComponents.all.filter { BCDDllComponents.isWines($0, shadow: d.shadow) }.count
        let parts = [wines == 0 ? nil : "\(wines) set to Wine's own", d.off.isEmpty ? nil : "\(d.off.count) switched off"].compactMap { $0 }
        return parts.isEmpty ? "As the games have them" : parts.joined(separator: " · ")
    }

    static func componentsSection(_ s: BCDGameSetupState) -> BCDGameSettingGroup {
        let d = s.dll
        var list: [BCDGameSetting] = []
        if !s.is64Bit {
            // One line for all: a 32-bit game loads a DLL from its own folder first, which the engine's switch cannot change yet.
            let ships = d.shipped.isEmpty ? "" : " This game ships " + d.shipped.prefix(6).joined(separator: ", ") + (d.shipped.count > 6 ? " and \(d.shipped.count - 6) more." : ".")
            list.append(BCDGameSetting(id: dll32, title: "Wine 自带的副本", kind: .info, value: "64-bit games only",
                                       note: "32 位游戏会优先从自己的文件夹加载 DLL，而非 Wine 的，BCD 目前还无法更改这一点。" + ships))
        } else {
            for (index, component) in BCDDllComponents.all.enumerated() {
                let mine = Set(component.names)
                let own = d.shipped.filter { mine.contains($0.lowercased()) }
                let wines = BCDDllComponents.isWines(component, shadow: d.shadow)
                let ships = own.isEmpty ? "The game's folder has none of these." : "The game ships " + own.prefix(6).joined(separator: ", ") + (own.count > 6 ? " and \(own.count - 6) more." : ".")
                list.append(BCDGameSetting(
                    id: componentsPrefix + component.id, title: component.title,
                    kind: .choice([BCDGameChoice(value: "", label: "游戏自带"), BCDGameChoice(value: "wine", label: "Wine 自带")]),
                    value: wines ? "wine" : "", defaultValue: "",
                    note: s.notes[componentsPrefix + component.id] ?? (component.note + " " + ships),
                    heading: index == 0 ? "Which copy a game uses" : nil))
            }
        }
        list.append(BCDGameSetting(
            id: dllOff, title: "已关闭", kind: .text(prompt: "dsound.dll;mfplat.dll"), value: d.off.joined(separator: ";"),
            note: s.notes[dllOff] ?? "DLLs the game cannot load at all, separated by semicolons, for a game that fails in one of them (a sound or video library, say). Empty: none. From the next start.",
            heading: "Switch a DLL off"))
        list.append(BCDGameSetting(
            id: runtimes, title: "已安装运行库", kind: .info,
            value: d.runtimes.map { $0.isEmpty ? "无" : $0.joined(separator: ", ") } ?? "None installed yet",
            note: "来自开始菜单中的 BCD Runtimes 文件夹（XNA、PhysX、OpenAL、DirectX 2010 年 6 月版），其文件保留在前缀中供所有游戏使用。",
            heading: "Installed for every game"))
        return BCDGameSettingGroup(id: componentsGroup, title: "组件", symbol: "puzzlepiece.extension", settings: list,
                                   note: "自带 DLL 的游戏会优先加载自己的副本。若因此导致游戏出问题，可强制使用 Wine 自带的副本。",
                                   headline: componentsSummary(d), parent: windowsGroup)
    }

    // MARK: CPU translation

    static func fexSection(_ s: BCDGameSetupState) -> BCDGameSettingGroup {
        var choices = [BCDGameChoice(value: "", label: "BCD 自行决定")]
        choices += BCDFEXPresets.all.map { BCDGameChoice(value: $0.id, label: $0.title) }
        if s.fexPreset == "custom" { choices.append(BCDGameChoice(value: "custom", label: "自定义：由游戏自身的文件指定")) }
        let preset = BCDFEXPresets.all.first { $0.id == s.fexPreset }
        let list: [BCDGameSetting] = [
            BCDGameSetting(id: fex, title: "内存顺序与内存块", kind: .choice(choices), value: s.fexPreset, defaultValue: "",
                           note: s.notes[fex] ?? (preset?.note ?? "How the emulator keeps x86's memory order and how it translates code. BCD's own choice writes nothing. A preset writes five lines (FEX_TSOENABLED, FEX_VECTORTSOENABLED, FEX_MEMCPYSETTSOENABLED, FEX_HALFBARRIERTSOENABLED, FEX_MULTIBLOCK) to the game's file, where Game config shows them. From the next start.")),
            BCDGameSetting(id: smc, title: "检查自修改代码", kind: .toggle, value: s.smcFull ? "1" : "0", defaultValue: "0",
                           note: "模拟器在每次执行前检查程序代码是否被程序自身修改。较慢。仅用于会自行修改内存中代码的游戏；大多数游戏不会。"),
        ]
        return BCDGameSettingGroup(id: fexGroup, title: "CPU 指令翻译", symbol: "cpu", settings: list,
                                   headline: s.smcFull ? (preset?.title ?? "BCD 自行决定") + " · self-modifying code" : (preset?.title ?? (s.fexPreset == "custom" ? "Custom" : "BCD 自行决定")))
    }

    // MARK: Saves outside the prefix

    static func moveQuestion(_ item: BCDSetupSaveItem) -> BCDGameQuestion {
        BCDGameQuestion(title: "Move \"\(item.label)\" out of the prefix?",
                        message: "BCD moves the folder into Files › BCD › Game Saves and leaves a link where it was, so the game opens the same path as before. Resetting or removing the prefix then leaves the saves alone, and Files shows them. Moving them back is one tap here. Nothing is deleted. Quit the game first.",
                        confirm: "Move out", destructive: false)
    }

    static func backQuestion(_ item: BCDSetupSaveItem) -> BCDGameQuestion {
        BCDGameQuestion(title: "Move \"\(item.label)\" back into the prefix?",
                        message: "链接会被移除，文件夹回到 Windows 程序通常保存它的位置。如果游戏在此期间在那里创建了自己的文件夹，则不做移动。",
                        confirm: "Move back", destructive: false)
    }

    static func savesSection(_ s: BCDGameSetupState) -> BCDGameSettingGroup? {
        guard !s.saves.isEmpty else { return nil }
        var list: [BCDGameSetting] = []
        for (index, item) in s.saves.enumerated() {
            let id = savePrefix + item.path
            let heading = index == 0 ? "Save folders BCD found" : nil
            if item.place == .missing {
                list.append(BCDGameSetting(id: id, title: item.label, kind: .info, value: "Not in the prefix yet",
                                           note: s.notes[id] ?? "The folder is not there now; the game makes it when it saves.", heading: heading))
                continue
            }
            let outside = item.place == .files || item.place == .needsLink
            list.append(BCDGameSetting(
                id: id, title: item.label,
                kind: .choice([BCDGameChoice(value: "prefix", label: "Windows 前缀", question: outside ? backQuestion(item) : nil),
                               BCDGameChoice(value: "files", label: "文件", question: outside ? nil : moveQuestion(item))]),
                value: outside ? "files" : "prefix", defaultValue: "prefix",
                note: s.notes[id] ?? s.savesBlocked ?? (item.place == .needsLink ? "Outside the prefix. The prefix lost its link; the game's next start makes it again."
                                                         : outside ? "Outside the prefix, in Files › BCD › Game Saves." : "Inside the prefix, where Windows programs keep it."),
                heading: heading))
        }
        let outside = s.saves.filter { $0.place == .files || $0.place == .needsLink }.count
        return BCDGameSettingGroup(id: saveGroup, title: "存档所在位置", symbol: "folder.badge.gearshape", settings: list,
                                   note: "BCD 会在运行过程中学习游戏的存档文件夹（存档备份 › 查找存档位置）。移出前缀的文件夹在前缀重置后仍然保留。",
                                   headline: outside == 0 ? "In the prefix" : "\(outside) of \(s.saves.count) outside the prefix")
    }

    /// The Library section's extra row for a game with a program and no store picture (round 604): the program's icon as its cover.
    static func exeIconRow(_ notes: [String: String]) -> BCDGameSetting {
        BCDGameSetting(id: exeIcon, title: "用程序图标作为封面", kind: .action,
                       note: notes[exeIcon] ?? "Takes the biggest icon out of the game's program and makes a cover picture of it, for a game with no store picture. The program is only read.")
    }

    // MARK: Game fixes

    static let addQuestionNote = "One line, as in the example: ini, ini-remove, reg, reg-delete, delete, write or redist, then its places and values. %GAME%, %DOCUMENTS%, %APPDATA% and %LOCALAPPDATA% stand for those folders. A fix never changes a program."

    static func removeQuestion(_ item: BCDSetupFixItem) -> BCDGameQuestion {
        BCDGameQuestion(title: "移除此修复？", message: item.summary + "\n\nThe line leaves the game's file. What the fix already changed stays; the first original of a file it changed is in Files › BCD › Fix Backups.",
                        confirm: "移除", destructive: true)
    }

    static func fixesSection(_ s: BCDGameSetupState) -> BCDGameSettingGroup {
        var list: [BCDGameSetting] = []
        for (index, item) in s.fixes.enumerated() {
            let id = fixID(item.number)
            let state = item.enabled ? "on" : "off"
            list.append(BCDGameSetting(
                id: id, title: item.summary,
                kind: .choice([BCDGameChoice(value: "on", label: "开启"), BCDGameChoice(value: "off", label: "关闭"),
                               BCDGameChoice(value: "remove", label: "移除修复", question: removeQuestion(item))]),
                value: state, defaultValue: "",
                note: s.notes[id] ?? item.problem.map { "Cannot run: \($0)." } ?? (item.enabled ? "Runs before the game starts, each time, and changes nothing that is already as wanted." : "Switched off."),
                heading: index == 0 ? "This game's fixes" : nil))
        }
        for (index, problem) in s.fixProblems.enumerated() {
            list.append(BCDGameSetting(id: "setup.fix-problem.\(index)", title: "BCD 无法识别的行", kind: .info, value: problem))
        }
        if s.fixes.isEmpty && s.fixProblems.isEmpty {
            list.append(BCDGameSetting(id: "setup.fix-none", title: "修复项", kind: .info, value: "无", note: "此游戏尚未设置任何修复项。"))
        }
        list.append(BCDGameSetting(
            id: fixAdd, title: "添加修复", kind: .text(prompt: "ini \"%DOCUMENTS%\\My Games\\Foo\\foo.ini\" Display FullScreen 1"), value: "",
            note: s.notes[fixAdd] ?? addQuestionNote, heading: "New"))
        let on = s.fixes.filter(\.enabled).count
        return BCDGameSettingGroup(id: fixesGroup, title: "游戏修复", symbol: "wrench.and.screwdriver", settings: list,
                                   note: "对游戏 INI 文件、注册表、文件夹及文件的改动，在每次启动前及启动时应用。",
                                   headline: s.fixes.isEmpty ? "无" : "\(on) of \(s.fixes.count) on")
    }

    // MARK: Wine desktop

    static func desktopSection(_ s: BCDGameSetupState) -> BCDGameSettingGroup? {
        guard let d = s.desktop else { return nil }
        var sizes = BCDWineDesktop.dpiChoices.map { BCDGameChoice(value: $0.value, label: $0.label) }
        if !sizes.contains(where: { $0.value == d.dpi }) { sizes.append(BCDGameChoice(value: d.dpi, label: "\(d.dpi) dpi")) }
        let list: [BCDGameSetting] = [
            BCDGameSetting(id: desktopDPI, title: "文字与窗口大小", kind: .choice(sizes), value: d.dpi, defaultValue: "",
                           note: s.notes[desktopDPI] ?? "Windows' DPI setting: larger makes the desktop's text, buttons and title bars bigger. On a phone the Wine desktop is small, so 144 or 192 reads better. Programs that handle DPI draw bigger too. From the next start."),
            BCDGameSetting(id: desktopTheme, title: "颜色", kind: .choice([BCDGameChoice(value: "", label: "浅色（Wine 自带）"), BCDGameChoice(value: "dark", label: "深色")]),
                           value: d.theme, defaultValue: "",
                           note: s.notes[desktopTheme] ?? "Dark sets the system colours of windows and controls. Wine has no Windows theme files, so programs that draw their own look keep it. From the next start."),
            BCDGameSetting(id: wallpaperPicture, title: "选择壁纸图片", kind: .opens(.wallpaperPicture),
                           note: "来自「文件」的图片。BCD 会裁剪到桌面分辨率（Resolution），保存为 C:\\bcd-wallpaper.bmp，并把下面的壁纸设成它。"),
            BCDGameSetting(id: desktopWallpaper, title: "壁纸", kind: .text(prompt: "C:\\bcd-wallpaper.bmp"), value: d.wallpaper,
                           note: s.notes[desktopWallpaper] ?? "A .bmp picture on drive C: drawn centred on the desktop (Wine draws bitmap files only). Empty: none."),
        ]
        let words = [d.dpi.isEmpty ? nil : "\(d.dpi) dpi", d.theme == "dark" ? "dark" : nil, d.wallpaper.isEmpty ? nil : "wallpaper"].compactMap { $0 }
        return BCDGameSettingGroup(id: desktopGroup, title: "Wine 桌面", symbol: "rectangle.on.rectangle", settings: list,
                                   note: "仅当以此 Wine 桌面方式启动时生效。其他启动方式不使用它：BCD 会把注册表恢复原样。",
                                   headline: words.isEmpty ? "As BCD sets it" : words.joined(separator: " · "))
    }

    /// The sections in the order Options lists them (after Compatibility), with the Components section reached from Windows.
    static func sections(_ s: BCDGameSetupState) -> [BCDGameSettingGroup] {
        var out = [windowsSection(s), componentsSection(s), fexSection(s)]
        if let places = savesSection(s) { out.append(places) }
        out.append(fixesSection(s))
        if let desktop = desktopSection(s) { out.append(desktop) }
        return out
    }

    // MARK: Reading what the player typed

    /// The DLL names in the "已关闭" field: the valid ones, lower case, and the words that are not DLL names.
    static func parseOff(_ text: String) -> (names: [String], rejected: [String]) {
        var names: [String] = [], rejected: [String] = []
        for part in text.split(whereSeparator: { ";, \n".contains($0) }) {
            let word = String(part)
            if BCDDllComponents.isDllName(word) { if !names.contains(word.lowercased()) { names.append(word.lowercased()) } } else { rejected.append(word) }
        }
        return (names, rejected)
    }
}
