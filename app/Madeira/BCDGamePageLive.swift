// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Combine
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

// The game page's engine side (BCDGamePage.swift, docs/BCD-UI-ARCHITECTURE.md): the only file of
// the page that names the engine, and so left out of the preview build (tools/ui-preview.py,
// ENGINE_BOUND). Every per-game function the old Game details page offered is here, through the
// engine's own models and files, never through one of that page's views: the library entry
// (LibraryModel.save), LibraryPrefs' switches, the game's own file (GameProfiles.swift), the
// recommended settings (GameRecommendationsApply.swift, RecommendationsSource), SteamOwnedLibrary
// and Steam Cloud, MadeiraDockModel, DockOffline, PadBindings, SteamCatalog, auto-tune, SaveBackup,
// LogUpload. What the page says about them is BCD's own wording, in BCDGamePage.swift and below.
//
// Which game: the store's BCDGame ids, "steam.<App ID>" and "local.<library entry id>"
// (BCDLiveID); the Wine desktop's entry before its first start is LibraryEntry.desktopEntry.
//
// BCDGameDetailSource finds this class by its Objective-C name, so nothing outside the engine
// has to name it.

@objc(BCDGamePageLive)
@MainActor final class BCDGamePageLive: NSObject, BCDGameDetailBackend {
    var onChange: (() -> Void)? { didSet { watch() } }
    var onNotice: (() -> Void)? { didSet { watch() } }
    private var watching = Set<AnyCancellable>()
    /// "游戏自身的程序": the install folder's programs, by App ID, once listed.
    private var programs: [Int: [String]] = [:]
    private var resolving = Set<Int>()
    /// BCD Dock's Steam launch option (2026-10-24): the entries Steam's launch configuration lists for the game that a Dock
    /// start can run (SteamDirectStart.dockOptions), by App ID, read from the cached library once the page opens.
    private var dockOptions: [Int: [SteamDirectStart.DockOption]] = [:]

    nonisolated override init() { super.init() }

    // MARK: Which game

    private func appID(_ game: BCDGame) -> Int? {
        if case .steam(let id)? = BCDLiveID.parse(game.id) { return id }
        return nil
    }

    /// The game's library entry, which holds its settings: for an installed Steam game the one
    /// LibraryModel.steamEntry gives (made when it has none yet), for the Wine desktop its entry
    /// or, before its first start, the one the library makes then.
    func entry(for game: BCDGame) -> LibraryEntry? {   // not private: the save backups' extension (BCDSaveBackups/) reads it
        let library = LibraryModel.shared
        switch BCDLiveID.parse(game.id) {
        case .steam(let appID)?:
            if let installed = SteamGamesModel.shared.games.first(where: { $0.id == appID }) {
                return library.steamEntry(installed, title: game.title)
            }
            return library.entries.first { $0.steamAppID == appID }
        case .local(let id)?:
            return library.entries.first { $0.id == id } ?? (id == LibraryEntry.desktopID ? LibraryEntry.desktopEntry : nil)
        case nil:
            // An installed GOG game is the library entry its install made (BCDLiveStoreGOG).
            if let product = BCDLiveStore.gogProduct(game.id) {
                guard BCDGOG.enabled, let id = BCDGOG.shared.installs[product]?.entryID else { return nil }
                return library.entries.first { $0.id == id }
            }
            // An installed Epic game is the library entry its install made (BCDLiveStoreEpic).
            if let id = BCDLiveStore.shared.epicEntryID(game.id) { return library.entries.first { $0.id == id } }
            guard game.store == .local else { return nil }
            return library.entries.first { $0.desktop != true && $0.steamAppID == nil && $0.title == game.title }
        }
    }

    /// Changes the entry's own fields and saves it.
    private func change(_ game: BCDGame, _ edit: (inout LibraryEntry) -> Void) {
        guard var entry = entry(for: game) else { return }
        edit(&entry)
        LibraryModel.shared.save(entry)
    }

    /// A line of the game's own file, written only when it changes; an entry the library does not
    /// hold yet (a Steam game's first settings, the desktop's) is saved with it.
    private func setLine(_ game: BCDGame, _ key: String, _ value: String) {
        guard let entry = entry(for: game) else { return }
        let file = GameProfile(windowsPath: entry.windowsPath)
        if (file.get(key) ?? "") != value { file.set(key, value.isEmpty ? nil : value) }
        if !LibraryModel.shared.entries.contains(where: { $0.id == entry.id }) { LibraryModel.shared.save(entry) }
    }

    // MARK: What the page shows

    func details(for game: BCDGame, settings: Bool) -> BCDGameDetails {
        var d = BCDGameDetails()
        let steam = SteamOwnedLibrary.shared
        let id = appID(game)
        if let id { d.storePage = URL(string: "https://store.steampowered.com/app/\(id)/") }
        if let id, let time = steam.playtime[id] {
            d.minutesPlayed = time.minutes
            if time.lastPlayed > 0 { d.lastPlayed = Date(timeIntervalSince1970: TimeInterval(time.lastPlayed)) }
        }
        // A download for a game Steam has installed is an update (SteamOwnedLibrary.cancelInstall only pauses it).
        if let id, steam.downloads[id] != nil, SteamGamesModel.shared.games.contains(where: { $0.id == id && $0.installed }) {
            d.updating = true
        }
        dlcOffer(game, into: &d)   // BCD's DLC support (BCDSteamDLC/BCDGamePageLiveDLC.swift): the question before a first install
        // An Epic game BCD cannot install says why, and one that may not start says so, before Install.
        let advice = BCDLiveStore.shared.epicInstallAdvice(game.id)
        d.installBlocker = advice.blocker
        d.installWarning = advice.warning
        // A Steam game before its install: what Steam says it downloads and takes (the selected depots), and its language.
        if let id, !game.state.isInstalled, let owned = steam.game(id) {
            d.downloadBytes = owned.downloadBytes.map { Int64(clamping: $0) }
            d.installBytes = owned.installBytes.map { Int64(clamping: $0) }
            if steam.downloads[id] == nil {
                d.offersDownloadOptions = true
                if settings { d.groups = [downloadGroup(id, owned)] }
            }
        }
        guard game.state.isInstalled, let entry = entry(for: game) else { return d }
        let desktop = entry.desktop == true
        let path = entry.windowsPath
        let profile = GameProfile(windowsPath: path)
        d.program = program(entry)
        d.sizeOnDisk = entry.folderBytes
        if d.lastPlayed == nil { d.lastPlayed = entry.lastPlayed }
        d.blockers = blockers(entry, appID: id)
        d.readiness = BCDReadinessLive.shared.note(for: entry) { [weak self] in self?.onChange?() }   // round 604: what the game's programs import that this device lacks
        // GOG's runtimes the game's build names that BCD does not install yet.
        d.storeNote = BCDLiveStore.shared.gogNote(game.id) ?? BCDLiveStore.shared.epicNote(game.id)
        // The sections only while Options is open: nothing is built for what is not on screen.
        if settings {
            d.groups = [display(entry, profile), direct3D(entry, profile), compatibility(entry), controls(entry, profile), gyro(entry)]
            d.groups.insert(contentsOf: setupGroups(game, entry, profile), at: 3)   // round 604: BCDGameSetup/BCDGamePageLiveSetup.swift (Windows, Components, CPU translation, Game fixes, Wine desktop)
            if let binds = binds(entry) { d.groups.append(binds) }
            if !desktop { d.groups += inputGroups(entry) }   // round 604: BCDInputPage.swift (turbo and macros, ...)
            if let launch = launch(entry) { d.groups.append(launch) }
            if let id { d.groups.append(steamGroup(entry, id)) }
            if let dlc = dlcGroup(game) { d.groups.append(dlc) }
            if !desktop { d.groups.append(midiGroup(entry)) }   // round 603: BCDMidi/BCDGamePageLiveMidi.swift
            if !desktop, let sound = d.groups.lastIndex(where: { $0.id == "sound" }) { d.groups[sound].settings += soundSettings(entry) }   // round 604: BCDGamePageLiveSound.swift (audio delay, volume, resume)
            if !desktop { d.groups.append(saveBackupsGroup(game, entry)) }   // round 603: BCDSaveBackups/BCDGamePageLiveSaves.swift
            if !desktop { d.groups.append(helpGroup(game, entry)) }   // round 604: BCDGamePageLiveHelp.swift (debug run, game feedback, launch check)
            if !desktop { d.groups.append(libraryGroup(entry, gog: game.store == .gog || game.store == .epic)) }
        }
        if let id {
            let installed = SteamGamesModel.shared.games.first { $0.id == id }
            // BCD updates, repairs and removes only what it downloaded into BCD Dock's own library folder.
            let managed = installed.map { SteamInstallPaths.isManaged(library: $0.library) } ?? false
            let downloading = steam.downloads[id] != nil
            if SteamOwnedLibrary.cloudEnabled { cloud(id, into: &d) }
            d.canRepair = SteamOwnedLibrary.enabled && managed && !downloading && steam.signedIn
            if managed && !downloading { d.removal = .uninstall(frees: entry.folderBytes ?? game.size) }
        } else if game.store == .gog || game.store == .epic {
            // Uninstall deletes a GOG or Epic game's files through the store (BCDLiveStoreGOG, BCDLiveStoreEpic).
            d.removal = .uninstall(frees: entry.folderBytes ?? game.size)
        } else if !desktop {
            d.removal = .removeFromLibrary
        }
        d.configSettings = profile.values.count
        if let rec = GameRecommendations.recommendation(for: entry) {
            let lists = RecommendationsSource.shared
            let standard = rec.id == GameRecommendations.standardID
            let inUse = profile.text == rec.fileText
            d.recommendation = BCDGameRecommendation(title: standard ? nil : rec.title, version: lists.version,
                                                     made: Self.day(lists.generated), downloaded: lists.origin != .builtIn,
                                                     checked: lists.lastChecked, inUse: inUse)
            d.settings = inUse ? (standard ? "标准" : "Recommended") : "Your own"
        } else if profile.hasSettings {
            d.settings = "Your own"
        }
        d.canReset = !desktop
        tuning(entry, into: &d)
        d.shortcut = !desktop
        d.saves = !desktop
        d.report = true
        d.sendLogAdvice = MemoryRights.lacking ? MemoryRights.sendLogAdvice : nil
        return d
    }

    private func program(_ entry: LibraryEntry) -> String? {
        var parts: [String] = []
        if entry.bits == 32 || entry.bits == 64 { parts.append("\(entry.bits)-bit") }
        if let api = entry.graphicsAPI, !api.isEmpty { parts.append(api.replacingOccurrences(of: "D3D", with: "Direct3D ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Why Play would not start a Steam game, in the engine's words (SteamGamesRules,
    /// SteamDirectStart).
    private func blockers(_ entry: LibraryEntry, appID: Int?) -> [String] {
        guard let appID else { return [] }
        let installed = SteamGamesModel.shared.games.first { $0.id == appID }?.installed ?? false
        let updating = SteamOwnedLibrary.shared.downloads[appID] != nil
        let reason = entry.startsSteamGameDirectly
            ? SteamDirectStart.blocker(installed: installed, program: entry.steamProgram, updating: updating)
            : SteamGamesRules.blocker(installed: installed, client: MadeiraDock.clientInstalled, signedIn: SteamSignIn.isSignedIn,
                                      updating: updating)
        return reason.map { [$0] } ?? []
    }

    private static func toggle(_ id: String, _ title: String, _ on: Bool, default: Bool = false, note: String,
                               locked: String? = nil) -> BCDGameSetting {
        BCDGameSetting(id: id, title: title, kind: .toggle, value: on ? "1" : "0", defaultValue: `default` ? "1" : "0",
                       note: note, locked: locked)
    }

    /// A choice kept in the game's own file; a value typed into the file by hand is listed too.
    private static func line(_ key: String, _ title: String, _ profile: GameProfile, _ labels: [(String, String)],
                             note: String) -> BCDGameSetting {
        let value = profile.get(key) ?? ""
        var choices = labels.map { BCDGameChoice(value: $0.0, label: $0.1) }
        if !choices.contains(where: { $0.value == value }) { choices.append(BCDGameChoice(value: value, label: value)) }
        return BCDGameSetting(id: key, title: title, kind: .choice(choices), value: value, defaultValue: "", note: note)
    }

    /// The engine's choices for a key with BCD's own names for them; a value the engine adds later
    /// keeps the engine's name.
    private static func named(_ engine: [(String, String)], _ names: [String: String]) -> [(String, String)] {
        engine.map { ($0.0, names[$0.0] ?? $0.1) }
    }

    /// "2026-10-18" as a date.
    private static func day(_ text: String) -> Date? { BCDFormat.day(text) }

    // MARK: Display

    private func display(_ entry: LibraryEntry, _ profile: GameProfile) -> BCDGameSettingGroup {
        let groups = ResolutionChoices.groups()
        var sizes = groups.flatMap { group in group.choices.map { BCDGameChoice(value: $0.value, label: Self.size($0), group: Self.shape(group.title)) } }
        // The screen's shape at 480 lines while the game uses MetalFX 1.5×, and a size saved elsewhere.
        if let shape = ResolutionChoices.metalFX(in: groups),
           entry.metalFXUpscale == 1.5 || entry.resolution == shape.value || profile.get("metalfx-upscale") == "1.5" {
            sizes.append(BCDGameChoice(value: shape.value, label: Self.size(shape), group: "Other sizes"))
        }
        if !sizes.contains(where: { $0.value == entry.resolution }),
           let saved = ResolutionChoices.extra(entry.resolution, in: groups, note: "已保存") {
            sizes.append(BCDGameChoice(value: entry.resolution, label: Self.size(saved), group: "Other sizes"))
        }
        var rates: [BCDGameChoice] = []
        // 30 and 40 need the frame caps this device's display path has; a saved one stays listed.
        if ProMotionIntent.has30Cap || entry.fpsMode == 3 { rates.append(BCDGameChoice(value: "3", label: "30 FPS")) }
        if ProMotionIntent.has40Cap || entry.fpsMode == 4 { rates.append(BCDGameChoice(value: "4", label: "40 FPS")) }
        rates += [BCDGameChoice(value: "1", label: "60 FPS"), BCDGameChoice(value: "0", label: "屏幕最大值"),
                  BCDGameChoice(value: "2", label: "无限制")]
        let fps = rates.first { $0.value == String(entry.fpsMode) }?.label ?? "\(entry.fpsMode)"
        // The game's own screen orientation (BCDOrientation.swift): "" follows Settings; a value this build does not know stays listed.
        var orientations = BCDOrientationRules.gameChoices(global: BCDOrientationLive.global).map { BCDGameChoice(value: $0.value, label: $0.label) }
        if let saved = entry.orientationLock, !saved.isEmpty, !orientations.contains(where: { $0.value == saved }) {
            orientations.append(BCDGameChoice(value: saved, label: saved))
        }
        var settings = [
            BCDGameSetting(id: "resolution", title: "分辨率", kind: .choice(sizes), value: entry.resolution,
                           defaultValue: ResolutionChoices.defaultValue,
                           note: "Windows 报告给游戏的屏幕尺寸，以及 Wine 桌面的大小。像素越少运行越快；「缩放」决定画面如何铺满本屏幕。"),
            BCDGameSetting(id: "scaling", title: "缩放",
                           kind: .choice(DisplayMode.allCases.map { BCDGameChoice(value: $0.rawValue, label: Self.scaling[$0.rawValue] ?? $0.label) }),
                           value: entry.displayMode.rawValue, defaultValue: DisplayMode.fit.rawValue,
                           note: "「适应」显示完整画面，比例不符处加黑边。「填充并裁剪」铺满屏幕。「拉伸」铺满并改变比例。「游戏原始比例」按游戏实际绘制的比例显示，4:3 的画面仍保持 4:3。"),
            BCDGameSetting(id: "orientation", title: "屏幕方向", kind: .choice(orientations), value: entry.orientationLock ?? "", defaultValue: "",
                           note: "此游戏运行时的屏幕旋转方式。「横屏」无论你怎么持握（例如躺下）都保持横屏；游戏结束后恢复为跟随设备。「设置」中可对所有游戏统一选择。"),
            BCDGameSetting(id: "fps", title: "帧率限制", kind: .choice(rates), value: String(entry.fpsMode), defaultValue: "1",
                           note: "游戏每秒最多显示的帧数。30 与 40 能让设备更凉爽；「无限制」则让游戏全速运行。"),
            Self.line("metalfx-upscale", "MetalFX 超分", profile, Self.named(GameProfile.metalFXChoices, ["": "关闭"]),
                      note: "Direct3D 11 与 12 游戏按上述分辨率绘制，Apple 的 MetalFX 按此倍数放大画面。配合较低分辨率可获得更高帧率。"),
        ]
        // MetalFX frame interpolation needs iOS 26; below it the switch is not offered (check-frame-gen-ios26.py).
        if #available(iOS 26.0, *) {
            settings.append(Self.toggle("framegen", "Frame generation (experimental)", profile.get("env.MADEIRA_FRAMEGEN") == "1",
                                        note: "MetalFX makes up a frame between every two the game draws: twice the frames, for GPU time, a little delay and some smearing at edges and the HUD. The frame-rate limit is ignored while it is on. Turn it off if the game runs below about 40 FPS without it: it waits for screen buffers and can hold such a game at 20 FPS."))
        }
        return BCDGameSettingGroup(id: "display", title: "显示", symbol: "display", settings: settings,
                                   headline: entry.resolution.replacingOccurrences(of: "x", with: " × ") + " · " + fps)
    }

    /// BCD's names for the engine's sizes ("1408×648 · default" reads "1408 × 648").
    private static func size(_ choice: ResolutionChoices.Choice) -> String {
        let words = ["light": "lighter", "≈1080p": "about 1080p", "native": "every pixel", "720 lines": "720 lines",
                     "已保存": "set earlier", "default": ""]
        let note = choice.label.components(separatedBy: " · ").dropFirst().joined(separator: " · ")
        let said = words[note] ?? note
        return "\(choice.w) × \(choice.h)" + (said.isEmpty ? "" : " · " + said)
    }

    /// ... and for their groups ("16:9 widescreen · bars at the sides" reads "Widescreen 16:9, bars at the sides").
    private static func shape(_ title: String) -> String {
        title.replacingOccurrences(of: "本屏幕的形状", with: "Shaped like this screen")
            .replacingOccurrences(of: "16:9 widescreen", with: "Widescreen 16:9")
            .replacingOccurrences(of: "4:3 classic", with: "Classic 4:3")
            .replacingOccurrences(of: " · ", with: ", ")
    }

    private static let scaling = ["fit": "Fit", "fill": "Fill and crop", "stretch": "Stretch", "aspect": "The game's own shape"]

    // MARK: Direct3D

    private func direct3D(_ entry: LibraryEntry, _ profile: GameProfile) -> BCDGameSettingGroup {
        let aniso = [BCDGameChoice(value: "0", label: "游戏自行决定")] + [1, 2, 4, 8].map { BCDGameChoice(value: "\($0)", label: "Up to \($0)×") }
        return BCDGameSettingGroup(id: "direct3d", title: "Direct3D", symbol: "cube.transparent", settings: [
            BCDGameSetting(id: "anisotropy", title: "Direct3D 9 纹理过滤", kind: .choice(aniso),
                           value: String(entry.anisotropyLimit ?? 0), defaultValue: "0",
                           note: "Direct3D 9 游戏可使用的最高各向异性过滤级别。"),
            Self.line("dxil-tess-max-factor", "Direct3D 12 tessellation", profile,
                      Self.named(GameProfile.tessChoices, ["": "Standard (3)", "2": "Light (2)", "4": "Medium (4)", "8": "Fine (8)",
                                                          "0": "The game's own, no cap"]),
                      note: "BCD 的 Direct3D 12 运行时使用的最高细分因子。越低越快。"),
            Self.line("async-submit", "Direct3D 12 command encoding", profile,
                      Self.named(GameProfile.submitChoices, ["": "On the game's thread", "1": "On a worker thread"]),
                      note: "由工作线程编码游戏的命令列表，为游戏主线程减负。"),
            Self.line("fence-chain", "Direct3D 12 GPU sync", profile,
                      Self.named(GameProfile.gpuSyncChoices, ["": "One pass after another", "6": "Where barriers allow"]),
                      note: "「屏障允许处」让 GPU 在游戏屏障允许的地方并行执行各通道；「按顺序」是更安全的默认值。"),
            Self.toggle("nvidia", "Show the game an NVIDIA card", LibraryPrefs.nvidia(entry.windowsPath),
                        note: "针对提示「没有显卡」或「获取 GPU 驱动信息失败」而停止的游戏：此时 Windows 会报告一块 NVIDIA 显卡及驱动。"),
            // madeira-bcd (2026-10-25, round 603): the same, for any maker (BCDGPUCards.swift), and the video memory a game is told it has.
            Self.line(BCDGPUCards.key, "伪装成此 GPU", profile, BCDGPUCards.choices,
                      note: "The graphics card the game is told it has: its name, maker and model, the same in Direct3D 9, 10, 11 and 12 and in Windows. For a game that quits with \"unsupported GPU\" or only knows some makers. Nothing runs faster: the phone's GPU does the drawing. NVIDIA GeForce RTX 3060 is the card the switch above reports, and a card chosen here wins over that switch. A game may then load the maker's own helper libraries. From the next start."),
            Self.line(BCDGPUCards.memoryKey, "Video memory", profile, BCDGPUCards.memoryChoices(RuntimeMemorySyncSettings.vramChoices),
                      note: "告知游戏的显存容量。游戏据此规划纹理池，若超过手机实际承受能力，iOS 可能会关闭游戏；「自动」会按手机可承受的范围设置。「设置 › 内存」可对所有游戏统一设置。从下次启动起生效。"),
        ])
    }

    // MARK: Compatibility

    private func compatibility(_ entry: LibraryEntry) -> BCDGameSettingGroup {
        let path = entry.windowsPath
        let fastsync = SyncEngine.current == .fastsync
        let lock = fastsync ? nil : "This belongs to Fastsync: choose it in Settings › Memory & sync to change it."
        let cpus = [BCDGameChoice(value: "0", label: "本设备的")] + [1, 2, 4, 6].map { BCDGameChoice(value: "\($0)", label: "\($0)") }
        return BCDGameSettingGroup(id: "compat", title: "兼容性", symbol: "cpu", settings: [
            Self.toggle("avx", "AVX and AVX2", LibraryPrefs.avx(path),
                        note: "针对启动时因非法指令（c000001d）退出的 64 位游戏，或提示需要 AVX、处理器不满足要求的游戏（因为它们期望 AVX）。此时模拟器将模拟 AVX，速度会变慢。"),
            Self.toggle("x87", "Faster x87 math", entry.reducedX87,
                        note: "精度稍低的 x87 浮点运算，在老游戏中运行更快。更改后可能需要重启 BCD。"),
            BCDGameSetting(id: "cpus", title: "游戏可见的处理器", kind: .choice(cpus), value: String(entry.cpuCount ?? 0),
                           defaultValue: "0", note: "Windows 告知游戏的处理器数量。"),
            Self.toggle("winevcrt", "Wine's C++ runtime", LibraryPrefs.wineVCRT(path),
                        note: "用 Wine 自带的 C++ 运行库替代 Microsoft 的，用于加载后立即崩溃的游戏。"),
            Self.toggle("fastsync", "Fast synchronization", entry.fastSync ?? true, default: true,
                        note: "Fastsync 在游戏自身进程内处理事件，而不经过 Wine 服务进程。", locked: lock),
            Self.toggle("semaphores", "Fast semaphore waits (experimental)", entry.semaphoreFastPath ?? false,
                        note: "Fastsync 也会在游戏进程内部处理信号量。", locked: lock),
        ])
    }

    // MARK: Controls and the screen during play

    private func controls(_ entry: LibraryEntry, _ profile: GameProfile) -> BCDGameSettingGroup {
        func percent(_ values: [Double], _ current: Double) -> [BCDGameChoice] {
            var list = values.map { BCDGameChoice(value: String(format: "%.2f", $0), label: "\(Int(($0 * 100).rounded()))%") }
            let now = String(format: "%.2f", current)
            if !list.contains(where: { $0.value == now }) { list.append(BCDGameChoice(value: now, label: "\(Int((current * 100).rounded()))%")) }
            return list
        }
        let opacity = entry.controlOpacity ?? 0.7, size = entry.controlSize ?? 1
        var settings = [
            Self.toggle("touch", "触摸控件", entry.touchControls,
                        note: "显示在游戏画面之上的屏幕按键。在游戏菜单中摆放它们并指定各自的功能。"),
            BCDGameSetting(id: "opacity", title: "触摸控件不透明度", kind: .choice(percent([0.25, 0.4, 0.55, 0.7, 0.85, 1], opacity)),
                           value: String(format: "%.2f", opacity), defaultValue: "0.70"),
            BCDGameSetting(id: "size", title: "触摸控件大小", kind: .choice(percent([0.5, 0.75, 1, 1.25, 1.5, 2], size)),
                           value: String(format: "%.2f", size), defaultValue: "1.00"),
            // Round 604: what the game sees as the controller (BCDPadModel.swift): an Xbox pad through XInput, a DualSense, a generic gamepad.
            Self.line(GamepadInput.padModeKey, "控制器接口", profile, BCDPadModel.choices().map { ($0.line, $0.title) }, note: BCDPadModel.pageNote),
        ]
        if GamepadInput.keyboardMouseAvailable {
            settings.append(BCDGameSetting(id: "controller", title: "控制器模式", kind: .choice([
                BCDGameChoice(value: "", label: "游戏自带的运行库"),
                BCDGameChoice(value: "dinput", label: "XInput 与 DirectInput"),
                BCDGameChoice(value: "keys", label: "键盘与鼠标"),
            ]), value: entry.controllerMode ?? "", defaultValue: "",
                note: "XInput and DirectInput adds the controller as a joystick too, for games older than XInput (a game reading both sees two). Keyboard and mouse turns sticks and buttons into keys and the mouse, for games without controller support, and the game sees no controller."))
            if entry.controllerMode == "keys" {
                let changed = (entry.controllerBinds ?? [:]).count + (entry.padMouseVertical == nil ? 0 : 1)
                settings.append(BCDGameSetting(id: "binds", title: "控制器绑定", kind: .opens(.section("binds")),
                                               value: changed == 0 ? "BCD's layout" : "\(changed) changed", defaultValue: "BCD's layout",
                                               note: "键盘鼠标模式下每个摇杆与按键分别敲击什么。"))
            }
        }
        settings += [
            BCDGameSetting(id: "hud", title: "性能 HUD", kind: .choice(BCDHUDLayout.allCases.map { BCDGameChoice(value: $0.rawValue, label: $0.title) }),
                           value: BCDHUDState.setup(for: entry).layout.rawValue, defaultValue: BCDHUDState.everyGame.rawValue,
                           note: "What shows over the game while you play: 1 the frame rate, 2 one line, 3 adds the load and a graph, 4 everything for a bug report, Custom your own readings. Its position and the Custom readings are set in the in-game menu, under Display. Settings has the choice for every game."),
            Self.toggle("livelogs", "Log over the game", entry.liveLogs, note: "游戏运行时把 BCD 日志叠在画面上，便于定位问题。"),
        ]
        return BCDGameSettingGroup(id: "controls", title: "操作控制", symbol: "gamecontroller", settings: settings)
    }

    // MARK: Gyro aim

    /// Turning the phone aims the game (BCDGyroAim.swift, BCDGyroLive.swift). Kept for the game by its path in the app's
    /// own preferences, not in the game's config file: how a phone is held is no compatibility setting.
    private func gyro(_ entry: LibraryEntry) -> BCDGameSettingGroup {
        let s = BCDGyroStore.settings(entry.windowsPath)
        let number = BCDGyroMenu.number
        var settings = [
            BCDGameSetting(id: "gyro-aim", title: "转动手机瞄准",
                           kind: .choice([BCDGameChoice(value: "", label: "关闭"), BCDGameChoice(value: "mouse", label: "移动鼠标"),
                                          BCDGameChoice(value: "stick", label: "推动右摇杆")]),
                           value: s.target.rawValue, defaultValue: "",
                           note: "游戏运行时手机陀螺仪用于瞄准：可模拟鼠标，或模拟控制器右摇杆（屏幕控制器或已配对手柄）。默认关闭，关闭时不运行任何相关处理。"),
        ]
        if s.isOn {
            settings += [
                BCDGameSetting(id: "gyro-sens", title: "灵敏度",
                               kind: .choice(BCDGyroSettings.sensitivityChoices.map { BCDGameChoice(value: number($0), label: number($0) + "×") }),
                               value: number(s.sensitivity), defaultValue: "1",
                               note: "1× 表示每度 8 个鼠标计数，或把摇杆推到底每秒转 90 度。"),
                BCDGameSetting(id: "gyro-hold", title: "仅按住时生效",
                               kind: .choice(BCDGyroHold.choices.map { BCDGameChoice(value: $0.0, label: $0.1) }), value: s.hold, defaultValue: "",
                               note: "控制器上的某个按键（屏幕控件或已配对的实体手柄）：只有按住时陀螺仪才瞄准，如同稳住射击的扳机。"),
                BCDGameSetting(id: "gyro-invert", title: "反转",
                               kind: .choice([BCDGameChoice(value: "", label: "无"), BCDGameChoice(value: "x", label: "左右"),
                                              BCDGameChoice(value: "y", label: "上下"), BCDGameChoice(value: "xy", label: "两者")]),
                               value: s.invertWord, defaultValue: ""),
                BCDGameSetting(id: "gyro-deadzone", title: "仍低于",
                               kind: .choice(BCDGyroSettings.deadzoneChoices.map { BCDGameChoice(value: number($0), label: number($0) + "°/s") }),
                               value: number(s.deadzone), defaultValue: "0.5",
                               note: "慢于此角度（度/秒）的转动会被视为手机静止。"),
                BCDGameSetting(id: "gyro-turn", title: "转身",
                               kind: .choice([BCDGameChoice(value: "", label: "世界纵轴"), BCDGameChoice(value: "screen", label: "屏幕纵轴")]),
                               value: s.turn.rawValue, defaultValue: "",
                               note: "「世界纵轴」跟随重力，因此即使手机后仰，视角仍随你的手臂转动。「屏幕纵轴」则以手机自身坐标为基准。"),
            ]
        }
        let headline = !s.isOn ? "关闭" : (s.target == .mouse ? "鼠标" : "右摇杆") + " · " + number(s.sensitivity) + "×"
            + (s.hold.isEmpty ? "" : " · while " + s.hold.uppercased())
        return BCDGameSettingGroup(id: "gyro", title: "陀螺仪瞄准", symbol: "gyroscope", settings: settings, headline: headline)
    }

    // MARK: Controller binds

    /// Keyboard-and-mouse mode's binds (LibraryEntry.controllerBinds, padMouseVertical): what
    /// each input presses; an input left on its default follows a touch control bound to it,
    /// else BCD's layout (PadBindings.template). Changes apply from the game's next start.
    private func binds(_ entry: LibraryEntry) -> BCDGameSettingGroup? {
        guard GamepadInput.keyboardMouseAvailable, entry.controllerMode == "keys" else { return nil }
        let table = entry.controllerBinds ?? [:]
        var settings: [BCDGameSetting] = []
        for section in BCDPadBinds.sections {
            for (index, input) in section.inputs.enumerated() {
                let value = table[input].map(Self.bindValue) ?? ""
                let standard = BCDPadBinds.label(Self.bindValue(PadBindings.templateAction(input)), input: input)
                settings.append(BCDGameSetting(id: "bind." + input, title: BCDPadBinds.inputName(input),
                                               kind: .choice(BCDPadBinds.choices(for: input, current: value, standard: standard)),
                                               value: value, defaultValue: "", heading: index == 0 ? section.title : nil))
            }
        }
        // The right stick moves the mouse unless it drives keys: how fast it moves it up and down.
        if (table["RS"] ?? PadBindings.templateAction("RS")).stickKeys == nil {
            let speed = entry.padMouseVertical ?? 1
            settings.append(BCDGameSetting(id: "bind.vertical", title: "上下速度",
                                           kind: .choice(BCDPadBinds.speeds(current: speed)),
                                           value: String(format: "%.2f", speed), defaultValue: "1.00",
                                           note: "相对于左右速度的比例。不同游戏对鼠标的转向与抬头速度比例不同：如果上下比左右快，就调低此项。",
                                           heading: "Right stick as the mouse"))
        }
        let changed = table.count + (entry.padMouseVertical == nil ? 0 : 1)
        if changed > 0 {
            settings.append(BCDGameSetting(id: "bind.reset", title: "还原所有绑定", kind: .action,
                                           note: "所有输入恢复默认，鼠标上下与左右速度保持一致。",
                                           question: BCDGameQuestion(title: "还原所有控制器绑定？",
                                                                     message: "每个摇杆和按键都会恢复默认：优先使用绑定它的触摸控件，否则使用 BCD 的布局。右摇杆的上下速度恢复为与左右速度一致。",
                                                                     confirm: "还原", destructive: true),
                                           destructive: true))
        }
        return BCDGameSettingGroup(id: "binds", title: "控制器绑定", symbol: "keyboard", settings: settings,
                                   headline: changed == 0 ? "BCD's layout" : "\(changed) changed", parent: "controls")
    }

    /// A bind as the page's value ("key.32") and back.
    private static func bindValue(_ action: ControlAction) -> String {
        switch action {
        case .none: return "none"
        case .mouseLeft: return "mouse.left"
        case .mouseRight: return "mouse.right"
        case .joystickWASD: return "stick.wasd"
        case .joystickArrows: return "stick.arrows"
        case .keyboardToggle: return "keyboard"
        case .key(let code): return "key.\(code)"
        case .pad(let name): return "pad." + name
        }
    }

    private static func bindAction(_ value: String) -> ControlAction? {
        switch value {
        case "none": return ControlAction.none
        case "mouse.left": return .mouseLeft
        case "mouse.right": return .mouseRight
        case "stick.wasd": return .joystickWASD
        case "stick.arrows": return .joystickArrows
        case "keyboard": return .keyboardToggle
        default:
            if value.hasPrefix("key."), let code = Int32(value.dropFirst(4)) { return .key(code) }
            if value.hasPrefix("pad.") { return .pad(String(value.dropFirst(4))) }
            return nil
        }
    }

    // MARK: Launch

    /// How the program starts, for a game BCD starts itself (a game added from Files, or a Steam
    /// game started as its own program); nil for a Steam game started through BCD Dock and for
    /// the Wine desktop.
    private func launch(_ entry: LibraryEntry) -> BCDGameSettingGroup? {
        var settings: [BCDGameSetting] = []
        if entry.usesLaunchOptions {
            settings += [
                BCDGameSetting(id: "start", title: "开始", kind: .choice([
                    BCDGameChoice(value: "direct", label: "自动"), BCDGameChoice(value: "desktop", label: "在 Wine 桌面中"),
                ]), value: entry.runsInDesktop ? "desktop" : "direct", defaultValue: "direct",
                    note: "On its own, the game is Wine's first program, with nothing behind it; launchers and message boxes still show over it, a full-screen window drawn without DirectX does not. In a Wine desktop it opens inside a desktop the size of Resolution, where every window shows."),
                BCDGameSetting(id: "workdir", title: "启动目录", kind: .text(prompt: "C:\\Games\\Some Game"),
                               value: entry.workingDirectory ?? "",
                               note: "游戏启动时所在目录，以 C:\\ 路径表示。留空则使用程序自身所在文件夹。"),
                Self.toggle("services", "Start Windows services first", entry.startServices == true,
                            note: "在游戏前启动 Windows 服务，供需要它们的启动器使用（Steam 风格的 COM）。BCD 会为此写一个小的批处理文件。"),
            ]
        }
        if entry.desktop != true && entry.steamAppID == nil {
            settings.append(BCDGameSetting(id: "arguments", title: "启动参数", kind: .text(prompt: "-windowed -nosplash"),
                                           value: entry.arguments, note: "每次启动时传给程序。",
                                           chips: BCDLaunchFlags.quick))
            let words = ["-dx12": "Ask for Direct3D 12", "-dx11": "Ask for Direct3D 11", "-dx10": "Ask for Direct3D 10",
                         "-dx9": "Ask for Direct3D 9", "-windowed": "Ask for a window", "-fullscreen": "Ask for full screen",
                         "-nosplash": "Skip the splash screen"]
            for flag in BCDLaunchFlags.flags {
                settings.append(Self.toggle("flag" + flag, flag, BCDLaunchFlags.has(entry.arguments, flag),
                                            note: (words[flag] ?? flag) + (flag.hasPrefix("-dx") ? "; one Direct3D flag at a time." : ".")))
            }
        }
        guard !settings.isEmpty else { return nil }
        settings.append(BCDGameSetting(id: "command", title: "启动什么", kind: .info, value: entry.commandPreview))
        let warning = entry.usesLaunchOptions && !entry.runsInDesktop && (entry.isBatch || entry.startServices == true)
        return BCDGameSettingGroup(id: "launch", title: "启动", symbol: "play.rectangle", settings: settings,
                                   note: warning ? "Started on its own, Wine stops as soon as its first program ends: a batch file that starts the game and exits ends the game too. Choose In a Wine desktop." : nil,
                                   headline: entry.runsInDesktop ? "在 Wine 桌面中" : (entry.arguments.isEmpty ? "自动" : "On its own · " + entry.arguments))
    }

    // MARK: Steam

    /// The Game language of a Steam download (SteamLanguage): Follow Settings, or one of the languages the game
    /// supports (every language while the cached library does not say). A game's own choice is kept in the app's defaults.
    private func languageSetting(_ appID: Int, _ owned: SteamOwnedGame?) -> BCDGameSetting {
        let current = SteamLanguage.gameChoice(UInt32(appID)) ?? ""
        let supported = Set((owned?.languages ?? []) + (owned?.depotLanguages ?? []))
        var list = [BCDGameChoice(value: "", label: "Follow Settings (\(SteamLanguage.name(SteamLanguage.download)))")]
        for item in SteamLanguage.all where supported.isEmpty || supported.contains(item.code) || item.code == current {
            list.append(BCDGameChoice(value: item.code, label: item.name))
        }
        return BCDGameSetting(id: "language", title: "游戏语言", kind: .choice(list), value: current, defaultValue: "",
                              note: "The language Steam installs for this game, and the one it is told to start in. Follow Settings is Settings › All settings › Steam game language, English unless you changed it. A game without the language gets English. It applies to the next download, update or repair.")
    }

    /// Before the install of a Steam game: the language, and what the download takes.
    private func downloadGroup(_ appID: Int, _ owned: SteamOwnedGame) -> BCDGameSettingGroup {
        var settings = [languageSetting(appID, owned)]
        if let bytes = owned.downloadBytes {
            settings.append(BCDGameSetting(id: "downloadsize", title: "下载大小", kind: .info, value: "About " + BCDFormat.bytes(Int64(clamping: bytes)),
                                           note: "Steam 统计的本次安装所占用 depot 的数值。来自其他游戏共享的 depot 不计入此处。"))
        }
        if let bytes = owned.installBytes {
            settings.append(BCDGameSetting(id: "installsize", title: "本设备上的大小", kind: .info, value: "About " + BCDFormat.bytes(Int64(clamping: bytes))))
        }
        return BCDGameSettingGroup(id: "download", title: "下载", symbol: "arrow.down.circle", settings: settings,
                                   headline: SteamLanguage.name(SteamLanguage.download(for: UInt32(appID))))
    }

    private func steamGroup(_ entry: LibraryEntry, _ appID: Int) -> BCDGameSettingGroup {
        let dock = MadeiraDockModel.shared
        let direct = entry.startsSteamGameDirectly
        var settings = [
            BCDGameSetting(id: "startwith", title: "启动方式", kind: .choice([
                BCDGameChoice(value: "", label: "BCD Dock（Steam 客户端）"),
                BCDGameChoice(value: SteamDirectStart.mode, label: "游戏自身的程序"),
            ]), value: direct ? SteamDirectStart.mode : "", defaultValue: "",
                note: "BCD Dock 通过 Valve 的 Steam 客户端启动游戏（不显示窗口）：客户端登录并做最终判断，与 PC 上一致。游戏自身的程序不经 Steam 直接启动：适用于无 DRM 的游戏，需要 Steam 的游戏这样无法启动。"),
        ]
        if direct {
            let found = programs[appID] ?? []
            if resolving.contains(appID) && entry.steamProgram == nil {
                settings.append(BCDGameSetting(id: "program", title: "程序", kind: .info, value: "Looking for the game's programs…"))
            } else if found.isEmpty && entry.steamProgram == nil {
                settings.append(BCDGameSetting(id: "program", title: "程序", kind: .info,
                                               value: "There's no Windows program in this game's install folder."))
            } else {
                var list = found.map { BCDGameChoice(value: $0, label: $0) }
                if let chosen = entry.steamProgram, !found.contains(chosen) { list.insert(BCDGameChoice(value: chosen, label: chosen), at: 0) }
                let source: String
                switch entry.steamProgramSource {
                case "steam": source = (entry.steamProgramArguments ?? "").isEmpty ? "Picked from the game's launch settings on Steam."
                    : "Picked, with its arguments, from the game's launch settings on Steam."
                case "choice": source = "Picked by you."
                case "only": source = "The only program in the install folder."
                default: source = "Pick the program to start."
                }
                settings.append(BCDGameSetting(id: "program", title: "程序", kind: .choice(list), value: entry.steamProgram ?? "",
                                               defaultValue: entry.steamProgram ?? "", note: source))
            }
        } else {
            // A Steam game with more than one launch entry Valve's client could start lets you pick which one; one that never
            // picked starts as it always did (SteamDirectStart.dockLaunch). Nothing is shown for a game with a single entry.
            let listed = dockOptions[appID] ?? []
            if listed.count > 1 || entry.steamLaunchOption != nil {
                var list = [BCDGameChoice(value: "", label: "Steam 决定")]
                list += listed.map { BCDGameChoice(value: String($0.index), label: $0.label) }
                let chosen = entry.steamLaunchOption.map(String.init) ?? ""
                let known = chosen.isEmpty || listed.contains { String($0.index) == chosen }
                settings.append(BCDGameSetting(id: "launchoption", title: "Steam 启动选项", kind: .choice(list),
                                               value: known ? chosen : "", defaultValue: "",
                                               note: known ? "Which of the game's launch entries Steam starts. Steam's choice is the first one that runs here, as before."
                                                           : "The entry chosen earlier is not in Steam's list for this install any more, so Steam's choice starts."))
            }
            settings.append(Self.toggle("smallpool", "较小的 JIT 池（512 MB）", dock.compactPool,
                                        note: "通过 BCD Dock 启动时使用 512 MB 的 JIT 池（而非默认大小），对所有 Steam 游戏生效，直到 BCD 关闭。"))
            if DockOffline.enabled {
                let custom = SteamGamesModel.shared.games.first { $0.id == appID }?.customExecutables ?? false
                let state: String, why: String
                switch DockOffline.mark(appID, preparedOnline: custom) {
                case .ready(let saved):
                    state = "Ready: Steam can sign in without a connection"
                    why = "Steam signed in online on this device on \(BCDFormat.fullDate(saved)), so it can sign this account in offline. With no internet, BCD asks Steam to start the game offline, and Steam checks its saved sign-in and licenses each time. The saved sign-in runs out after a while: start a game online now and then. Games that need their own servers still need them."
                case .needsFirstStart:
                    state = "Needs one online start of this game"
                    why = "Steam can sign in offline, but this game sets up its program for your account on its first start, and that needs a connection. Start it once online."
                case .needsOnline:
                    state = "Needs one online start of any Steam game"
                    why = "Steam has no saved offline sign-in on this device yet. Start any Steam game once online; after that, installed games can start without a connection."
                }
                settings.append(BCDGameSetting(id: "offline", title: "离线游玩", kind: .info, value: state, note: why))
            }
        }
        if DockInstallers.choiceEnabled, dock.installPrograms[appID] != nil {
            settings.append(BCDGameSetting(id: "installs", title: "一次性安装", kind: .choice([
                BCDGameChoice(value: "1", label: "下次启动时运行"), BCDGameChoice(value: "0", label: "跳过"),
            ]), value: (dock.installRunNext[appID] ?? true) ? "1" : "0", defaultValue: "1",
                note: "Steam 为此游戏列出的安装程序（运行库、启动器）。「运行」：下次启动时运行尚未完成的部分。"))
            let title = entry.title
            settings.append(BCDGameSetting(id: "installrequest", title: "下次启动时", kind: .choice([
                BCDGameChoice(value: "", label: "不再需要"),
                BCDGameChoice(value: DockInstallRequest.record.rawValue, label: "把安装步骤标记为已完成",
                              question: BCDGameQuestion(title: "Count the one-time installs of \(title) as done?",
                                                        message: "针对已完成工作但窗口一直未关闭的安装程序。下次启动时此游戏的安装程序视为已完成，不再运行。不会安装或移除任何内容。",
                                                        confirm: "Count as done", destructive: false)),
                BCDGameChoice(value: DockInstallRequest.reset.rawValue, label: "取消安装标记并重新运行",
                              question: Self.resetQuestion(title, signOut: false)),
                BCDGameChoice(value: DockInstallRequest.resetSignOut.rawValue, label: "同上，并退出 Rockstar 登录",
                              question: Self.resetQuestion(title, signOut: true)),
            ]), value: dock.installRequest[appID]?.rawValue ?? "", defaultValue: "",
                note: "现在设置，在下次通过 BCD Dock 启动游戏时执行；设为「不再需要」可撤销。"))
        }
        if let status = dock.status, !direct {
            settings.append(BCDGameSetting(id: "dockstatus", title: "上次通过 BCD Dock 启动", kind: .info, value: status))
        }
        // The language of a download BCD made (Valve's client installs have none of this): the game's choice, the language
        // the install record names, and Repair in another language.
        let steam = SteamOwnedLibrary.shared
        if let installed = SteamGamesModel.shared.games.first(where: { $0.id == appID }), SteamInstallPaths.isManaged(library: installed.library) {
            let owned = steam.game(appID)
            settings.append(languageSetting(appID, owned))
            let recorded = SteamGamesModel.shared.languages[appID]
            if let recorded {
                settings.append(BCDGameSetting(id: "langinstalled", title: "已安装的语言", kind: .info, value: SteamLanguage.name(recorded)))
            }
            if steam.downloads[appID] == nil, steam.signedIn,
               let wanted = owned?.languageToDownload(recorded: recorded, installedDepots: SteamGamesModel.shared.depots[appID] ?? []) {
                settings.append(BCDGameSetting(id: "langdownload", title: "Download in \(SteamLanguage.name(wanted))", kind: .action,
                                               note: "Adds the game's \(SteamLanguage.name(wanted)) content and tells Steam to start it in that language. The files of the current language stay."))
            }
        }
        settings.append(BCDGameSetting(id: "appid", title: "App ID", kind: .info, value: String(appID)))
        let free = (try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
        if let free {
            settings.append(BCDGameSetting(id: "free", title: "本设备可用空间", kind: .info, value: BCDFormat.bytes(free),
                                           note: "用于更新与修复的空间。"))
        }
        let missing = !direct && !dock.clientInstalled
        return BCDGameSettingGroup(id: "steam", title: "Steam", symbol: "arrow.down.app", settings: settings,
                                   note: missing ? "BCD Dock needs Valve's client components first: download them in Settings › Steam › BCD Dock." : nil,
                                   headline: direct ? "游戏自身的程序" : "Through BCD Dock")
    }

    private static func resetQuestion(_ title: String, signOut: Bool) -> BCDGameQuestion {
        BCDGameQuestion(title: signOut ? "Take out the installs of \(title) and the Rockstar sign-in?" : "Take out the one-time installs of \(title)?",
                        message: "At the next start BCD moves what the one-time installs added to Wine (the Rockstar Games Launcher, Social Club, the Visual C++ 2015-2022 and Vulkan runtimes) into a backup folder in BCD's Documents, and that start runs only the installers. Then restart BCD and start the game. Games that share these installs reinstall them at their next start. Game files and saves stay."
                            + (signOut ? " The Rockstar launcher's sign-in goes too." : ""),
                        confirm: "下次启动时", destructive: true)
    }

    // MARK: Library

    /// `gog`: a GOG or Epic game's name and pictures are the store's, so it has no Name or Find on Steam row.
    private func libraryGroup(_ entry: LibraryEntry, gog: Bool) -> BCDGameSettingGroup {
        let steamGame = entry.steamAppID != nil
        var settings: [BCDGameSetting] = []
        if !gog {
            settings.append(BCDGameSetting(id: "title", title: "名称", kind: .text(prompt: entry.title), value: entry.title,
                                           note: "游戏库中显示的名称。"))
        }
        // Find on Steam, for a game added by hand: a Steam game is its store page already.
        if !steamGame && !gog {
            settings.append(BCDGameSetting(id: "findstore", title: "在 Steam 中查找", kind: .opens(.storeSearch),
                                           value: entry.steamID == nil ? "" : "Found",
                                           note: "在 Steam 商店中查找此游戏，以获取名称与商店图片。"))
        }
        settings.append(BCDGameSetting(id: "cover", title: entry.coverFile == nil ? "Choose a cover picture" : "Choose another cover picture",
                                       kind: .opens(.coverPicture), note: "来自「文件」的图片，用来替代商店封面。"))
        if entry.coverFile != nil {
            let store = gog || (entry.steamAppID ?? entry.steamID) != nil
            settings.append(BCDGameSetting(id: "storeart", title: store ? "Use the store's pictures again" : "Remove your cover picture",
                                           kind: .action, note: store ? "Shows the store's pictures in place of yours." : "The game's own colours stand in."))
        }
        if !gog { settings += exeIconRows(entry) }   // round 604: the program's icon as the cover (BCDGameSetup/BCDGamePageLiveSetup.swift)
        var path = steamGame ? entry.launchWindowsPath : entry.windowsPath
        if entry.startsSteamGameDirectly, !entry.launchArguments.isEmpty { path += "\n" + entry.launchArguments }
        let how: String? = steamGame ? (entry.startsSteamGameDirectly ? "BCD starts this program itself, without Steam."
                                                                       : "Steam's client starts the game from this folder, with its usual launch option.") : nil
        settings.append(BCDGameSetting(id: "path", title: "程序", kind: .info, value: path, note: how))
        return BCDGameSettingGroup(id: "library", title: "游戏库", symbol: "books.vertical", settings: settings, headline: entry.title)
    }

    // MARK: Steam Cloud

    /// Steam Cloud's state for the game (SteamOwnedLibrary.cloud): where a sync stands, the saves
    /// the two sides disagree on, and what the last one moved.
    private func cloud(_ appID: Int, into d: inout BCDGameDetails) {
        let steam = SteamOwnedLibrary.shared
        guard steam.signedIn else { d.cloud = .signedOut; return }
        guard let state = steam.cloud[appID] else { d.cloud = .notChecked; return }
        d.cloudProblem = state.problem
        if let last = state.lastDownload {
            d.cloudReceived = last.files
            d.cloudBackedUp = last.backedUp
        }
        d.cloudSent = state.lastUpload ?? 0
        switch state.phase {
        case .checking: d.cloud = .checking
        case .downloading(let done, let total): d.cloud = .moving(up: false, done: done, total: total)
        case .uploading(let done, let total): d.cloud = .moving(up: true, done: done, total: total)
        case .failed(let message): d.cloud = .failed(message)
        case .ready:
            let seconds: (UInt64) -> Date? = { $0 == 0 ? nil : Date(timeIntervalSince1970: TimeInterval($0)) }
            d.cloudConflicts = state.conflicts.map { save in
                BCDCloudConflict(name: save.name, cloudDate: seconds(save.cloudTime), cloudBytes: Int64(clamping: save.cloudSize),
                                 deviceDate: save.kind == .cloudOnly ? nil : (seconds(save.localTime) ?? .distantPast),
                                 deviceBytes: Int64(clamping: save.localSize))
            }
            let audit = state.audit
            let waiting = audit.count(.differ) + audit.count(.cloudOnly) + audit.count(.localOnly)
            if !state.conflicts.isEmpty {
                d.cloud = .differ(state.conflicts.count)
            } else {
                d.cloud = waiting > 0 ? .waiting(waiting) : .synced(matching: audit.count(.same))
            }
        }
    }

    // MARK: Auto-tune

    /// Settings › Auto-tune on, for a game it can tune: this game's switch, where its search
    /// stands and what it tried. Off, nothing of it is read.
    private func tuning(_ entry: LibraryEntry, into d: inout BCDGameDetails) {
        let path = entry.windowsPath
        let tuned = AutoTune.enabled && AutoTune.eligible(entry) ? (on: AutoTune.isOn(path), state: AutoTune.state(path), most: AutoTuneEngine.maxAttempts) : nil
        guard let tuned else { return }
        let state = tuned.state
        // The last start failed because a .NET program found no Wine Mono (AutoTuneState.monoMissing), and nothing has
        // been downloaded since: the page says where to get it. Read here, so only while auto-tune is on.
        d.needsWineMono = state.monoMissing == true && !WineMonoModel.available
        let history = !state.attempts.isEmpty || !state.kept.isEmpty
        let steps = state.attempts.reversed().map { step -> (title: String, detail: String) in
            var words = [Self.said(step.outcome), "stage \(step.stage)", "\(Int(step.seconds)) s", "\(step.presents) frames"]
            if let kept = step.kept { words.append(kept ? "kept" : "taken back") }
            let lines = step.lines.isEmpty ? "" : "\n" + step.lines.joined(separator: "\n")
            return (step.rule.map { $0 == "retry" ? "Same settings, once more" : $0 } ?? "First run", words.joined(separator: " · ") + lines)
        }
        var status: String
        switch state.status {
        case "trying":
            if let next = state.candidate {
                status = next.isEmpty ? "Next start: the same settings once more."
                    : "Next start tries \(next.joined(separator: "; ")) (attempt \(state.decided + 1) of \(tuned.most))."
            } else {
                status = "Waiting for the next start."
            }
        case "found": status = "Found: " + state.kept.joined(separator: "; ")
        case "ok": status = "It played without changes."
        case "stuck": status = "No known fix fits the last failure (tried: \(state.triedSummary)). " + Self.reportAdvice
                                 + (state.lowDiskNote.map { " " + $0 } ?? "")   // round 624 (agent D3 S5-3): no swap file for lack of storage
        case "gave-up": status = "Stopped after \(tuned.most) attempts. " + Self.reportAdvice
        case "known":
            status = "\(state.knownLead): \(state.knownReason ?? state.known ?? "a known problem")."
            if state.knownNoFix != true, let fixed = state.knownFixedIn {
                if let ran = state.knownBuild, ran >= fixed {
                    status += " Build \(fixed) was to fix it, yet build \(ran) still crashed: share the report."
                } else {
                    status += " Build \(fixed) fixes it: update BCD."
                }
            }
        default: status = "Play once: the first start is the baseline."
        }
        d.tuning = BCDGameTuning(on: tuned.on, status: tuned.on || history ? status : nil, canUndo: history, found: state.kept, history: steps)
        if tuned.on && history { d.settings = "Auto-tune on" }   // on for every game now: the label says so only once it has a search or kept lines, so "Recommended" and "Your own" stay visible
    }

    /// Without the increased memory limit the setup, not BCD, is the usual cause, and a report
    /// cannot fix it: say what can (2026-10-20: 54 of 257 logs came from such installs).
    private static let reportAdvice: String = EntitlementStatus.check().increasedMemory
        ? "Share the report to send it."
        : "This install lacks the increased memory limit, the usual cause on it: add it with GetMoreRam, or sign BCD with a paid developer account, before sending a report."

    /// How a start ended, in auto-tune's words.
    private static func said(_ outcome: String) -> String { AutoTune.enabled ? AutoTuneOffer.outcomeText(outcome) : outcome }

    // MARK: What the page does

    /// What a game's page does when it opens: a game seen for the first time gets its
    /// recommended settings (GameRecommendationsApply.swift), the program's graphics API is read
    /// once, the install records and BCD Dock's per-game state are read again, a Steam game not
    /// yet compared with Steam Cloud in this run is, and "游戏自身的程序" finds its program.
    func opened(_ game: BCDGame) {
        dlcOpened(game)
        BCDLiveStore.shared.epicOpened(game.id)
        guard game.state.isInstalled else { return }
        if var entry = entry(for: game) {
            var changed = moveOldFields(&entry)
            let isNew = !LibraryModel.shared.entries.contains { $0.id == entry.id }
            if GameRecommendations.prepare(&entry, new: isNew) { changed = true }
            if changed { LibraryModel.shared.save(entry) }
            readGraphicsAPI(game, entry)
        }
        guard let id = appID(game) else { return }
        SteamGamesModel.shared.refresh()
        MadeiraDockModel.shared.refresh()
        let steam = SteamOwnedLibrary.shared
        if SteamOwnedLibrary.cloudEnabled, steam.signedIn, steam.cloud[id] == nil {
            Task { await steam.syncCloud(id) }
        }
        resolveProgram(game)
        readDockOptions(game)
    }

    /// The entries of Steam's launch configuration a Dock start can run, for "Steam 启动选项": from the cached library
    /// only (no connection is opened for it), off the main thread. A game with no more than one such entry shows no choice.
    private func readDockOptions(_ game: BCDGame) {
        guard let entry = entry(for: game), let appID = entry.steamAppID,
              let launches = SteamOwnedLibrary.shared.game(appID)?.launches, launches.allSatisfy({ $0.index != nil }) else { return }
        let folder = LibraryModel.drive.appendingPathComponent(entry.relativePath, isDirectory: true)
        Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { SteamDirectStart.dockOptions(launches, installFolder: folder) }.value
            guard let self, self.dockOptions[appID] != found else { return }
            self.dockOptions[appID] = found
            self.onChange?()
        }
    }

    /// The Direct3D version (or other API) a game's program imports, read off the main thread
    /// once for an entry that has none yet; the facts card shows it.
    private func readGraphicsAPI(_ game: BCDGame, _ entry: LibraryEntry) {
        guard entry.graphicsAPI == nil, entry.desktop != true else { return }
        let relative = entry.relativePath, id = entry.id
        Task { [weak self] in
            let api = await Task.detached(priority: .utility) { () -> String? in
                guard let program = try? LibraryModel.executable(relative) else { return nil }
                return LibraryModel.graphicsImports(program)
            }.value
            guard let api, let self, var now = self.entry(for: game), now.id == id, now.graphicsAPI == nil else { return }
            now.graphicsAPI = api
            LibraryModel.shared.save(now)
        }
    }

    /// Upstream's own fields for switches the fork keeps elsewhere (AVX, NVIDIA, frame generation,
    /// MetalFX, config lines) move there once, as the fork has moved them since 2026-10-12: this
    /// page then shows and changes what a start uses. True when the entry changed.
    private func moveOldFields(_ entry: inout LibraryEntry) -> Bool {
        let path = entry.windowsPath
        let file = GameProfile(windowsPath: path)
        var moved: [String] = []
        if entry.avx == true { LibraryPrefs.setAVX(true, for: path); moved.append("avx") }
        if entry.reportNVIDIA == true { LibraryPrefs.setNvidia(true, for: path); moved.append("nvidia") }
        if #available(iOS 26.0, *) {
            if entry.frameGeneration == true, file.get("env.MADEIRA_FRAMEGEN") == nil {
                file.set("env.MADEIRA_FRAMEGEN", "1"); moved.append("framegen")
            }
        }
        if let factor = entry.metalFXUpscale, file.get("metalfx-upscale") == nil {
            file.set("metalfx-upscale", factor == factor.rounded() ? String(Int(factor)) : String(factor))
            moved.append("metalfx")
        }
        if let config = entry.config, !config.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // The entry's lines first, the file's after: a key both set keeps the file's value.
            let old = file.text
            file.text = config + (config.hasSuffix("\n") ? "" : "\n") + old
            moved.append("config")
        }
        guard !moved.isEmpty else { return false }
        entry.avx = nil
        entry.reportNVIDIA = nil
        if moved.contains("framegen") { entry.frameGeneration = nil }
        entry.metalFXUpscale = nil
        entry.config = nil
        LogStore.shared.log("[bcd] \(entry.title): moved \(moved.joined(separator: ",")) into the game's own settings")
        return true
    }

    func set(_ setting: String, to value: String, for game: BCDGame) {
        if helpSet(setting, to: value, for: game) { return }   // round 604: the "此游戏的帮助" section's rows (BCDGamePageLiveHelp.swift)
        if soundSet(setting, to: value, for: game) { return }   // round 604: the Sound section's audio delay, volume and resume rows (BCDGamePageLiveSound.swift)
        if dlcSet(setting, to: value, for: game) { return }
        if saveBackupsSet(setting, to: value, for: game) { return }   // round 603: the "存档备份" section's rows
        if midiSet(setting, to: value, for: game) { return }   // round 603: the Sound section's MIDI music row
        if inputSet(setting, to: value, for: game) { return }   // round 604: BCDInputPage.swift's rows (turbo and macros, ...)
        if setupSet(setting, to: value, for: game) { return }   // round 604: the setup sections' rows (BCDGameSetup/BCDGamePageLiveSetup.swift)
        let on = value == "1"
        switch setting {
        case "resolution": change(game) { $0.resolution = value }
        case "scaling": change(game) { $0.display = value }
        case "fps":
            guard let mode = Int(value) else { return }
            change(game) { $0.fpsMode = mode }
        case "orientation":
            guard value.isEmpty || BCDOrientationChoice(rawValue: value) != nil else { return }
            change(game) { $0.orientationLock = value.isEmpty ? nil : value }
        case "metalfx-upscale", "dxil-tess-max-factor", "async-submit", "fence-chain", GamepadInput.padModeKey, BCDGPUCards.key, BCDGPUCards.memoryKey:
            setLine(game, setting, value)
        case "framegen":
            if #available(iOS 26.0, *) {
                setLine(game, "env.MADEIRA_FRAMEGEN", on ? "1" : "")
            }
        case "gyro-aim", "gyro-sens", "gyro-hold", "gyro-invert", "gyro-deadzone", "gyro-turn":
            // madeira-bcd (2026-10-25, round 603): gyro aim, kept for the game by its path (BCDGyroStore).
            if let entry = entry(for: game) {
                BCDGyroStore.set(entry.windowsPath, setting, value)
                BCDGyroLive.shared.refresh()
            }
        case "anisotropy": change(game) { $0.anisotropyLimit = Int(value).flatMap { $0 == 0 ? nil : $0 } }
        case "nvidia": entry(for: game).map { LibraryPrefs.setNvidia(on, for: $0.windowsPath) }
        case "avx": entry(for: game).map { LibraryPrefs.setAVX(on, for: $0.windowsPath) }
        case "winevcrt": entry(for: game).map { LibraryPrefs.setWineVCRT(on, for: $0.windowsPath) }
        case "x87": change(game) { $0.reducedX87 = on }
        case "cpus": change(game) { $0.cpuCount = Int(value).flatMap { $0 == 0 ? nil : $0 } }
        case "fastsync": change(game) { $0.fastSync = on }
        case "semaphores": change(game) { $0.semaphoreFastPath = on }
        case "touch": change(game) { $0.touchControls = on }
        case "hud":
            guard let layout = BCDHUDLayout(rawValue: value) else { return }
            change(game) { BCDHUDState.apply(layout, to: &$0) }
        case "livelogs": change(game) { $0.liveLogs = on }
        case "opacity": if let level = Double(value) { change(game) { $0.controlOpacity = min(max(level, 0.15), 1) } }
        case "size": if let level = Double(value) { change(game) { $0.controlSize = min(max(level, 0.5), 2) } }
        case "controller": change(game) { $0.controllerMode = value.isEmpty ? nil : value }
        case "bind.vertical":
            guard let speed = Double(value), speed.isFinite else { return }
            change(game) { $0.padMouseVertical = abs(speed - 1) < 0.01 ? nil : min(max(speed, 0.25), 1.5) }
        case "bind.reset":
            change(game) { entry in
                entry.controllerBinds = nil
                entry.padMouseVertical = nil
            }
        case let bind where bind.hasPrefix("bind."):
            let input = String(bind.dropFirst(5))
            let action = Self.bindAction(value)
            guard value.isEmpty || action != nil else { return }
            change(game) { entry in
                var table = entry.controllerBinds ?? [:]
                table[input] = action
                entry.controllerBinds = table.isEmpty ? nil : table
            }
        case "start": change(game) { $0.launchMode = value == "desktop" ? "desktop" : nil }
        case "workdir":
            let folder = value.trimmingCharacters(in: .whitespaces)
            change(game) { $0.workingDirectory = folder.isEmpty ? nil : folder }
        case "services": change(game) { $0.startServices = on ? true : nil }
        case "arguments": change(game) { $0.arguments = value }
        case let flag where flag.hasPrefix("flag-"):
            let word = String(flag.dropFirst(4))
            change(game) { entry in
                if BCDLaunchFlags.has(entry.arguments, word) != on { entry.arguments = BCDLaunchFlags.toggled(entry.arguments, word) }
            }
        case "startwith":
            let mode: String? = value == SteamDirectStart.mode ? value : nil
            guard let entry = entry(for: game), entry.steamStart != mode else { return }
            change(game) { $0.steamStart = mode }
            LogStore.shared.log("[steam-start] app=\(entry.steamAppID ?? 0) mode=\(mode == nil ? "dock" : "game")")
            resolveProgram(game)
        case "program":
            guard !value.isEmpty else { return }
            change(game) { entry in
                entry.steamProgram = value
                entry.steamProgramArguments = nil
                entry.steamProgramFolder = nil
                entry.steamProgramSource = "choice"
            }
            LogStore.shared.log("[steam-start] app=\(appID(game) ?? 0) program=choice")
        case "launchoption":
            let key = Int(value)
            guard value.isEmpty || (key != nil && key! >= 0), let id = appID(game) else { return }
            change(game) { $0.steamLaunchOption = key }
            LogStore.shared.log("[steam-start] app=\(id) launch-option=\(key == nil ? "default" : "choice")")
        case "language":
            guard let id = appID(game), value.isEmpty || SteamLanguage.all.contains(where: { $0.code == value }) else { return }
            SteamLanguage.chooseForGame(UInt32(id), value.isEmpty ? nil : value)
        case "langdownload":
            if let id = appID(game), SteamOwnedLibrary.shared.downloads[id] == nil { SteamOwnedLibrary.shared.repair(id) }
        case "smallpool": MadeiraDockModel.shared.compactPool = on
        case "installs": if let id = appID(game) { MadeiraDockModel.shared.setRunsInstallers(id, on) }
        case "installrequest": if let id = appID(game) { MadeiraDockModel.shared.setInstallRequest(id, DockInstallRequest(rawValue: value)) }
        case "title":
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            change(game) { $0.title = name }
        case "storeart": change(game) { $0.coverFile = nil }
        default:
            break
        }
    }

    /// "游戏自身的程序": which program a start runs. The player's own pick stays while it
    /// is installed; otherwise Steam's launch configuration decides, then a program set earlier
    /// that is still installed, then the folder's only program; with none of these the player picks.
    private func resolveProgram(_ game: BCDGame) {
        guard let entry = entry(for: game), entry.startsSteamGameDirectly, let appID = entry.steamAppID,
              resolving.insert(appID).inserted else { return }
        let folder = LibraryModel.drive.appendingPathComponent(entry.relativePath, isDirectory: true)
        let picked = entry.steamProgramSource == "choice" ? entry.steamProgram : nil
        Task { [weak self] in
            let installed = await Task.detached(priority: .userInitiated) { SteamDirectStart.programs(in: folder) }.value
            self?.programs[appID] = installed
            if let picked, installed.contains(picked) {
                self?.resolved(appID)
                return
            }
            let options = await SteamOwnedLibrary.shared.launchOptions(appID: appID) ?? []
            let fromSteam = await Task.detached(priority: .userInitiated) { SteamDirectStart.choose(options, installFolder: folder) }.value
            guard let self else { return }
            defer { self.resolved(appID) }
            guard var now = self.entry(for: game), now.startsSteamGameDirectly, now.steamAppID == appID else { return }
            if let fromSteam {
                now.steamProgram = fromSteam.program
                now.steamProgramArguments = fromSteam.arguments.isEmpty ? nil : fromSteam.arguments
                now.steamProgramFolder = fromSteam.folder
                now.steamProgramSource = "steam"
            } else if !(now.steamProgram.map(installed.contains) ?? false) {
                let only = installed.count == 1 ? installed.first : nil
                now.steamProgram = only
                now.steamProgramArguments = nil
                now.steamProgramFolder = nil
                now.steamProgramSource = only == nil ? nil : "only"
            }
            LibraryModel.shared.save(now)
            LogStore.shared.log("[steam-start] app=\(appID) launch-entries=\(options.count) programs=\(installed.count) source=\(now.steamProgramSource ?? "none")")
        }
    }

    private func resolved(_ appID: Int) {
        resolving.remove(appID)
        onChange?()
    }

    func syncCloud(_ game: BCDGame) {
        guard let id = appID(game) else { return }
        Task { await SteamOwnedLibrary.shared.syncCloud(id) }
    }

    func keepCloudSaves(_ game: BCDGame, fromCloud: Bool) {
        guard let id = appID(game) else { return }
        Task { await SteamOwnedLibrary.shared.resolveCloud(id, useCloud: fromCloud) }
    }

    func resetToRecommended(_ game: BCDGame) {
        change(game) { entry in _ = GameRecommendations.reset(&entry) }
    }

    /// Get the latest recommended settings: BCD asks online for a newer list
    /// (RecommendationsSource.refresh, which puts one into use for every game that follows its
    /// list), then compares this game's config with the newest list for it.
    func refreshRecommendedSettings(for game: BCDGame) async -> BCDRecommendedRefresh {
        let before = entry(for: game).map { GameProfile(windowsPath: $0.windowsPath).text }
        let result = await RecommendationsSource.shared.refresh()
        switch result {
        case .offline(_, let origin, let notPublished):
            return .offline(builtIn: origin == .builtIn, nothingOnline: notPublished)
        case .rejected:
            return .rejected
        case .upToDate, .updated:
            guard let entry = entry(for: game), let rec = GameRecommendations.recommendation(for: entry) else { return .upToDate }
            let now = GameProfile(windowsPath: entry.windowsPath).text
            let differs = Self.changes(now, rec.fileText)
            if differs > 0 { return .available(changes: differs) }
            if let before, before != now { return .updated(changes: Self.changes(before, now)) }
            return .upToDate
        }
    }

    /// Applied as Reset to Recommended applies the list.
    func applyRecommendedSettings(_ game: BCDGame) { resetToRecommended(game) }

    /// How many keys two configs set differently.
    static func changes(_ a: String, _ b: String) -> Int {
        let x = GameProfile.parse(a), y = GameProfile.parse(b)
        return Set(x.keys).union(y.keys).filter { x[$0] != y[$0] }.count
    }

    func setTuning(_ on: Bool, for game: BCDGame) {
        guard let path = entry(for: game)?.windowsPath else { return }
        if AutoTune.enabled { AutoTune.setOn(path, on) }
    }

    func undoTuning(_ game: BCDGame) {
        guard let path = entry(for: game)?.windowsPath else { return }
        if AutoTune.enabled { AutoTune.reset(path) }
    }

    /// Each line auto-tune kept goes into the game's own file, then auto-tune starts over.
    func writeTuningLines(_ game: BCDGame) {
        guard let path = entry(for: game)?.windowsPath else { return }
        let kept = AutoTune.enabled ? AutoTune.state(path).kept : []
        guard !kept.isEmpty else { return }
        let profile = GameProfile(windowsPath: path)
        for line in kept {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { profile.set(parts[0], parts[1]) }
        }
        if AutoTune.enabled { AutoTune.reset(path) }
    }

    /// Auto-tune's report for one game, as text to share: where it stands, what it kept, what
    /// each start tried and how it ended, the best start's signature lines and error boxes.
    func tuningReport(for game: BCDGame) -> String? {
        guard let entry = entry(for: game) else { return nil }
        let path = entry.windowsPath
        guard let state = AutoTune.enabled ? AutoTune.state(path) : nil else { return nil }
        var out = ["BCD auto-tune report: \(entry.title)", "status: \(state.status)"]
        if state.status == "known" { out.append("known crash: \(state.known ?? "-") (\(state.knownReason ?? "-"))") }
        if !state.kept.isEmpty { out.append("kept lines:"); out += state.kept.map { "  " + $0 } }
        if let next = state.candidate { out.append("next start: " + (next.isEmpty ? "the same settings" : next.joined(separator: "; "))) }
        if let best = state.best {
            out.append("best start: \(best.outcome), stage \(best.stage), \(Int(best.seconds)) s, \(best.presents) frames")
        }
        out.append("starts:")
        for step in state.attempts {
            let kept = step.kept.map { $0 ? "kept" : "taken back" } ?? "-"
            out.append("  \(BCDFormat.reportTime(step.date)) \(step.rule ?? "first run") [\(step.lines.joined(separator: "; "))] -> "
                       + "\(step.outcome), stage \(step.stage), \(Int(step.seconds)) s, \(step.presents) frames, \(kept) \(step.log ?? "")")
        }
        if let evidence = state.best?.evidence, !evidence.isEmpty { out.append("signature lines:"); out += evidence.map { "  " + $0 } }
        if let boxes = state.best?.dialogs, !boxes.isEmpty { out.append("error boxes:"); out += boxes.map { "  " + $0 } }
        return out.joined(separator: "\n") + "\n"
    }

    func shortcutLink(for game: BCDGame) -> String? {
        entry(for: game).map { ShortcutRouter.link(for: $0.windowsPath) }
    }

    func backUpSaves() async throws -> BCDSavesBackup {
        let made = try await Task.detached(priority: .userInitiated) { try SaveBackup.backup() }.value
        return BCDSavesBackup(file: made.url, files: made.files, bytes: Int64(clamping: made.bytes), leftOut: made.leftOut)
    }

    func restoreSaves(from file: URL) async throws -> Int {
        try await Task.detached(priority: .userInitiated) { try SaveBackup.restore(from: file) }.value
    }

    /// The newest of the logs Send Log offers (LogUpload.recentLogs) that is this game's: logs are
    /// named after the program a start ran (LogStore.startSessionLog), and a Steam game started
    /// through BCD Dock after its own program in its install folder (ntdll's session log).
    func lastLog(of game: BCDGame) async -> BCDGameLog? {
        guard let entry = entry(for: game) else { return nil }
        let program = entry.launchWindowsPath.split(separator: "\\").last.map { String($0).lowercased() } ?? ""
        let dock = entry.steamAppID != nil && !entry.startsSteamGameDirectly
        let folder = LibraryModel.drive.appendingPathComponent(entry.relativePath, isDirectory: true)
        let found = await Task.detached(priority: .userInitiated) { () -> URL? in
            var names: Set<String> = [program]
            if dock {
                names.formUnion(SteamDirectStart.programs(in: folder).map { ($0.split(separator: "/").last.map(String.init) ?? $0).lowercased() })
            }
            return LogUpload.recentLogs().first { names.contains(LogUpload.game(of: $0).lowercased()) }
        }.value
        guard let found else { return nil }
        return BCDGameLog(file: found, name: found.lastPathComponent, date: LogUpload.modified(found), bytes: LogUpload.size(found))
    }

    func logComment() async -> String? { await logComment(for: nil) }

    func logComment(for log: BCDGameLog) async -> String? { await logComment(for: log.file) }

    private func logComment(for file: URL?) async -> String? {
        await withCheckedContinuation { continuation in
            BCDLogComment.ask(for: file, { continuation.resume(returning: $0) }, cancelled: { continuation.resume(returning: nil) })
        }
    }

    /// Send Log, by hand, as Settings › Send Log sends one (LogUpload.send).
    func send(_ log: BCDGameLog, of game: BCDGame, comment: String, progress: @escaping (String) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            LogUpload.send(log.file, game: LogUpload.game(of: log.file), comment: comment, progress: progress) { result in
                // madeira-bcd (round 624, agent R S13 / Discord W4: four players could not find or copy their code): the same alert a
                // crash's Send Log shows, with the code and a Copy code button; the row's message stays as it was.
                BCDCrashPrompt.report(result)
                // A screenshot that went along says so after the code (LogUpload.lastShotNote).
                continuation.resume(with: result.map { code in LogUpload.lastShotNote.map { code + ". " + $0 } ?? code })
            }
        }
    }

    // MARK: Config, Find on Steam, the cover picture

    /// The game's own file (GameProfiles.swift), the one every start of the game reads.
    func configText(for game: BCDGame) -> String? {
        entry(for: game).map { GameProfile(windowsPath: $0.windowsPath).text }
    }

    func saveConfig(_ text: String, for game: BCDGame) {
        guard let entry = entry(for: game) else { return }
        let profile = GameProfile(windowsPath: entry.windowsPath)
        if profile.text != text { profile.text = text }
        if !LibraryModel.shared.entries.contains(where: { $0.id == entry.id }) { LibraryModel.shared.save(entry) }
    }

    /// Steam's public store search (SteamCatalog): no account involved.
    func searchStore(_ text: String) async throws -> [BCDStoreMatch] {
        try await SteamCatalog.search(text).map { BCDStoreMatch(id: $0.id, name: $0.name, picture: $0.tiny_image.flatMap { URL(string: $0) }) }
    }

    /// The store page's App ID gives a game added by hand the store's pictures (BCDLiveStore), and
    /// the match its name; a cover picture of the player's own gives way to them.
    func useStoreMatch(_ match: BCDStoreMatch, for game: BCDGame) {
        change(game) { entry in
            entry.steamID = match.id
            entry.title = match.name
            entry.coverFile = nil
        }
    }

    /// The picture, at most 20 MB, becomes a JPEG at most 1200 pixels on its long side in
    /// Documents/bcd-art (where the library reads covers), under a new name each time so no
    /// cached copy of the last one shows; the game's last picture of its own goes.
    func setCover(from file: URL, for game: BCDGame) async throws {
        guard let entry = entry(for: game) else { return }
        let folder = LibraryModel.documents.appendingPathComponent("bcd-art", isDirectory: true)
        let name = "\(entry.id.uuidString)-\(Int(Date().timeIntervalSince1970)).jpg"
        try await Task.detached(priority: .userInitiated) {
            try Self.writeCover(from: file, to: folder.appendingPathComponent(name))
        }.value
        let old = entry.coverFile
        change(game) { $0.coverFile = name }
        if let old, old != name, old.hasPrefix(entry.id.uuidString) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(URL(fileURLWithPath: old).lastPathComponent))
        }
    }

    nonisolated private static func writeCover(from file: URL, to target: URL) throws {
        let opened = file.startAccessingSecurityScopedResource()
        defer { if opened { file.stopAccessingSecurityScopedResource() } }
        let bytes = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard bytes <= 20_000_000 else { throw BCDGameError("Choose a picture under 20 MB.") }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: 1200,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceShouldCacheImmediately: true]
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let picture = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw BCDGameError("BCD couldn't read this picture. Choose a JPEG, PNG or HEIC picture.")
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let out = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw BCDGameError("BCD couldn't save the picture.")
        }
        CGImageDestinationAddImage(out, picture, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(out) else {
            try? FileManager.default.removeItem(at: target)
            throw BCDGameError("BCD couldn't save the picture.")
        }
    }

    // MARK: Watching the engine while a page is open

    /// The page reads its details again when a game's settings, its Steam records, Steam Cloud,
    /// the sign-in, BCD Dock's per-game state or the recommended settings' list change; and it
    /// closes when the engine has something to tell on the main screen (a session starting, an
    /// error, a notice).
    private func watch() {
        watching.removeAll()
        guard onChange != nil || onNotice != nil else {
            // The page closed: nothing of it stays alive.
            programs.removeAll()
            return
        }
        let library = LibraryModel.shared
        let steam = SteamOwnedLibrary.shared
        let games = SteamGamesModel.shared
        let dock = MadeiraDockModel.shared
        let lists = RecommendationsSource.shared
        let changes: [AnyPublisher<Void, Never>] = [
            library.$entries.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            steam.$cloud.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            steam.$signedIn.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            steam.$downloads.map { Set($0.keys) }.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            games.$games.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            games.$builds.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            dock.$installRunNext.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            dock.$installRequest.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            dock.$installPrograms.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            dock.$compactPool.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            dock.$status.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            lists.$version.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            lists.$lastChecked.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            dlcChanges,
            BCDLiveStore.shared.epicDetailChanges,
        ]
        Publishers.MergeMany(changes)
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] in self?.onChange?() }
            .store(in: &watching)
        let notices: [AnyPublisher<Bool, Never>] = [
            library.$current.dropFirst().map { $0 != nil }.eraseToAnyPublisher(),
            library.$error.dropFirst().map { $0 != nil }.eraseToAnyPublisher(),
            library.$restartNotice.dropFirst().map { $0 != nil }.eraseToAnyPublisher(),
            library.$jitNotice.dropFirst().map { $0 != nil }.eraseToAnyPublisher(),
            library.$cloudNotice.dropFirst().map { $0 != nil }.eraseToAnyPublisher(),
        ]
        Publishers.MergeMany(notices)
            .filter { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.onNotice?() }
            .store(in: &watching)
    }
}
