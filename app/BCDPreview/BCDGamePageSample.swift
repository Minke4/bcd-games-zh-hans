// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation
import SwiftUI

/// The game page's sample backend for the preview app: every section of Options, Steam Cloud,
/// recommended settings, auto-tune, saves and logs for the sample library (BCDPreviewData.swift),
/// kept in memory. Only the preview app compiles this file; the app's backend is BCDGamePageLive.
@MainActor final class BCDGamePageSample: BCDGameDetailBackend {
    var onChange: (() -> Void)?
    var onNotice: (() -> Void)?
    /// Settings changed in the preview, by game and setting.
    private var values: [String: [String: String]] = [:]
    private var cloud: [String: BCDCloudSaves] = ["367520": .synced(matching: 3), "271590": .differ(2)]
    private var tuning: [String: BCDGameTuning] = ["wc3": BCDGameTuning(
        on: true, status: "Found: dxmt = d3d9.deferSurfaceCreation=1", canUndo: true, found: ["dxmt = d3d9.deferSurfaceCreation=1"],
        history: [(title: "d9-surface-defer", detail: "reached play · stage 4 · 312 s · 18,420 frames · kept\ndxmt = d3d9.deferSurfaceCreation=1"),
                  (title: "First run", detail: "crashed · stage 2 · 14 s · 0 frames")])]
    private var recommendedApplied = Set<String>()
    /// Steam DLC for the sample games (BCDGameDLC.swift): the DLC the sample account owns, which are installed and which the
    /// switches say. The sample's offer before a first install is asked once, as the app asks it.
    private static let dlcOwned: [String: [(id: UInt32, name: String, bytes: Int64)]] = [
        "367520": [(1, "Character Pack", 410_000_000), (2, "Story Expansion", 1_900_000_000), (3, "Bonus Maps", 260_000_000),
                   (4, "Soundtrack Edition Content", 95_000_000)],
        // A long list, for the chooser (the real ones: The Witcher 3 has 18 DLC, X-Plane 12 several maps of many GB each).
        "620": [(11, "Co-op Levels", 1_200_000_000), (12, "Bonus Campaign", 3_400_000_000), (13, "Europe Scenery", 6_800_000_000),
                (14, "Asia Scenery", 5_100_000_000), (15, "Aircraft Pack: Classics", 2_300_000_000), (16, "Aircraft Pack: Airliners", 4_900_000_000),
                (17, "Weather Add-on", 310_000_000), (18, "Hair and Beard Pack", 12_000_000), (19, "Soundtrack Content", 95_000_000),
                (20, "Anniversary Skins", 41_000_000), (21, "Night Lights", 780_000_000), (22, "Winter Maps", 1_600_000_000),
                (23, "Harbour Missions", 2_050_000_000), (24, "Director's Cut Extras", 530_000_000)],
    ]
    private var dlcInstalled: [String: Set<UInt32>] = ["367520": [1, 2]]
    private var dlcWanted: [String: Set<UInt32>] = [:]
    private var dlcAsked = Set<String>()
    /// Round 604's input choices (BCDInputPage.swift) for the sample games: game -> feature -> line -> value.
    private var inputLines: [String: [String: [String: String]]] = [:]
    private func inputProfile(_ game: BCDGame) -> BCDInputProfile { BCDInputProfile(lines: inputLines[game.id] ?? [:]) }

    private func value(_ game: BCDGame, _ id: String, _ fallback: String) -> String { values[game.id]?[id] ?? fallback }

    func details(for game: BCDGame, settings: Bool) -> BCDGameDetails {
        let steam = game.store == .steam
        var d = BCDGameDetails()
        if steam { d.storePage = URL(string: "https://store.steampowered.com/app/\(game.id)/") }
        if steam, case .notInstalled = game.state, !dlcAsked.contains(game.id), let owned = Self.dlcOwned[game.id] {
            // -BCDTab game-620-checking: the lookup is still running, so Install shows "正在检查 DLC…".
            if UserDefaults.standard.string(forKey: "BCDTab") == "game-\(game.id)-checking" {
                d.dlcCheck = .checking
            } else {
                d.dlcOffer = BCDDLCOffer(items: owned.map { BCDDLCOfferItem(id: $0.id, name: $0.name, bytes: $0.bytes) })
            }
        }
        // Epic: what BCD says before Install, in BCDEpicRules' words (the engine's file is not in the preview; check-epic.py holds these
        // strings to the real ones). Milestone 2: an ownership-token game installs (BCD starts it signed in) with a note, a game that
        // must be online says BCD signs it in, and GTA V's BattlEye is an explicit exception with its reason.
        switch game.id {
        case "epic.rally": d.installBlocker = "This game comes with anti-cheat software (Easy Anti-Cheat), which can't run in BCD."
        case "epic.citadel": d.installWarning = "This game asks Epic to confirm you own it each time it starts. BCD does that when it starts the game signed in, so it needs an internet connection. Games like this often add copy protection of their own that may not run here."
        case "epic.harbor": d.installBlocker = "This game starts through another company's launcher (Ubisoft), which BCD can't run yet."
        case "epic.courier": d.installWarning = "Epic says this game must be online to start. BCD starts it signed in to your Epic account, so it needs an internet connection."
        case "epic.gtav": d.installWarning = "This game's anti-cheat (BattlEye) guards only GTA Online. BCD starts the game with its own -nobattleye option, so Story Mode plays and GTA Online stays off."
        default: break
        }
        guard game.state.isInstalled else { return d }
        let keys = value(game, "controller", game.store == .local ? "keys" : "") == "keys"
        let bindsChanged = (values[game.id] ?? [:]).keys.filter { $0.hasPrefix("bind.") }.count
        func choice(_ id: String, _ title: String, _ fallback: String, _ list: [(String, String)], note: String? = nil) -> BCDGameSetting {
            BCDGameSetting(id: id, title: title, kind: .choice(list.map { BCDGameChoice(value: $0.0, label: $0.1) }),
                           value: value(game, id, fallback), defaultValue: fallback, note: note)
        }
        func toggle(_ id: String, _ title: String, _ fallback: Bool = false, note: String? = nil) -> BCDGameSetting {
            BCDGameSetting(id: id, title: title, kind: .toggle, value: value(game, id, fallback ? "1" : "0"),
                           defaultValue: fallback ? "1" : "0", note: note)
        }
        var resolution = BCDGameSetting(id: "resolution", title: "分辨率", kind: .choice(Self.resolutions),
                                        value: value(game, "resolution", "1408x648"), defaultValue: "1408x648",
                                        note: "The screen size Windows reports to the game. Fewer pixels run faster; Scaling decides how the picture fills this screen.")
        if game.id == "271590" && values[game.id]?["resolution"] == nil { resolution.value = "1568x720" }
        let fps = choice("fps", "帧率限制", "1", [("3", "30 FPS"), ("4", "40 FPS"), ("1", "60 FPS"),
                                                        ("0", "屏幕最大值"), ("2", "无限制")],
                         note: "游戏每秒最多显示的帧数。30 与 40 能让设备更凉爽；「无限制」则让游戏全速运行。")
        d.groups = [
            BCDGameSettingGroup(id: "display", title: "显示", symbol: "display", settings: [
                resolution,
                choice("scaling", "缩放", "fit", [("fit", "Fit"), ("fill", "Fill and crop"), ("stretch", "Stretch"), ("aspect", "The game's own shape")],
                       note: "Fit shows the whole picture, with bars where its shape differs from the screen's. Fill covers the screen and crops."),
                choice("orientation", "屏幕方向", "", BCDOrientationRules.gameChoices(global: nil).map { ($0.value, $0.label) },
                       note: "此游戏运行时的屏幕旋转方式。「横屏」无论你怎么持握（例如躺下）都保持横屏；游戏结束后恢复为跟随设备。「设置」中可对所有游戏统一选择。"),
                fps,
                choice("metalfx-upscale", "MetalFX 超分", "", [("", "关闭"), ("1.5", "1.5×"), ("2", "2×")],
                       note: "Direct3D 11 and 12 games draw at the resolution above, and Apple's MetalFX enlarges the picture by this much."),
                toggle("framegen", "Frame generation (experimental)",
                       note: "MetalFX makes up a frame between every two the game draws: twice the frames, for GPU time and a little delay."),
            ], headline: resolution.value.replacingOccurrences(of: "x", with: " × ") + " · " + (fps.choices.first { $0.value == fps.value }?.label ?? "")),
            BCDGameSettingGroup(id: "direct3d", title: "Direct3D", symbol: "cube.transparent", settings: [
                choice("anisotropy", "Direct3D 9 纹理过滤", "0", [("0", "游戏自行决定"), ("2", "Up to 2×"), ("4", "Up to 4×"), ("8", "Up to 8×")]),
                choice("dxil-tess-max-factor", "Direct3D 12 tessellation", "", [("", "Standard (3)"), ("2", "Light (2)"), ("8", "Fine (8)")]),
                choice("async-submit", "Direct3D 12 command encoding", "", [("", "On the game's thread"), ("1", "On a worker thread")]),
                choice("fence-chain", "Direct3D 12 GPU sync", "", [("", "One pass after another"), ("6", "Where barriers allow")]),
                toggle("nvidia", "Show the game an NVIDIA card", game.id == "271590",
                       note: "For games that stop with \"no graphics card\": Windows then reports an NVIDIA card and driver."),
            ]),
            BCDGameSettingGroup(id: "compat", title: "兼容性", symbol: "cpu", settings: [
                toggle("avx", "AVX and AVX2", note: "For a 64-bit game that quits at start with an illegal instruction because it expects AVX."),
                toggle("x87", "Faster x87 math", note: "Less exact x87 math, which runs faster in older games."),
                choice("cpus", "游戏可见的处理器", "0", [("0", "本设备的"), ("2", "2"), ("4", "4"), ("6", "6")]),
                toggle("winevcrt", "Wine's C++ runtime"),
                BCDGameSetting(id: "fastsync", title: "Fast synchronization", kind: .toggle, value: "1", defaultValue: "1",
                               note: "Fastsync handles this game's events inside its own process.",
                               locked: "This belongs to Fastsync: choose it in Settings › Memory & sync to change it."),
            ]),
            BCDGameSettingGroup(id: "controls", title: "操作控制", symbol: "gamecontroller", settings: [
                toggle("touch", "触摸控件", note: "Buttons on the screen over the game."),
                choice("opacity", "触摸控件不透明度", "0.70", [("0.40", "40%"), ("0.70", "70%"), ("1.00", "100%")]),
                choice("env.MADEIRA_PAD_MODE", "控制器接口", "", BCDPadModel.choices().map { ($0.line, $0.title) }, note: BCDPadModel.pageNote),
                BCDGameSetting(id: "controller", title: "控制器模式", kind: .choice([
                    BCDGameChoice(value: "", label: "游戏自带的运行库"), BCDGameChoice(value: "dinput", label: "XInput 与 DirectInput"),
                    BCDGameChoice(value: "keys", label: "键盘与鼠标")]),
                               value: value(game, "controller", game.store == .local ? "keys" : ""), defaultValue: ""),
            ] + (keys ? [BCDGameSetting(id: "binds", title: "控制器绑定", kind: .opens(.section("binds")),
                                        value: bindsChanged == 0 ? "BCD's layout" : "\(bindsChanged) changed", defaultValue: "BCD's layout",
                                        note: "键盘鼠标模式下每个摇杆与按键分别敲击什么。")] : [])
              + [choice("hud", "性能 HUD", "off", BCDHUDLayout.allCases.map { ($0.rawValue, $0.title) },
                        note: "What shows over the game while you play: 1 the frame rate, 2 one line, 3 adds the load and a graph, 4 everything for a bug report, Custom your own readings. Its position and the Custom readings are set in the in-game menu, under Display. Settings has the choice for every game.")]),
        ]
        if keys { d.groups.append(binds(game)) }
        d.groups += BCDInputPage.groups(inputProfile(game))   // round 604: turbo and macros, ...
        if steam {
            d.groups.append(BCDGameSettingGroup(id: "steam", title: "Steam", symbol: "arrow.down.app", settings: [
                choice("startwith", "启动方式", "", [("", "BCD Dock（Steam 客户端）"), ("game", "游戏自身的程序")]),
                toggle("smallpool", "较小的 JIT 池（512 MB）"),
                BCDGameSetting(id: "installrequest", title: "下次启动时", kind: .choice([
                    BCDGameChoice(value: "", label: "不再需要"),
                    BCDGameChoice(value: "已重置", label: "取消安装标记并重新运行",
                                  question: BCDGameQuestion(title: "Take out the one-time installs?", message: "At the next start…",
                                                            confirm: "下次启动时", destructive: true)),
                ]), value: value(game, "installrequest", ""), defaultValue: ""),
                BCDGameSetting(id: "appid", title: "App ID", kind: .info, value: game.id),
            ], headline: value(game, "startwith", "") == "game" ? "游戏自身的程序" : "Through BCD Dock"))
        } else {
            d.groups.append(BCDGameSettingGroup(id: "launch", title: "启动", symbol: "play.rectangle", settings: [
                choice("start", "开始", "direct", [("direct", "自动"), ("desktop", "在 Wine 桌面中")]),
                BCDGameSetting(id: "arguments", title: "启动参数", kind: .text(prompt: "-windowed -nosplash"),
                               value: value(game, "arguments", ""), note: "每次启动时传给程序。", chips: BCDLaunchFlags.quick),
                toggle("flag-windowed", "-windowed", note: "请求窗口。"),
                BCDGameSetting(id: "command", title: "启动什么", kind: .info, value: "\(game.id).exe " + value(game, "arguments", "")),
            ], headline: "自动"))
        }
        let gog = game.store == .gog || game.store == .epic
        var library: [BCDGameSetting] = []
        if !gog {
            library.append(BCDGameSetting(id: "title", title: "名称", kind: .text(prompt: game.title), value: game.title, note: "游戏库中显示的名称。"))
        }
        if !steam && !gog {
            library.append(BCDGameSetting(id: "findstore", title: "在 Steam 中查找", kind: .opens(.storeSearch),
                                          note: "在 Steam 商店中查找此游戏，以获取名称与商店图片。"))
        }
        library.append(BCDGameSetting(id: "cover", title: "Choose a cover picture", kind: .opens(.coverPicture),
                                      note: "来自「文件」的图片，用来替代商店封面。"))
        library.append(BCDGameSetting(id: "path", title: "程序", kind: .info, value: "C:\\Games\\\(game.title)\\game.exe"))
        d.groups.append(BCDGameSettingGroup(id: "library", title: "游戏库", symbol: "books.vertical", settings: library, headline: game.title))
        if steam, let owned = Self.dlcOwned[game.id] {
            let installed = dlcInstalled[game.id] ?? [], wanted = dlcWanted[game.id] ?? installed
            let rows = owned.map { BCDDLCRow(id: $0.id, name: $0.name, bytes: $0.bytes, installed: installed.contains($0.id), wanted: wanted.contains($0.id)) }
            if let group = BCDGameDLC.group(BCDDLCState(rows: rows, withoutFiles: 1, notOwned: 3)),
               let at = d.groups.firstIndex(where: { $0.id == "library" }) { d.groups.insert(group, at: at) }
        }
        // Round 604: Help with this game (BCDGameHelp.swift) and the Sound section's audio rows (BCDGameSound.swift), as the app builds them.
        if game.state.isInstalled, let at = d.groups.firstIndex(where: { $0.id == "library" }) {
            var help = BCDHelpState()
            help.hasLog = true
            help.readinessChecked = true
            if game.id == "271590" { help.readiness = "muv-luv_pf.exe is a 32-bit program that wants mfc140u.dll (Microsoft's MFC). BCD does not carry the 32-bit one yet." }
            if let result = values[game.id]?["help.fb.result"] { help.feedback.result = BCDFeedbackResult(rawValue: result) }
            help.message = help.feedback.result.flatMap { _ in BCDGameFeedbackCore.text(game: game.title, draft: help.feedback, numbers: nil) }
            d.groups.insert(BCDGameHelp.group(help), at: at)
            d.groups.insert(BCDGameSettingGroup(id: "sound", title: "声音", symbol: "speaker.wave.2",
                                                settings: BCDGameSound.settings(latency: value(game, BCDGameSound.latencyID, ""), volume: value(game, BCDGameSound.volumeID, ""),
                                                                                resume: value(game, BCDGameSound.resumeID, "0"))), at: at)
        }
        // Round 604: the setup sections (Windows, Components, CPU translation, Where the saves live, Game fixes, Wine desktop, Start).
        if game.state.isInstalled {
            var setup = BCDGameSetupState()
            setup.windowsVersion = game.id == "wc3" ? "win7" : ""
            setup.is64Bit = game.id != "wc3" && game.id != "wc2"
            setup.dll.shipped = ["d3dx9_43.dll", "xinput1_3.dll", "VCRUNTIME140.dll"]
            setup.dll.shadow = setup.is64Bit ? ["vcruntime140.dll"] : []
            setup.dll.off = game.id == "wc3" ? ["dsound.dll"] : []
            setup.dll.runtimes = ["OpenAL", "XNA Framework 4.0"]
            setup.fexPreset = game.id == "271590" ? "performance" : ""
            setup.saves = [BCDSetupSaveItem(path: "users/u/Documents/My Games/Foo", label: "Documents › My Games › Foo", place: .prefix),
                           BCDSetupSaveItem(path: "users/u/AppData/Roaming/Vendor/Foo", label: "AppData › Roaming › Vendor › Foo", place: .files)]
            setup.fixes = game.id == "wc3" ? [
                BCDSetupFixItem(number: 1, enabled: true, summary: "In foo.ini, [Display] FullScreen = 1", problem: nil),
                BCDSetupFixItem(number: 2, enabled: false, summary: "Move ShaderCache aside", problem: nil),
                BCDSetupFixItem(number: 3, enabled: true, summary: "Write evil.dll", problem: "BCD does not write that place or a program"),
            ] : []
            if game.id == "wc2" { setup.desktop = BCDSetupDesktopState(dpi: "144", theme: "dark", wallpaper: "C:\\bcd-wallpaper.bmp") }
            var start = BCDGameStartState()
            if game.id == "wc3" {
                start.plan = BCDStartPlan.read(["start.delay": "5", "start.second": "C:\\Tools\\mapper.exe", "window.1": "raise title \"Warcraft III\" 1000"])
            }
            d.groups.insert(contentsOf: BCDGameSetupPage.sections(setup) + [BCDGameStartPage.group(start)], at: min(3, d.groups.count))
        }
        if !settings { d.groups = [] }
        d.sizeOnDisk = game.size
        d.lastPlayed = game.lastPlayed
        d.configSettings = 2 + (values[game.id]?.count ?? 0)
        d.canReset = true
        d.shortcut = true
        d.saves = true
        d.report = true
        let changed = !(values[game.id] ?? [:]).isEmpty
        switch game.id {
        case "wc3":
            d.program = "32-bit · Direct3D 8"
            d.recommendation = BCDGameRecommendation(title: nil, version: 3, made: Date() - 86_400, checked: Date() - 7200, inUse: !changed)
            d.tuning = tuning["wc3"]
            d.settings = tuning["wc3"]?.on == true ? "Auto-tune on" : "标准"
            d.removal = .removeFromLibrary
        case "wc2":
            d.program = "32-bit · DirectDraw"
            d.recommendation = BCDGameRecommendation(title: "Warcraft II: Battle.net Edition", version: 2, inUse: !changed)
            d.settings = "Recommended"
            d.removal = .removeFromLibrary
        case "271590":
            d.program = "64-bit · Direct3D 11"
            d.recommendation = BCDGameRecommendation(title: "Grand Theft Auto V Legacy", version: 3, made: Date() - 86_400, downloaded: true, checked: Date() - 600, inUse: recommendedApplied.contains(game.id))
            d.settings = recommendedApplied.contains(game.id) ? "Recommended" : "Your own"
        default:
            d.program = "64-bit · Direct3D 11"
            d.recommendation = BCDGameRecommendation(title: nil, inUse: !changed)
            d.settings = changed ? "Your own" : "标准"
        }
        if gog {
            d.storeNote = game.store == .epic ? "This game uses Epic Online Services. BCD starts it signed in to your Epic account. If it still asks you to sign in on a web page, that part isn't supported yet."
                : "May need: Visual C++ 2017, DirectX (June 2010). BCD doesn't install these from GOG yet."
            d.removal = .uninstall(frees: game.size)
        }
        if steam {
            d.cloud = cloud[game.id] ?? .notChecked
            if case .differ? = d.cloud {
                d.cloudConflicts = [
                    BCDCloudConflict(name: "SaveGame_3.sav", cloudDate: Date() - 7200, cloudBytes: 2_310_000, deviceDate: Date() - 86_400, deviceBytes: 2_290_000),
                    BCDCloudConflict(name: "profile.dat", cloudDate: Date() - 7200, cloudBytes: 14_000, deviceDate: nil),
                ]
                d.cloudReceived = 3
                d.cloudBackedUp = 1
            }
            d.canRepair = true
            d.removal = .uninstall(frees: game.size)
        }
        return d
    }

    func opened(_ game: BCDGame) {}

    func set(_ setting: String, to value: String, for game: BCDGame) {
        if setting.hasPrefix("dlc.") {
            let owned = Set((Self.dlcOwned[game.id] ?? []).map(\.id))
            switch setting {
            case BCDGameDLC.chooseID:
                dlcAsked.insert(game.id)
                dlcWanted[game.id] = BCDGameDLC.chosenSet(value).map { $0.intersection(owned) } ?? owned
            case BCDGameDLC.allID:
                dlcWanted[game.id] = owned
                dlcInstalled[game.id] = owned
            case BCDGameDLC.applyID:
                dlcInstalled[game.id] = dlcWanted[game.id] ?? dlcInstalled[game.id] ?? []
            default:
                if let dlc = BCDGameDLC.dlcID(setting) {
                    var wanted = dlcWanted[game.id] ?? dlcInstalled[game.id] ?? []
                    if value == "1" { wanted.insert(dlc) } else { wanted.remove(dlc) }
                    dlcWanted[game.id] = wanted
                }
            }
            return
        }
        if BCDInputLines.handles(setting) {
            let current = inputProfile(game)
            if let write = BCDInputLines.write(setting: setting, value: value, current: { current.get($0, $1) }) {
                inputLines[game.id, default: [:]][write.feature, default: [:]][write.line] = write.value.isEmpty ? nil : write.value
            }
            return
        }
        if value == "run" { return }
        values[game.id, default: [:]][setting] = value
    }

    func syncCloud(_ game: BCDGame) {
        let before = cloud[game.id] ?? .notChecked
        cloud[game.id] = .checking
        onChange?()
        Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            if case .differ = before { self.cloud[game.id] = before } else { self.cloud[game.id] = .synced(matching: 3) }
            self.onChange?()
        }
    }

    func keepCloudSaves(_ game: BCDGame, fromCloud: Bool) {
        cloud[game.id] = .synced(matching: 5)
        onChange?()
    }

    func resetToRecommended(_ game: BCDGame) {
        values[game.id] = nil
        recommendedApplied.insert(game.id)
    }

    func refreshRecommendedSettings(for game: BCDGame) async -> BCDRecommendedRefresh {
        try? await Task.sleep(nanoseconds: 500_000_000)
        if game.id == "271590" && !recommendedApplied.contains(game.id) { return .available(changes: 3) }
        return game.store == .gog ? .offline(builtIn: true, nothingOnline: false) : .upToDate
    }

    func applyRecommendedSettings(_ game: BCDGame) { resetToRecommended(game) }

    func setTuning(_ on: Bool, for game: BCDGame) {
        var state = tuning[game.id] ?? BCDGameTuning(on: false, status: nil, canUndo: false)
        state.on = on
        state.status = on ? (state.status ?? "Play once: the first start is the baseline.") : nil
        tuning[game.id] = state
    }

    func undoTuning(_ game: BCDGame) {
        tuning[game.id] = BCDGameTuning(on: tuning[game.id]?.on ?? false, status: nil, canUndo: false)
    }

    func writeTuningLines(_ game: BCDGame) {
        undoTuning(game)
        values[game.id, default: [:]]["dxmt"] = "d3d9.deferSurfaceCreation=1"
    }

    func tuningReport(for game: BCDGame) -> String? { "BCD auto-tune report: \(game.title)\nstatus: found\n" }

    func shortcutLink(for game: BCDGame) -> String? { "bcd://play?exe=C:%5CGames%5C\(game.id)" }

    func backUpSaves() async throws -> BCDSavesBackup {
        try? await Task.sleep(nanoseconds: 600_000_000)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("BCD-saves-sample.zip")
        try Data("sample".utf8).write(to: file)
        return BCDSavesBackup(file: file, files: 42, bytes: 3_400_000, leftOut: 0)
    }

    func restoreSaves(from file: URL) async throws -> Int { 42 }

    func lastLog(of game: BCDGame) async -> BCDGameLog? {
        guard game.lastPlayed != nil else { return nil }
        return BCDGameLog(file: URL(fileURLWithPath: "/tmp/sample.txt"), name: "game.exe-2026-10-18_21-04-11.txt",
                          date: Date() - 3600, bytes: 2_400_000)
    }

    func logComment() async -> String? { "" }

    func send(_ log: BCDGameLog, of game: BCDGame, comment: String, progress: @escaping (String) -> Void) async throws -> String {
        progress("Compressing…")
        try? await Task.sleep(nanoseconds: 500_000_000)
        progress("Sending 1 MB…")
        try? await Task.sleep(nanoseconds: 500_000_000)
        return "K7Q2XM"
    }

    private var configs: [String: String] = [:]

    func configText(for game: BCDGame) -> String? {
        configs[game.id] ?? "# BCD settings for this game\nmetalfx-upscale = 1.5\nfence-chain = 6\n"
    }

    func saveConfig(_ text: String, for game: BCDGame) { configs[game.id] = text }

    func searchStore(_ text: String) async throws -> [BCDStoreMatch] {
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !text.localizedCaseInsensitiveContains("zzz") else { return [] }
        return [BCDStoreMatch(id: 2800, name: "Warcraft III: Reign of Chaos"),
                BCDStoreMatch(id: 2801, name: "Warcraft III: The Frozen Throne"),
                BCDStoreMatch(id: 2802, name: "Warcraft III: Reforged")]
    }

    func useStoreMatch(_ match: BCDStoreMatch, for game: BCDGame) {}

    func setCover(from file: URL, for game: BCDGame) async throws {
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    /// Keyboard-and-mouse binds: a few changed, as a player would leave them.
    private func binds(_ game: BCDGame) -> BCDGameSettingGroup {
        let standard = ["LS": "stick.wasd", "RS": "none", "A": "key.32", "B": "key.17", "X": "key.69", "Y": "key.82", "LB": "key.81",
                        "RB": "key.70", "LT": "mouse.right", "RT": "mouse.left", "L3": "key.16", "R3": "key.67", "菜单": "key.27",
                        "View": "key.9", "D↑": "key.38", "D↓": "key.40", "D←": "key.37", "D→": "key.39"]
        let sample = ["B": "key.71", "Y": "key.9"]
        var settings: [BCDGameSetting] = []
        for section in BCDPadBinds.sections {
            for (index, input) in section.inputs.enumerated() {
                let value = values[game.id]?["bind." + input] ?? sample[input] ?? ""
                settings.append(BCDGameSetting(id: "bind." + input, title: BCDPadBinds.inputName(input),
                                               kind: .choice(BCDPadBinds.choices(for: input, current: value,
                                                                                 standard: BCDPadBinds.label(standard[input] ?? "none", input: input))),
                                               value: value, defaultValue: "", heading: index == 0 ? section.title : nil))
            }
        }
        let speed = Double(values[game.id]?["bind.vertical"] ?? "") ?? 0.8
        settings.append(BCDGameSetting(id: "bind.vertical", title: "上下速度", kind: .choice(BCDPadBinds.speeds(current: speed)),
                                       value: String(format: "%.2f", speed), defaultValue: "1.00",
                                       note: "As a share of the speed across.", heading: "Right stick as the mouse"))
        settings.append(BCDGameSetting(id: "bind.reset", title: "还原所有绑定", kind: .action,
                                       note: "Every input goes back to its default.",
                                       question: BCDGameQuestion(title: "还原所有控制器绑定？", message: "Each stick and button goes back to its default.",
                                                                 confirm: "还原", destructive: true), destructive: true))
        return BCDGameSettingGroup(id: "binds", title: "控制器绑定", symbol: "keyboard", settings: settings, headline: "3 changed", parent: "controls")
    }

    static let resolutions: [BCDGameChoice] = {
        let own = "Shaped like this screen", wide = "Widescreen 16:9, bars at the sides", classic = "Classic 4:3, bars at the sides"
        return [
            BCDGameChoice(value: "1160x536", label: "1160 × 536 · lighter", group: own),
            BCDGameChoice(value: "1408x648", label: "1408 × 648", group: own),
            BCDGameChoice(value: "1568x720", label: "1568 × 720 · 720 lines", group: own),
            BCDGameChoice(value: "2080x960", label: "2080 × 960 · about 1080p", group: own),
            BCDGameChoice(value: "2532x1170", label: "2532 × 1170 · every pixel", group: own),
            BCDGameChoice(value: "960x540", label: "960 × 540", group: wide),
            BCDGameChoice(value: "1280x720", label: "1280 × 720", group: wide),
            BCDGameChoice(value: "1920x1080", label: "1920 × 1080", group: wide),
            BCDGameChoice(value: "640x480", label: "640 × 480", group: classic),
            BCDGameChoice(value: "1024x768", label: "1024 × 768", group: classic),
        ]
    }()
}

/// `-BCDTab game[-<game id>[-<what>]]`: a game's page alone, with Options open (`options`, a
/// section such as `display` or `binds`, a setting such as `resolution` or `bind.A`, `cloud`,
/// `recommended`, `tuning`, `config`, `findstore`) or a question (`uninstall`, `remove`). Without an id, `-BCDGame <id>`, else Hollow Knight.
struct BCDGamePreviewRoot: View {
    let spec: String

    var body: some View {
        let parts = spec.split(separator: "-").map(String.init)
        let id = parts.count > 1 ? parts[1] : (UserDefaults.standard.string(forKey: "BCDGame") ?? "367520")
        let what = parts.count > 2 ? parts[2] : ""
        let panel: BCDGameOptionsPage? = switch what {
        case "options": .main
        case "cloud": .cloud
        case "recommended": .recommended
        case "tuning": .tuning
        case "config": .config
        case "findstore": .storeSearch
        case "display", "direct3d", "compat", "controls", "launch", "steam", "library", "binds", "dlc", "help", "sound",
             "windows", "components", "fex", "saveplace", "fixes", "desktop", "start": .group(what)   // the last seven: round 604 (BCDGameSetupPage.swift, BCDGameStart.swift)
        case _ where BCDInputPage.groupIDs.contains(what): .group(what)
        case "resolution", "fps", "scaling", "arguments", "installrequest": .setting(what)
        default: what.hasPrefix("bind.") ? .setting(what) : nil
        }
        let ask: BCDGameAction? = what == "uninstall" ? .uninstall : what == "remove" ? .removeFromLibrary
            : what == "install" || what == "checking" ? .install(.device) : what == "choose" ? .chooseDLC(.device) : nil
        BCDGamePage(gameID: id, from: "游戏库", backend: BCDGameDetailSource.backend, panel: panel, ask: ask) {
            print("[preview] back")
        }
    }
}
