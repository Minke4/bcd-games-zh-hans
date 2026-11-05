// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Settings' sections (BCDSettings.swift draws the frame around them). Each section reads and
// changes the engine only through its backend protocol: BCDSettingsLive.swift implements them
// with the engine's own settings and functions, the preview app with sample data. The words
// on screen are all here, so the preview shows exactly what the app shows.

private func gigabytes(_ megabytes: Int) -> String { String(format: "%g GB", Double(megabytes) / 1024) }
private func memoryText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory) }

/// Graphics' frame caps, Controls' opacity and speed steps (frames a second, fractions, multiples).
private let frameCaps = [24, 30, 40, 60]
private let opacitySteps = [0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9, 1.0]
private let speedSteps = [0.1, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.5, 3, 3.5, 4, 5, 6, 7, 8]

/// Storage's words for the engine's items, by id.
private let storageWords: [String: (String, String)] = [
    "capture": ("Captured frames", "Pictures saved by the performance overlay's capture button."),
    "logs": ("Older session logs", "Earlier games' logs. BCD keeps the newest 40 by itself."),
    "sc12": ("Direct3D 12 shader cache", "Shaders already converted for Metal. After a clear, games convert them again and start slower once."),
    "sc11": ("Direct3D 11 shader cache", "Compiled shaders of Direct3D 9, 10 and 11 games."),
    "drive": ("Drive C: (Windows)", "Your games, their saves and Windows' own files."),
    "mono": ("Wine Mono", "The .NET runtime. Remove it under .NET Framework."),
]

// MARK: - Memory & performance

/// The memory switches Settings shows (the engine's JIT pool, video memory, swap file...).
enum BCDMemoryKey: String, CaseIterable {
    case pool, videoMemory, swap, swapCoverage, memoryPool, syncEngine
}

struct BCDMemoryStatus: Hashable {
    /// What iOS lets BCD use, measured now (what it uses plus what is still free to it).
    var limitBytes: Int64?
    var deviceBytes: Int64
    var increasedLimit: Bool
    var extendedAddressing: Bool
    /// The end of the address space games can reserve in.
    var addressSpaceBytes: Int64?
}

@MainActor protocol BCDMemoryBackend: ObservableObject {
    var status: BCDMemoryStatus { get }
    /// The build can hide the switches; the status stays.
    var switchesShown: Bool { get }
    /// The values a switch offers, in order. "" is the engine's own default.
    func choices(_ key: BCDMemoryKey) -> [String]
    func value(_ key: BCDMemoryKey) -> String
    func set(_ key: BCDMemoryKey, _ value: String)
    var eco: Bool { get }
    func setEco(_ on: Bool)
    /// A switch changed this run: it applies from BCD's next start.
    var restartNeeded: Bool { get }
    var extensionTestAvailable: Bool { get }
    var extensionTestRunning: Bool { get }
    var extensionTestLine: String? { get }
    func runExtensionTest()
    func refresh()
}

struct BCDMemorySettings<Backend: BCDMemoryBackend>: View {
    @ObservedObject var backend: Backend

    var body: some View {
        let status = backend.status
        VStack(alignment: .leading, spacing: 18) {
            BCDSettingsGroup(title: "本设备") {
                BCDSettingsInfoRow(title: "BCD 可使用",
                                   note: "当前实测值。超过此值，iOS 会关闭 BCD 并连带关闭游戏。",
                                   value: status.limitBytes.map(memoryText) ?? "Not measured")
                BCDSettingsInfoRow(title: "提高内存上限",
                                   note: status.increasedLimit
                                       ? "This copy of BCD carries Apple's increased-memory entitlement."
                                       : "Missing: iOS closes large games early. Sign BCD with a profile that grants the increased-memory entitlement.",
                                   value: status.increasedLimit ? "开启" : "关闭",
                                   valueColor: status.increasedLimit ? BCDStyle.mint : BCDSettingsColor.amber)
                BCDSettingsInfoRow(title: "扩展地址空间",
                                   note: status.extendedAddressing
                                       ? "Games can reserve up to \(status.addressSpaceBytes.map(memoryText) ?? "512 GB") of addresses."
                                       : "The standard space of about 64 GB. A few large games need the extended-virtual-addressing entitlement.",
                                   value: status.extendedAddressing ? "开启" : "关闭",
                                   valueColor: status.extendedAddressing ? BCDStyle.mint : BCDSettingsColor.amber)
                BCDSettingsInfoRow(title: "本设备内存", value: memoryText(status.deviceBytes))
            }
            if backend.switchesShown {
                BCDSettingsGroup(title: "游戏内存") {
                    row(.pool, "JIT pool",
                        "Set aside when a game starts, for the x86 code BCD has translated. Below 512 MB, big games can run out of room.")
                    row(.videoMemory, "Video memory",
                        "The graphics memory games are told they have. Automatic decides from what is free at the start. Too much and iOS may close BCD; too little and games keep reloading textures.")
                    row(.swap, "Swap file",
                        "When memory runs short, game data moves into a file on this device, up to this size. It costs some speed.")
                    row(.swapCoverage, "What can move",
                        "Which of a game's allocations may move into the swap file. The wider, the more memory it saves and the more it can slow a game.",
                        enabled: backend.value(.swap) != "")
                    row(.memoryPool, "Helper memory",
                        "Memory from BCD's helper extension, outside BCD's own limit, used before the swap file while the device has some to spare. Experimental; needs the swap file.",
                        enabled: backend.value(.swap) != "")
                }
                BCDSettingsGroup(title: "速度与功耗") {
                    row(.syncEngine, "Thread sync",
                        "How a game's threads wait for each other. Fastsync, the standard, does it inside the game; Madsync is the earlier engine of that kind; Wine's own uses neither.")
                    BCDSettingsToggleRow(id: BCDSettingsID.control(.memory, "eco"), title: "节能模式",
                                         note: "所有游戏以低线程优先级启动：更凉快、更省电，但更慢。适合加载画面较多的场合。",
                                         isOn: backend.eco) { backend.setEco($0) }
                }
                if backend.restartNeeded { BCDSettingsNotice(text: bcdSettingsRestartNote) }
            }
            if backend.extensionTestAvailable {
                BCDSettingsGroup(title: "实验功能") {
                    BCDSettingsActionRow(id: BCDSettingsID.control(.memory, "extension-test"),
                                         title: backend.extensionTestRunning ? "Testing the helper's memory…" : "Test the helper's memory",
                                         note: backend.extensionTestLine ?? "Checks whether memory made by BCD's helper extension stays outside BCD's own limit. The result goes to the log.",
                                         symbol: "memorychip", enabled: !backend.extensionTestRunning) { backend.runExtensionTest() }
                }
            }
        }
        .onAppear { backend.refresh() }
    }

    private func row(_ key: BCDMemoryKey, _ title: String, _ note: String, enabled: Bool = true) -> some View {
        BCDSettingsValueRow(id: BCDSettingsID.control(.memory, key.rawValue), title: title, note: note,
                            choices: backend.choices(key).map { BCDSettingsChoice(value: $0, label: Self.label(key, $0)) },
                            value: backend.value(key), enabled: enabled) { backend.set(key, $0) }
    }

    static func label(_ key: BCDMemoryKey, _ value: String) -> String {
        let megabytes = Int(value)
        switch key {
        case .pool: return value.isEmpty ? "Standard (896 MB)" : megabytes.map { "\($0) MB" } ?? value
        case .videoMemory: return value.isEmpty ? "Automatic" : megabytes.map(gigabytes) ?? value
        case .swap, .memoryPool: return value.isEmpty ? "关闭" : megabytes.map(gigabytes) ?? value
        case .swapCoverage:
            switch value {
            case "": return "Large blocks (8 MB and up)"
            case "blocks": return "Blocks of 1 MB and up"
            case "wide": return "1 MB and up, and overflow"
            case "broad": return "Whole reservations (4 MB and up)"
            default: return value
            }
        case .syncEngine:
            switch value {
            case "fastsync": return "Fastsync (standard)"
            case "madsync": return "Madsync"
            case "wine": return "Wine 自带"
            default: return value
            }
        }
    }
}

// MARK: - Graphics

/// A size the Windows desktop can have on this screen.
struct BCDResolution: Hashable {
    enum Shape: Hashable { case screen, wide, classic, native }
    var width: Int
    var height: Int
    var shape: Shape
    var value: String { "\(width)x\(height)" }
}

@MainActor protocol BCDGraphicsBackend: ObservableObject {
    /// This screen's sizes, in order.
    var resolutions: [BCDResolution] { get }
    /// The size used while none is chosen ("WxH").
    var defaultResolution: String { get }
    /// The chosen size, "" for the default.
    var resolution: String { get }
    func setResolution(_ value: String)
    /// A cap for every game, frames a second; nil is none.
    var frameCap: Int? { get }
    func setFrameCap(_ fps: Int?)
    /// The screen's highest refresh rate.
    var displayRate: Int { get }
    var holdMaximumRate: Bool { get }
    func setHoldMaximumRate(_ on: Bool)
    /// MetalFX upscaling for games that choose none: "", "1.5" or "2".
    var metalFX: String { get }
    func setMetalFX(_ value: String)
    /// 32-bit Direct3D 9 games: "" (emulated, the standard) or "native".
    var direct3D9: String { get }
    func setDirect3D9(_ value: String)
    /// What the screen does while a game runs (BCDOrientation.swift): "" follows the device, else one of the
    /// BCDOrientationChoice words ("landscape", ...). A game's own page can choose for that game.
    var orientation: String { get }
    func setOrientation(_ value: String)
    /// The build can hide the display switch.
    var displaySwitchesShown: Bool { get }
    var restartNeeded: Bool { get }
    /// The performance HUD every game takes that has none of its own (BCDHUDCore.swift): "" for none, else "1" to "4".
    var hudEveryGame: String { get }
    func setHUDEveryGame(_ value: String)
}

extension BCDGraphicsBackend {
    var hudEveryGame: String { "" }
    func setHUDEveryGame(_ value: String) {}
}

struct BCDGraphicsSettings<Backend: BCDGraphicsBackend>: View {
    @ObservedObject var backend: Backend
    @EnvironmentObject private var model: BCDSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BCDSettingsGroup(title: "针对所有游戏",
                             footer: "A game's own choices, on its page, come first: its resolution, its FPS limit (60 unless you change it), its MetalFX, its screen orientation.") {
                BCDSettingsValueRow(id: BCDSettingsID.control(.graphics, "resolution"), title: "分辨率",
                                    note: "Windows 桌面的大小，以及通过 BCD Dock 启动且自身未设置分辨率的 Steam 游戏所用的大小。",
                                    choices: resolutionChoices, value: backend.resolution) { backend.setResolution($0) }
                BCDSettingsValueRow(id: BCDSettingsID.control(.graphics, "frame-cap"), title: "帧率上限",
                                    note: "所有游戏每秒最多绘制的帧数，低于游戏自身帧率上限时有效。可降低发热与耗电。",
                                    choices: capChoices, value: backend.frameCap.map(String.init) ?? "") { value in
                    backend.setFrameCap(Int(value))
                }
                BCDSettingsValueRow(id: BCDSettingsID.control(.graphics, "metalfx"), title: "MetalFX 超分",
                                    note: "Apple 的 MetalFX 以较低分辨率绘制每帧再放大：更快，但略为柔和。",
                                    choices: [BCDSettingsChoice(value: "", label: "关闭"), BCDSettingsChoice(value: "1.5", label: "1.5×"),
                                              BCDSettingsChoice(value: "2", label: "2×")],
                                    value: backend.metalFX) { backend.setMetalFX($0) }
                BCDSettingsValueRow(id: BCDSettingsID.control(.graphics, "d3d9"), title: "Direct3D 9（32 位游戏）",
                                    note: "32 位 Direct3D 9 游戏的绘制方式：模拟前端、「标准」或原生 ARM64 实现。",
                                    choices: [BCDSettingsChoice(value: "", label: "模拟（标准）"),
                                              BCDSettingsChoice(value: "native", label: "原生 ARM64")],
                                    value: backend.direct3D9) { backend.setDirect3D9($0) }
                BCDSettingsValueRow(id: BCDSettingsID.control(.graphics, "orientation"), title: "屏幕方向",
                                    note: "游戏运行时的屏幕旋转方式。「横屏」无论你怎么持握（例如躺下）都保持横屏；游戏结束后恢复为跟随设备。",
                                    choices: BCDOrientationChoice.offered.map { BCDSettingsChoice(value: $0.setting ?? "", label: $0.label) },
                                    value: backend.orientation) { backend.setOrientation($0) }
            }
            BCDSettingsGroup(title: "性能 HUD",
                             footer: "1 is the frame rate alone, 2 one line, 3 adds the load and a graph, 4 is everything for a bug report. A game's own choice, made in its in-game menu under Display, comes first, and so does an overlay a game already had on. Custom is built there too.") {
                BCDSettingsValueRow(id: BCDSettingsID.control(.graphics, "hud"), title: "针对所有游戏",
                                    note: "它会避开触摸控件与画面，默认关闭，需手动选择。",
                                    choices: [BCDSettingsChoice(value: "", label: "关闭"), BCDSettingsChoice(value: "1", label: "1"), BCDSettingsChoice(value: "2", label: "2"),
                                              BCDSettingsChoice(value: "3", label: "3"), BCDSettingsChoice(value: "4", label: "4")],
                                    value: backend.hudEveryGame) { backend.setHUDEveryGame($0) }
            }
            if backend.displaySwitchesShown && backend.displayRate > 60 {
                BCDSettingsGroup(title: "显示") {
                    BCDSettingsToggleRow(id: BCDSettingsID.control(.graphics, "hold-rate"),
                                         title: "Keep the screen at \(backend.displayRate) Hz",
                                         note: "While a game runs at 60 FPS, the screen stays at its highest rate, so a late frame waits \(1000 / backend.displayRate) ms instead of 17. Uses more power.",
                                         isOn: backend.holdMaximumRate) { backend.setHoldMaximumRate($0) }
                }
            }
            if BCDFoldableDevice.isThisDevice {   // madeira-bcd foldable (experimental, BCDFoldable.swift): the foldable iPhone's Settings only; every other device's Graphics page is unchanged
                BCDSettingsGroup(title: "折叠屏 iPhone") { BCDFoldableSettingsRow() }
            }
            if backend.restartNeeded { BCDSettingsNotice(text: bcdSettingsRestartNote) }
            BCDSettingsGroup {
                BCDSettingsActionRow(id: BCDSettingsID.control(.graphics, "more"), title: "更多图形选项",
                                     note: "Direct3D、DXMT 与 MetalFX 的选项在「全部设置」中。", symbol: "slider.horizontal.3") {
                    model.openAll("Direct3D")
                }
            }
        }
    }

    private var resolutionChoices: [BCDSettingsChoice] {
        var list = [BCDSettingsChoice(value: "", label: "标准 · " + Self.size(backend.defaultResolution))]
        list += backend.resolutions.filter { $0.value != backend.defaultResolution }.map { r in
            let shape: String
            switch r.shape {
            case .screen: shape = ""
            case .wide: shape = " · 16:9"
            case .classic: shape = " · 4:3"
            case .native: shape = " · native"
            }
            return BCDSettingsChoice(value: r.value, label: "\(r.width) × \(r.height)\(shape)")
        }
        if !backend.resolution.isEmpty, !list.contains(where: { $0.value == backend.resolution }) {
            list.append(BCDSettingsChoice(value: backend.resolution, label: Self.size(backend.resolution) + " · yours"))
        }
        return list
    }

    private var capChoices: [BCDSettingsChoice] {
        var list = [BCDSettingsChoice(value: "", label: "关闭")] + frameCaps.map { BCDSettingsChoice(value: String($0), label: "\($0) FPS") }
        if let cap = backend.frameCap, !frameCaps.contains(cap) { list.append(BCDSettingsChoice(value: String(cap), label: "\(cap) FPS")) }
        return list
    }

    private static func size(_ value: String) -> String { value.replacingOccurrences(of: "x", with: " × ") }
}

// MARK: - Controls

enum BCDPointerMode: String, CaseIterable {
    case absolute, touch, relative
    var title: String {
        switch self {
        case .absolute: return "触控板"
        case .touch: return "Touch"
        case .relative: return "鼠标视角"
        }
    }
}

struct BCDControlLayout: Identifiable, Hashable {
    var id: String
    var name: String
    var builtIn: Bool
}

/// A controller input and what it does in keyboard-and-mouse mode.
struct BCDSettingsBinding: Hashable {
    var input: String
    var action: String
}

@MainActor protocol BCDControlsBackend: ObservableObject {
    var touchControls: Bool { get }
    func setTouchControls(_ on: Bool)
    var opacity: Double { get }
    func setOpacity(_ value: Double)
    /// Named layouts: the build can switch them off.
    var layoutsShown: Bool { get }
    var layouts: [BCDControlLayout] { get }
    var activeLayout: String? { get }
    /// Controls on screen that no layout holds: switching away loses them unless kept.
    var unsavedControls: Bool { get }
    var canSaveLayouts: Bool { get }
    var nextLayoutName: String { get }
    func useLayout(_ id: String, keepCurrentFirst: Bool)
    /// A new empty layout; true when it was made (the editor opens on it).
    func newLayout() -> Bool
    func deleteLayout(_ id: String)
    /// Round 604: a custom layout as a small file to send to someone, and a layout from such a file added to the list (BCDControlShareLive.swift).
    var canShareLayouts: Bool { get }
    func shareLayout(_ id: String)
    func importLayoutFromFile()
    /// The on-screen layout editor, full screen; nil where there is none (the preview app).
    func editor(close: @escaping () -> Void) -> AnyView?
    var pointer: BCDPointerMode { get }
    func setPointer(_ mode: BCDPointerMode)
    var touchSpeed: Double { get }
    func setTouchSpeed(_ value: Double)
    var lookSpeed: Double { get }
    func setLookSpeed(_ value: Double)
    var mouseSpeed: Double { get }
    func setMouseSpeed(_ value: Double)
    var rightStickMouse: Bool { get }
    func setRightStickMouse(_ on: Bool)
    /// Physical controllers reach games.
    var controllers: Bool { get }
    func setControllers(_ on: Bool)
    var controllerAPI: String { get }
    var controllerAPIChoices: [BCDSettingsChoice] { get }
    func setControllerAPI(_ value: String)
    var controllerOutput: String { get }
    var controllerOutputChoices: [BCDSettingsChoice] { get }
    func setControllerOutput(_ value: String)
    /// What a controller presses in keyboard-and-mouse mode, out of the box.
    var keyboardMouseTemplate: [BCDSettingsBinding] { get }
    /// Keys and the mouse from the controller too, for every game (a fixed mapping).
    var controllerKeys: Bool { get }
    func setControllerKeys(_ on: Bool)
    /// A mouse or trackpad connected to this device.
    var mouseConnected: Bool { get }
    /// iPad: the pointer can be captured for a game (an iPhone has no pointer to capture).
    var pointerLockAvailable: Bool { get }
    var pointerLocked: Bool { get }
    /// Capturing works on the mouse's raw path only.
    var pointerLockUsable: Bool { get }
    func togglePointerLock()
    /// iPhone: a mouse is connected but nothing arrives from it (AssistiveTouch is off).
    var mouseNeedsAssistiveTouch: Bool { get }
    func dismissMouseHint()
    var restartNeeded: Bool { get }
}

extension BCDControlsBackend {
    var canShareLayouts: Bool { false }
    func shareLayout(_ id: String) {}
    func importLayoutFromFile() {}
}

struct BCDControlsSettings<Backend: BCDControlsBackend>: View {
    @ObservedObject var backend: Backend
    @EnvironmentObject private var model: BCDSettingsModel
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BCDSettingsGroup(title: "触摸控件",
                             footer: "For games without a choice of their own; a game in your library keeps its own on its page. Touch controls show with the device on its side.") {
                BCDSettingsToggleRow(id: id("touch"), title: "触摸控件", note: "绘制在游戏画面之上的按键与摇杆。",
                                     isOn: backend.touchControls) { backend.setTouchControls($0) }
                BCDSettingsValueRow(id: id("opacity"), title: "不透明度", choices: opacitySteps.map(percent),
                                    value: Self.snap(backend.opacity, opacitySteps)) { backend.setOpacity(Double($0) ?? 1) }
                if backend.layoutsShown {
                    BCDSettingsValueRow(id: id("layout"), title: "布局",
                                        note: backend.unsavedControls ? "What is on screen now is in no layout yet." : nil,
                                        choices: layoutChoices, value: backend.activeLayout ?? "", enabled: !backend.layouts.isEmpty) { chosen in
                        useLayout(chosen)
                    }
                    if backend.canSaveLayouts {
                        BCDSettingsActionRow(id: id("new-layout"), title: "新布局",
                                             note: "Starts \u{201C}\(backend.nextLayoutName)\u{201D} empty and opens the editor.", symbol: "plus") {
                            if backend.newLayout() { openEditor() }
                        }
                    }
                    if let active = backend.layouts.first(where: { $0.id == backend.activeLayout && !$0.builtIn }), backend.canSaveLayouts {
                        BCDSettingsActionRow(id: id("delete-layout"), title: "Delete \u{201C}\(active.name)\u{201D}", symbol: "trash",
                                             destructive: true) { confirmDelete(active) }
                    }
                    if backend.canShareLayouts {
                        if let active = backend.layouts.first(where: { $0.id == backend.activeLayout && !$0.builtIn }) {
                            BCDSettingsActionRow(id: id("share-layout"), title: "Share \u{201C}\(active.name)\u{201D}",
                                                 note: "保存为一个可发给朋友的小文件。", symbol: "square.and.arrow.up") { backend.shareLayout(active.id) }
                        }
                        if backend.canSaveLayouts {
                            BCDSettingsActionRow(id: id("import-layout"), title: "从文件添加布局",
                                                 note: "别人分享给你的布局，即「文件」中的 .json 文件。BCD 会先校验，再作为一个新布局加入；你原有的布局保持不变。",
                                                 symbol: "square.and.arrow.down") { backend.importLayoutFromFile() }
                        }
                    }
                }
                BCDSettingsActionRow(id: id("edit"), title: "编辑屏幕布局",
                                     note: "移动、缩放并映射控件。编辑时请把设备横过来。",
                                     symbol: "slider.horizontal.below.rectangle") { openEditor() }
            }
            BCDSettingsGroup(title: "指针", footer: pointerNote) {
                BCDSettingsValueRow(id: id("pointer"), title: "触摸如何移动指针",
                                    choices: BCDPointerMode.allCases.map { BCDSettingsChoice(value: $0.rawValue, label: $0.title) },
                                    value: backend.pointer.rawValue) { backend.setPointer(BCDPointerMode(rawValue: $0) ?? .absolute) }
                speedRow("touch-speed", "触摸速度", backend.touchSpeed) { backend.setTouchSpeed($0) }
                speedRow("look-speed", "鼠标视角速度", backend.lookSpeed) { backend.setLookSpeed($0) }
                speedRow("mouse-speed", "Mouse speed", backend.mouseSpeed, note: "连接到此设备的鼠标或触控板。") {
                    backend.setMouseSpeed($0)
                }
            }
            BCDSettingsGroup(title: "鼠标", footer: UIDevice.current.userInterfaceIdiom == .phone
                             ? "On an iPhone a mouse reaches apps only through AssistiveTouch: Settings › Accessibility › Touch › AssistiveTouch, then Devices."
                             : "A captured pointer is hidden and every movement goes to the game. Ctrl+Alt+P captures or frees it at any time.") {
                BCDSettingsInfoRow(title: "鼠标或触控板", value: backend.mouseConnected ? "已连接" : "无",
                                   valueColor: backend.mouseConnected ? BCDStyle.mint : BCDStyle.textSoft)
                if backend.mouseNeedsAssistiveTouch {
                    BCDSettingsActionRow(id: id("mouse-hint"), title: "鼠标尚无输入",
                                         note: "按下方说明开启「辅助触控」。选择此项可隐藏本行。",
                                         symbol: "xmark") { backend.dismissMouseHint() }
                }
                if backend.pointerLockAvailable {
                    BCDSettingsToggleRow(id: id("pointer-lock"), title: "捕获指针",
                                         note: backend.pointerLocked ? "Captured. Tap here or press Ctrl+Alt+P to free it."
                                             : backend.mouseConnected && !backend.pointerLockUsable
                                             ? "This mouse comes through the system's pointer, which capturing would stop."
                                             : "For mouse-look in games.",
                                         isOn: backend.pointerLocked,
                                         enabled: backend.mouseConnected && backend.pointerLockUsable) { _ in backend.togglePointerLock() }
                }
            }
            BCDSettingsGroup(title: "控制器") {
                BCDSettingsActionRow(id: id("controller-screen"), title: "控制器",
                                     note: "已连接的控制器、每个按键的检测，以及控制器作为键盘鼠标的用法。") {
                    model.showControllers()
                }
                BCDSettingsToggleRow(id: id("controllers"), title: "游戏中的控制器",
                                     note: "已配对的控制器会以 Xbox 手柄的身份呈现给游戏。",
                                     isOn: backend.controllers) { backend.setControllers($0) }
                BCDSettingsValueRow(id: id("controller-api"), title: "玩家 1 为",
                                    note: "「Xbox（XInput）」适合大多数游戏。「HID」会把玩家 1 呈现为 DualSense 或普通手柄，适合读取这类设备的游戏。",
                                    choices: backend.controllerAPIChoices.map { Self.words($0, Self.apiWords) }, value: backend.controllerAPI,
                                    enabled: backend.controllers) { backend.setControllerAPI($0) }
                BCDSettingsValueRow(id: id("controller-output"), title: "振动与灯光",
                                    note: "游戏可回传给控制器的内容：振动、DualSense 的扳机与灯条。",
                                    choices: backend.controllerOutputChoices.map { Self.words($0, Self.outputWords) }, value: backend.controllerOutput,
                                    enabled: backend.controllers) { backend.setControllerOutput($0) }
                BCDSettingsToggleRow(id: id("right-stick-mouse"), title: "右摇杆移动鼠标",
                                     note: "针对不读取控制器的游戏。",
                                     isOn: backend.rightStickMouse) { backend.setRightStickMouse($0) }
                BCDSettingsToggleRow(id: id("controller-keys"), title: "所有游戏中都可用控制器按键",
                                     note: "控制器同时也会敲击按键与鼠标：A 空格、B Esc、X E、Y R、摇杆 WASD 与方向键、扳机对应鼠标键。如果游戏本身读取控制器，每次按键会被识别两次，因此仅建议用于不支持控制器的游戏。",
                                     isOn: backend.controllerKeys) { backend.setControllerKeys($0) }
            }
            if backend.restartNeeded { BCDSettingsNotice(text: bcdSettingsRestartNote) }
            BCDSettingsGroup(title: "键盘鼠标模式",
                             footer: "A game without controller support can take the controller as keyboard and mouse: choose it on the game's page, where each button can also be changed for that game. Out of the box the buttons do this.") {
                let template = backend.keyboardMouseTemplate
                ForEach(0..<((template.count + 1) / 2), id: \.self) { line in
                    HStack(spacing: 0) {
                        binding(template[line * 2])
                        if line * 2 + 1 < template.count { binding(template[line * 2 + 1]) } else { Spacer().frame(maxWidth: .infinity) }
                    }
                }
            }
        }
        .fullScreenCover(isPresented: $editing) { editorCover }
        .onChange(of: editing) { _, open in model.cover(open ? { editing = false } : nil) }
    }

    private func id(_ name: String) -> String { BCDSettingsID.control(.controls, name) }

    /// Settings' own words for the engine's controller choices, by value (the engine's label
    /// stays for a value Settings does not know).
    private static var apiWords: [String: String] {
        ["": "Xbox controller (standard)", "hid": "HID: DualSense or plain pad", "dualsense": "Always a DualSense",
         "generic": "Always a plain gamepad"]
    }
    private static var outputWords: [String: String] {
        ["": "All of it (standard)", "hid": "DualSense effects only", "xinput": "Rumble only", "0": "Nothing"]
    }
    private static func words(_ choice: BCDSettingsChoice, _ table: [String: String]) -> BCDSettingsChoice {
        BCDSettingsChoice(value: choice.value, label: table[choice.value] ?? choice.label)
    }

    private func percent(_ value: Double) -> BCDSettingsChoice {
        BCDSettingsChoice(value: String(value), label: "\(Int((value * 100).rounded()))%")
    }

    /// The stored value as one of the choices, so the row shows the nearest step.
    private static func snap(_ value: Double, _ steps: [Double]) -> String {
        String(steps.min { abs($0 - value) < abs($1 - value) } ?? value)
    }

    private func speedRow(_ name: String, _ title: String, _ value: Double, note: String? = nil,
                          set: @escaping (Double) -> Void) -> some View {
        BCDSettingsValueRow(id: id(name), title: title, note: note,
                            choices: speedSteps.map { BCDSettingsChoice(value: String($0), label: String(format: "%g×", $0)) },
                            value: Self.snap(value, speedSteps)) { set(Double($0) ?? value) }
    }

    private var pointerNote: String {
        switch backend.pointer {
        case .absolute: return "Trackpad: drag to move the pointer, tap to click, hold then drag to drag, two fingers to scroll or right-click."
        case .touch: return "Touch: the pointer jumps to your finger and a tap clicks there; hold, then move, to drag."
        case .relative: return "Mouse-look: dragging turns the camera; click with on-screen buttons."
        }
    }

    private var layoutChoices: [BCDSettingsChoice] {
        var list = backend.layouts.map { BCDSettingsChoice(value: $0.id, label: $0.name) }
        if backend.activeLayout == nil || !list.contains(where: { $0.value == backend.activeLayout }) {
            list.insert(BCDSettingsChoice(value: backend.activeLayout ?? "", label: "未保存"), at: 0)
        }
        return list
    }

    private func binding(_ item: BCDSettingsBinding) -> some View {
        HStack(spacing: 8) {
            Text(item.input).font(BCDStyle.label(13)).foregroundStyle(BCDStyle.ground)
                .padding(.horizontal, 7).frame(minWidth: 30, minHeight: 22)
                .background(BCDStyle.text, in: Capsule())
            Text(item.action).font(BCDStyle.body(14)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func useLayout(_ id: String) {
        guard !id.isEmpty, id != backend.activeLayout else { return }
        guard backend.unsavedControls else { backend.useLayout(id, keepCurrentFirst: false); return }
        var choices: [BCDSettingsConfirm.Choice] = []
        if backend.canSaveLayouts {
            choices.append(.init(title: "Keep them as \u{201C}\(backend.nextLayoutName)\u{201D}") { backend.useLayout(id, keepCurrentFirst: true) })
        }
        choices.append(.init(title: "替换它们", destructive: true) { backend.useLayout(id, keepCurrentFirst: false) })
        model.ask(BCDSettingsConfirm(title: "保留屏幕上的控件？",
                                     message: "它们还不在任何布局中，切换会丢失。", choices: choices))
    }

    private func confirmDelete(_ layout: BCDControlLayout) {
        model.ask(BCDSettingsConfirm(title: "Delete \u{201C}\(layout.name)\u{201D}?", message: "布局将被删除；使用过它的游戏会保留各自的副本。",
                                     choices: [.init(title: "删除", destructive: true) { backend.deleteLayout(layout.id) }]))
    }

    private func openEditor() { editing = true }

    @ViewBuilder private var editorCover: some View {
        if let editor = backend.editor(close: { editing = false }) {
            editor
        } else {
            VStack(spacing: 16) {
                Text("布局编辑器会在 App 内打开。").font(BCDStyle.heading(18))
                Button("关闭") { editing = false }.buttonStyle(BCDOutlineButtonStyle()).frame(maxWidth: 240)
                    .bcdFocusable("settings.editor.close", cornerRadius: 25) { editing = false }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(BCDStyle.ground.ignoresSafeArea())
            .foregroundStyle(BCDStyle.text)
        }
    }
}

// MARK: - Storage

/// Something BCD keeps on the device besides the games: a cache, logs, a runtime.
struct BCDStorageItem: Identifiable, Hashable {
    var id: String
    /// The engine's own name, for an item Settings has no words of its own for.
    var name: String
    var bytes: Int64?
    var clearable: Bool
}

@MainActor protocol BCDStorageBackend: ObservableObject {
    var deviceFree: Int64? { get }
    var deviceTotal: Int64? { get }
    var items: [BCDStorageItem] { get }
    var measuring: Bool { get }
    func refresh()
    func clear(_ id: String)
    /// Saves: one zip of every Windows user's saves, and putting one back.
    var savesBusy: Bool { get }
    var savesMessage: String? { get }
    /// Makes the zip; `done` gets it for the share sheet (nil when it failed).
    func backupSaves(_ done: @escaping (URL?) -> Void)
    /// The zip was shared (or not): it goes.
    func discardBackup(_ url: URL)
    func restoreSaves(from url: URL)
    /// Every game found on drive C:, added to the library at once.
    var addingGames: Bool { get }
    var addGamesMessage: String? { get }
    func addEveryGame()
    /// Games kept on an SSD (USB-C): the folder chosen in Files appears as C:\External. Only the live backend has it.
    var supportsExternalGames: Bool { get }
    var externalGamesMessage: String? { get }
    var externalGamesFree: Int64? { get }
    /// The name of the folder chosen last, once one was (the Reconnect button); nil before.
    var externalGamesSavedFolder: String? { get }
    var canConnectExternalGames: Bool { get }
    func connectExternalGames(_ url: URL)
    /// The saved folder again, without the picker. `chooseAgain` runs when iOS no longer lets BCD open it.
    func reconnectExternalGames(chooseAgain: @escaping () -> Void)
    /// What the folder picker did ("已打开", "已回复", "failed: ...", "已关闭"), for the log.
    func noteExternalPicker(_ what: String)
    var prefixToolsView: AnyView? { get }
}

extension BCDStorageBackend {
    /// Round 604: copies, export, import and a fresh registry for the Windows prefix (BCDPrefixTools.swift); nil: the group is left out.
    var prefixToolsView: AnyView? { nil }
    var supportsExternalGames: Bool { false }
    var externalGamesMessage: String? { nil }
    var externalGamesFree: Int64? { nil }
    var externalGamesSavedFolder: String? { nil }
    var canConnectExternalGames: Bool { false }
    func connectExternalGames(_ url: URL) {}
    func reconnectExternalGames(chooseAgain: @escaping () -> Void) {}
    func noteExternalPicker(_ what: String) {}
}

struct BCDStorageSettings<Backend: BCDStorageBackend>: View {
    @ObservedObject var backend: Backend
    @EnvironmentObject private var store: BCDStore
    @EnvironmentObject private var model: BCDSettingsModel
    @Environment(\.bcdLayout) private var layout
    @State private var backup: BCDShareItems?
    @State private var choosingBackup = false
    @State private var choosingExternalGames = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            room
            if backend.supportsExternalGames { externalGames }
            BCDSettingsGroup(title: "游戏", footer: games.isEmpty ? nil : "Largest first.") {
                if games.isEmpty {
                    BCDSettingsInfoRow(title: "尚未安装任何游戏", value: "")
                }
                ForEach(games) { game in gameRow(game) }
                BCDSettingsActionRow(id: BCDSettingsID.control(.storage, "add-every-game"),
                                     title: backend.addingGames ? "Looking for games…" : "Add every game on drive C:",
                                     note: backend.addGamesMessage ?? "Looks through drive C: and adds each game's main program to your library.",
                                     symbol: "square.and.arrow.down.on.square", enabled: !backend.addingGames) { backend.addEveryGame() }
            }
            BCDSettingsGroup(title: "存档",
                             footer: "One zip of every Windows user's saves: their Documents, Saved Games and AppData folders, without caches. Keep it somewhere safe, in Files or iCloud Drive. Restoring puts its files back and overwrites saves of the same name.") {
                BCDSettingsActionRow(id: BCDSettingsID.control(.storage, "backup"),
                                     title: backend.savesBusy ? "Working…" : "Back up every save",
                                     note: backend.savesMessage, symbol: "externaldrive.badge.icloud", enabled: !backend.savesBusy) {
                    backend.backupSaves { url in if let url { backup = BCDShareItems(urls: [url]) } }
                }
                BCDSettingsActionRow(id: BCDSettingsID.control(.storage, "restore"), title: "从备份恢复",
                                     symbol: "arrow.uturn.backward.circle", enabled: !backend.savesBusy) { choosingBackup = true }
            }
            if let tools = backend.prefixToolsView { tools }   // round 604: BCDPrefixTools.swift
            BCDSettingsGroup(title: "共享文件",
                             footer: "What each takes on this device" + (backend.measuring ? ", measuring now." : ".")
                                + " Clearing never touches your games or their saves.") {
                ForEach(backend.items) { item in itemRow(item) }
            }
        }
        .onAppear { backend.refresh() }
        .sheet(item: $backup, onDismiss: { backup.map { $0.urls.forEach(backend.discardBackup) } }) {
            BCDShareSheet(items: $0.urls)
        }
        .fileImporter(isPresented: $choosingBackup, allowedContentTypes: [.zip]) { result in
            guard case .success(let url) = result else { return }
            model.ask(BCDSettingsConfirm(title: "Restore the saves in \(url.lastPathComponent)?",
                                         message: "C:\\users 中所有同名文件都会被替换。",
                                         choices: [.init(title: "恢复", destructive: true) { backend.restoreSaves(from: url) }]))
        }
    }

    private var room: some View {
        VStack(alignment: .leading, spacing: 10) {
            BCDEyebrow(text: "本设备")
            if let free = backend.deviceFree ?? store.system.freeDeviceBytes {
                let total = backend.deviceTotal ?? store.system.totalDeviceBytes
                HStack(alignment: .firstTextBaseline) {
                    Text("\(BCDFormat.bytes(free)) free").font(BCDStyle.heading(layout == .pad ? 22 : 19))
                    Spacer()
                    if let total { Text("of \(BCDFormat.bytes(total))").font(BCDStyle.body(14)).foregroundStyle(BCDStyle.textSoft) }
                }
                if let total, total > 0 { BCDProgressBar(fraction: 1 - Double(free) / Double(total)) }
            } else {
                Text("可用空间未知").font(BCDStyle.body(15)).foregroundStyle(BCDStyle.textSoft)
            }
            if let external = store.system.freeExternalBytes {
                Label("External drive: \(BCDFormat.bytes(external)) free", systemImage: "externaldrive.fill")
                    .font(BCDStyle.label(14)).foregroundStyle(BCDStyle.lavender)
            }
        }
        .bcdCard(padding: 16)
    }

    /// Settings > Storage > External SSD (thebcd69/bcd-games#12 by Pardoxum, with Reconnect). The folder picker is attached
    /// here, on the group, not on the page: the page already carries the saves backup's importer, and two importers
    /// on one view can displace each other.
    private var externalGames: some View {
        let saved = backend.externalGamesSavedFolder
        return BCDSettingsGroup(title: "外置固态硬盘",
                                footer: "Connect a USB-C SSD and choose its games folder in Files. Open Add a game → External to add its programs. Windows and existing saves stay on this device. Store downloads still install on this device. After you unplug the SSD or restart the phone, tap Reconnect; if iOS has forgotten the folder, BCD opens Files for you to choose it again. Quit games before changing the connection, and keep the SSD connected while playing.") {
            if let saved {
                BCDSettingsActionRow(id: BCDSettingsID.control(.storage, "external-reconnect"),
                                     title: "Reconnect \(saved)", note: backend.externalGamesMessage,
                                     symbol: "externaldrive.badge.checkmark", enabled: backend.canConnectExternalGames) {
                    backend.reconnectExternalGames {
                        backend.noteExternalPicker("已打开（重连后）")
                        choosingExternalGames = true
                    }
                }
            }
            BCDSettingsActionRow(id: BCDSettingsID.control(.storage, "external-games"),
                                 title: saved == nil ? "Choose an SSD folder" : "Choose another SSD folder",
                                 note: saved == nil ? backend.externalGamesMessage : nil, symbol: "externaldrive",
                                 enabled: backend.canConnectExternalGames) {
                backend.noteExternalPicker("已打开")
                choosingExternalGames = true
            }
            if let free = backend.externalGamesFree {
                BCDSettingsInfoRow(title: "外置存储可用空间", value: BCDFormat.bytes(free))
            }
        }
        .fileImporter(isPresented: $choosingExternalGames, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url):
                backend.noteExternalPicker("已回复")
                backend.connectExternalGames(url)
            case .failure(let error):
                backend.noteExternalPicker("failed: \(error.localizedDescription)")
            }
        }
        .onChange(of: choosingExternalGames) { _, open in if !open { backend.noteExternalPicker("已关闭") } }
    }

    private var games: [BCDGame] {
        store.games.filter { $0.state.isInstalled }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
    }

    private func gameRow(_ game: BCDGame) -> some View {
        let open = model.backends.openGame
        let place = game.place == .externalDrive ? "On the external drive" : "在本设备上"
        return BCDSettingsActionRow(id: BCDSettingsID.control(.storage, "game.\(game.id)"), title: game.title,
                                    note: game.store == .local ? place : "\(game.store.title) · \(place)",
                                    detail: game.size.map(BCDFormat.bytes) ?? "—",
                                    symbol: open == nil ? nil : "chevron.right") {
            open?(game)
        }
    }

    private func itemRow(_ item: BCDStorageItem) -> some View {
        let words = storageWords[item.id] ?? (BCDSettingsText.scrub(item.name), "")
        let size = item.bytes.map(BCDFormat.bytes) ?? "…"
        return Group {
            if item.clearable {
                BCDSettingsActionRow(id: BCDSettingsID.control(.storage, item.id), title: words.0, note: words.1,
                                     detail: size, symbol: "trash", enabled: (item.bytes ?? 0) > 0) {
                    model.ask(BCDSettingsConfirm(title: "Clear \(words.0.lowercased())?", message: words.1,
                                                 choices: [.init(title: "清除", destructive: true) { backend.clear(item.id) }]))
                }
            } else {
                BCDSettingsInfoRow(title: words.0, note: words.1, value: size)
            }
        }
    }
}

// MARK: - .NET Framework

enum BCDMonoState: Hashable {
    case missing
    case builtIn
    case installed(version: String)
    case downloading(Double)
    case installing(Double)
}

@MainActor protocol BCDDotNetBackend: ObservableObject {
    var state: BCDMonoState { get }
    var error: String? { get }
    /// The version BCD downloads, and its download and installed sizes.
    var version: String { get }
    var downloadBytes: Int64 { get }
    var installedBytes: Int64? { get }
    func install()
    func remove()
    func refresh()
}

struct BCDDotNetSettings<Backend: BCDDotNetBackend>: View {
    @ObservedObject var backend: Backend
    @EnvironmentObject private var model: BCDSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BCDSettingsGroup(title: "Wine Mono",
                             footer: "Games written for Microsoft's .NET Framework run on Wine Mono, the Wine project's open-source take on it. BCD downloads it from WineHQ: about \(BCDFormat.bytes(backend.downloadBytes)), about 130 MB once installed. Most games do not need it.") {
                BCDSettingsInfoRow(title: "在本设备上", value: stateText, valueColor: stateColor)
                switch backend.state {
                case .downloading(let fraction), .installing(let fraction):
                    BCDProgressBar(fraction: fraction).padding(.horizontal, 14).padding(.bottom, 14)
                case .missing:
                    BCDSettingsActionRow(id: BCDSettingsID.control(.dotnet, "download"),
                                         title: backend.error == nil ? "Download Wine Mono" : "重试",
                                         note: backend.error, detail: BCDFormat.bytes(backend.downloadBytes),
                                         symbol: "arrow.down.circle.fill") { backend.install() }
                case .installed:
                    BCDSettingsActionRow(id: BCDSettingsID.control(.dotnet, "remove"), title: "移除 Wine Mono",
                                         note: backend.error, detail: backend.installedBytes.map(BCDFormat.bytes),
                                         symbol: "trash", destructive: true) {
                        model.ask(BCDSettingsConfirm(title: "移除 Wine Mono？",
                                                     message: "基于 .NET 的游戏在重新下载之前无法启动。",
                                                     choices: [.init(title: "移除", destructive: true) { backend.remove() }]))
                    }
                case .builtIn:
                    EmptyView()
                }
            }
        }
        .onAppear { backend.refresh() }
    }

    private var stateText: String {
        switch backend.state {
        case .missing: return "Not downloaded"
        case .builtIn: return "Built into this copy"
        case .installed(let version): return "Version \(version)" + (backend.installedBytes.map { " · \(BCDFormat.bytes($0))" } ?? "")
        case .downloading(let f):
            let done = Int64(Double(backend.downloadBytes) * f)
            return "Downloading · \(BCDFormat.bytes(done)) of \(BCDFormat.bytes(backend.downloadBytes))"
        case .installing(let f): return "Installing · \(Int((f * 100).rounded()))%"
        }
    }

    private var stateColor: Color {
        switch backend.state {
        case .installed, .builtIn: return BCDStyle.mint
        case .downloading, .installing: return BCDStyle.lavender
        case .missing: return BCDStyle.textSoft
        }
    }
}

// MARK: - Visual C++ runtime

enum BCDVCRuntimeState: Hashable {
    case missing
    case downloading(received: Int64, expected: Int64)
    case installing(Double)
    case installed(version: String)
}

/// What the next game links: the copy this build carries, the downloaded one, or none.
enum BCDVCRuntimeSource: Hashable { case bundled, downloaded, none }

@MainActor protocol BCDVCRuntimeBackend: ObservableObject {
    var state: BCDVCRuntimeState { get }
    var source: BCDVCRuntimeSource { get }
    /// Why the last install or removal failed.
    var lastError: String? { get }
    /// Downloads from Microsoft, checks and installs (also a reinstall).
    func install()
    func cancel()
    func remove()
    func refresh()
}

/// Microsoft's Visual C++ runtime: what this device has, and getting it from Microsoft once
/// the person accepts Microsoft's licence (VCRuntime, VCRuntimeDownload.swift).
struct BCDVCRuntimeSettings<Backend: BCDVCRuntimeBackend>: View {
    @ObservedObject var backend: Backend
    @EnvironmentObject private var model: BCDSettingsModel
    @Environment(\.openURL) private var openURL
    static var licence: URL { URL(string: "https://visualstudio.microsoft.com/license-terms/vs2022-cruntime/")! }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BCDSettingsGroup(title: "Visual C++ 2015–2022，64 位",
                             footer: "Most Windows games are built with Microsoft's tools and need this runtime to start. BCD fetches it straight from Microsoft, about 25 MB, keeps only its DLLs exactly as Microsoft ships them, and runs nothing from the download.") {
                BCDSettingsInfoRow(title: "在本设备上", note: versionNote, value: sourceText,
                                   valueColor: backend.source == .none ? BCDStyle.textSoft : BCDStyle.mint)
                switch backend.state {
                case .downloading(let received, let expected):
                    progress(expected > 0 ? Double(received) / Double(expected) : 0,
                             expected > 0 ? "\(BCDFormat.bytes(received)) of \(BCDFormat.bytes(expected))" : "Starting the download…")
                    BCDSettingsActionRow(id: BCDSettingsID.control(.vcruntime, "取消"), title: "取消下载", symbol: "xmark") {
                        backend.cancel()
                    }
                case .installing(let fraction):
                    progress(fraction, "正在解包并校验文件…")
                case .missing, .installed:
                    if backend.source == .none {
                        BCDSettingsActionRow(id: BCDSettingsID.control(.vcruntime, "download"),
                                             title: backend.lastError == nil ? "Accept and download" : "重试",
                                             note: "下载即表示你接受 Microsoft 对该运行库的许可条款。",
                                             symbol: "arrow.down.circle.fill") { backend.install() }
                    }
                    if backend.source == .downloaded {
                        BCDSettingsActionRow(id: BCDSettingsID.control(.vcruntime, "reinstall"), title: "重新下载",
                                             note: "只有新副本通过全部校验后才会替换当前副本。",
                                             symbol: "arrow.clockwise") { backend.install() }
                    }
                    if case .installed = backend.state {
                        BCDSettingsActionRow(id: BCDSettingsID.control(.vcruntime, "remove"), title: "移除已下载的副本",
                                             symbol: "trash", destructive: true) {
                            model.ask(BCDSettingsConfirm(title: "移除已下载的运行库？",
                                                         message: backend.source == .bundled
                                                             ? "This build carries its own copy, which games keep using."
                                                             : "Games that need it will not start until it is downloaded again.",
                                                         choices: [.init(title: "移除", destructive: true) { backend.remove() }]))
                        }
                    }
                }
                if let error = backend.lastError {
                    Text(error).font(BCDStyle.body(13.5)).foregroundStyle(BCDStyle.alert)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                BCDSettingsActionRow(id: BCDSettingsID.control(.vcruntime, "licence"), title: "Microsoft 许可条款",
                                     symbol: "doc.text") { openURL(Self.licence) }
            }
        }
        .onAppear { backend.refresh() }
    }

    private var sourceText: String {
        switch backend.source {
        case .bundled: return "Included in this build"
        case .downloaded: return "Downloaded"
        case .none: return "Not installed"
        }
    }

    /// The downloaded copy's version (the copy this build carries has none to show).
    private var versionNote: String? {
        guard backend.source == .downloaded, case .installed(let version) = backend.state, !version.isEmpty else { return nil }
        return "Version \(version), from Microsoft."
    }

    private func progress(_ fraction: Double, _ line: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            BCDProgressBar(fraction: fraction)
            Text(line).font(BCDStyle.body(13.5)).foregroundStyle(BCDStyle.textSoft).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

/// Round 625 (the owner's item 26): Microsoft's 32-bit MFC (VCRuntime.x86), under the 64-bit runtime on the Visual C++ page. A 32-bit
/// game gets it only when its config says env.MADEIRA_MFC32 = 1 (auto-tune adds that after the start it fails; WineProcessBridge.m
/// madeira_mfc32), so a game that runs today without it is not touched.
struct BCDMFC32Settings<Backend: BCDVCRuntimeBackend>: View {
    @ObservedObject var backend: Backend
    @EnvironmentObject private var model: BCDSettingsModel

    var body: some View {
        BCDSettingsGroup(title: "MFC，32 位",
                         footer: "A few 32-bit games and their plug-ins need Microsoft's MFC (mfc140u.dll). BCD fetches Microsoft's 32-bit package, about 14 MB, keeps only its four MFC DLLs exactly as Microsoft ships them, and gives them to a game whose config says env.MADEIRA_MFC32 = 1 (auto-tune adds it after a start that fails for it).") {
            BCDSettingsInfoRow(title: "在本设备上", note: versionNote, value: backend.source == .none ? "Not installed" : "Downloaded",
                               valueColor: backend.source == .none ? BCDStyle.textSoft : BCDStyle.mint)
            switch backend.state {
            case .downloading(let received, let expected):
                progress(expected > 0 ? Double(received) / Double(expected) : 0,
                         expected > 0 ? "\(BCDFormat.bytes(received)) of \(BCDFormat.bytes(expected))" : "Starting the download…")
                BCDSettingsActionRow(id: BCDSettingsID.control(.vcruntime, "mfc32-cancel"), title: "取消下载", symbol: "xmark") {
                    backend.cancel()
                }
            case .installing(let fraction):
                progress(fraction, "正在解包并校验文件…")
            case .missing, .installed:
                if backend.source == .none {
                    BCDSettingsActionRow(id: BCDSettingsID.control(.vcruntime, "mfc32-download"),
                                         title: backend.lastError == nil ? "Accept and download" : "重试",
                                         note: "下载即表示你接受 Microsoft 对该运行库的许可条款（见上）。",
                                         symbol: "arrow.down.circle.fill") { backend.install() }
                } else {
                    BCDSettingsActionRow(id: BCDSettingsID.control(.vcruntime, "mfc32-reinstall"), title: "重新下载",
                                         note: "只有新副本通过全部校验后才会替换当前副本。",
                                         symbol: "arrow.clockwise") { backend.install() }
                }
                if case .installed = backend.state {
                    BCDSettingsActionRow(id: BCDSettingsID.control(.vcruntime, "mfc32-remove"), title: "移除 32 位 MFC",
                                         symbol: "trash", destructive: true) {
                        model.ask(BCDSettingsConfirm(title: "移除 32 位 MFC？",
                                                     message: "需要它的 32 位游戏在重新下载之前无法启动。",
                                                     choices: [.init(title: "移除", destructive: true) { backend.remove() }]))
                    }
                }
            }
            if let error = backend.lastError {
                Text(error).font(BCDStyle.body(13.5)).foregroundStyle(BCDStyle.alert)
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { backend.refresh() }
    }

    private var versionNote: String? {
        guard case .installed(let version) = backend.state, !version.isEmpty else { return nil }
        return "Version \(version), from Microsoft."
    }

    private func progress(_ fraction: Double, _ line: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            BCDProgressBar(fraction: fraction)
            Text(line).font(BCDStyle.body(13.5)).foregroundStyle(BCDStyle.textSoft).monospacedDigit()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

// MARK: - Logs

struct BCDLogFile: Identifiable, Hashable {
    var id: String            // its path
    var name: String          // its file name
    var date: Date
    var bytes: Int64
    var hasGame = true        // round 624 (agent N S6): a game's session is in it (LogUpload.hasGame); false: BCD's own start-up only
}

struct BCDSentLog: Identifiable, Hashable {
    var id: String { code }
    var code: String
    var name: String
    var date: Date
}

/// The diagnostics switches beside extended logging (each an engine option; the live
/// backend knows which).
enum BCDDiagnostic: String, CaseIterable, Identifiable {
    case deviceLoad, power, lean, sessionTools
    var id: String { rawValue }
    var title: String {
        switch self {
        case .deviceLoad: return "Device load in the log"
        case .power: return "Power readings"
        case .lean: return "Lean diagnostics"
        case .sessionTools: return "Tools in the in-game menu"
        }
    }
    var note: String {
        switch self {
        case .deviceLoad: return "Heat, Low Power Mode, battery and brightness every 10 seconds while a game runs."
        case .power: return "The GPU's and the device's power every 5 seconds."
        case .lean: return "Stops the samplers that pause a game's threads to look at them."
        case .sessionTools: return "Frame capture and GPU sync, for testing."
        }
    }
}

@MainActor protocol BCDLogsBackend: ObservableObject {
    /// Said before a log is sent (an install without the increased memory limit); nil: nothing.
    var sendLogAdvice: String? { get }
    /// The newest logs, newest first: only these can be sent.
    var recent: [BCDLogFile] { get }
    var sent: [BCDSentLog] { get }
    var sending: Bool { get }
    var sendStatus: String? { get }
    /// `comment`: the sender's words for the top of the log (BCDLogComment), empty for none.
    func send(_ log: BCDLogFile, comment: String)
    func copy(_ code: String)
    /// BCD's own logs, ready for the share sheet.
    func exportable() -> [URL]
    var extendedLogging: Bool { get }
    func setExtendedLogging(_ on: Bool)
    func diagnostic(_ item: BCDDiagnostic) -> Bool
    func setDiagnostic(_ item: BCDDiagnostic, _ on: Bool)
    var crashTuning: Bool { get }
    /// Whether auto-tune runs in this session: the switch applies from the next start.
    var crashTuningRunning: Bool { get }
    func setCrashTuning(_ on: Bool)
    var restartNeeded: Bool { get }
    func refresh()
    /// After a session that closed unexpectedly, BCD asks once whether to send its log (BCDSessionRecorderLive.swift).
    var asksAfterUnexpectedClose: Bool { get }
    func setAsksAfterUnexpectedClose(_ on: Bool)
    /// A screenshot from the in-game menu is also added to Photos (BCDScreenshotLive.swift).
    var screenshotsToPhotos: Bool { get }
    func setScreenshotsToPhotos(_ on: Bool)
    /// A line a second (frame rate, CPU, memory, heat) kept for the session and sent with its log (BCDPerfTraceLive.swift). Off unless turned on.
    var perfTrace: Bool { get }
    func setPerfTrace(_ on: Bool)
}

extension BCDLogsBackend {
    var sendLogAdvice: String? { nil }
    var asksAfterUnexpectedClose: Bool { true }
    func setAsksAfterUnexpectedClose(_ on: Bool) {}
    var screenshotsToPhotos: Bool { true }
    func setScreenshotsToPhotos(_ on: Bool) {}
    var perfTrace: Bool { false }
    func setPerfTrace(_ on: Bool) {}
}

struct BCDLogsSettings<Backend: BCDLogsBackend>: View {
    @ObservedObject var backend: Backend
    @EnvironmentObject private var model: BCDSettingsModel
    @State private var sharing: BCDShareItems?
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BCDSettingsGroup(title: "发送日志",
                             footer: "Choose a log to send it. On this device BCD first takes out folder paths, user names, e-mail and IP addresses, then compresses it and sends it; the compressed copy is deleted right after. You get a code: quote it when you report a problem.") {
                if backend.recent.isEmpty {
                    BCDSettingsInfoRow(title: "还没有日志", note: "游戏运行过后才会产生日志。", value: "")
                }
                ForEach(backend.recent) { log in
                    BCDSettingsActionRow(id: BCDSettingsID.control(.logs, "send.\(log.name)"), title: BCDSettingsText.logName(log.name),
                                         note: "\(BCDFormat.dateTime(log.date)) · \(BCDFormat.bytes(log.bytes))",
                                         symbol: "paperplane", enabled: !backend.sending) { confirmSend(log) }
                }
                if let status = backend.sendStatus {
                    Text(status).font(BCDStyle.label(14)).foregroundStyle(BCDStyle.lavender)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !backend.sent.isEmpty {
                BCDSettingsGroup(title: "已发送", footer: "Choose a code to copy it.") {
                    ForEach(backend.sent.prefix(5)) { item in
                        BCDSettingsActionRow(id: BCDSettingsID.control(.logs, "sent.\(item.code)"), title: item.code,
                                             note: "\(BCDSettingsText.logName(item.name)) · \(BCDFormat.dateTime(item.date))",
                                             detail: copied == item.code ? "Copied" : nil, symbol: "doc.on.doc") {
                            backend.copy(item.code)
                            copied = item.code
                        }
                    }
                }
            }
            BCDSettingsGroup(title: "导出") {
                BCDSettingsActionRow(id: BCDSettingsID.control(.logs, "export"), title: "导出 BCD 日志",
                                     note: "本次与上次运行的日志，可保存或分享。", symbol: "square.and.arrow.up") {
                    let urls = backend.exportable()
                    if !urls.isEmpty { sharing = BCDShareItems(urls: urls) }
                }
            }
            BCDSettingsGroup(title: "诊断") {
                BCDSettingsToggleRow(id: BCDSettingsID.control(.logs, "extended"), title: "详细日志",
                                     note: "在每个游戏的日志中记录更多细节。会略微降低游戏速度：仅在报告问题时开启。",
                                     isOn: backend.extendedLogging) { backend.setExtendedLogging($0) }
                BCDSettingsToggleRow(id: BCDSettingsID.control(.logs, "perftrace"), title: "性能追踪",
                                     note: "游戏运行时，BCD 每秒向一个小文件写入一行（帧率、最慢帧、CPU、剩余内存、发热），最长一小时。发送该游戏日志时追踪数据会一并带上，从而按时间定位掉速。关闭时不产生任何开销。",
                                     isOn: backend.perfTrace) { backend.setPerfTrace($0) }
                ForEach(BCDDiagnostic.allCases) { item in
                    BCDSettingsToggleRow(id: BCDSettingsID.control(.logs, item.rawValue), title: item.title, note: item.note,
                                         isOn: backend.diagnostic(item)) { backend.setDiagnostic(item, $0) }
                }
                BCDSettingsActionRow(id: BCDSettingsID.control(.logs, "more"), title: "更多日志选项",
                                     note: "「全部设置」中的所有日志开关。", symbol: "slider.horizontal.3") {
                    model.openAll("Debugging")
                }
            }
            BCDSettingsGroup(title: "崩溃后") {
                BCDSettingsToggleRow(id: BCDSettingsID.control(.logs, "autotune"), title: "自动调优",
                                     note: "On by default for every game (each game's page has its own switch). When a game crashes, freezes or is closed by iOS, BCD looks through its log afterwards and tries one known fix at its next start, and keeps it if the game gets further. Your own settings always win.",
                                     isOn: backend.crashTuning) { backend.setCrashTuning($0) }
                BCDSettingsToggleRow(id: BCDSettingsID.control(.logs, "crashprompt"), title: "询问意外关闭的会话",
                                     note: "当游戏运行时 BCD 被关闭（iOS 内存不足或崩溃），下次启动时 BCD 会询问一次是否发送该会话的日志。同一会话绝不会重复询问。",
                                     isOn: backend.asksAfterUnexpectedClose) { backend.setAsksAfterUnexpectedClose($0) }
            }
            BCDSettingsGroup(title: "截图",
                             footer: "Take one from a game's menu under Tools. They are kept in Files › BCD › Screenshots. When you send a log, you can send the screenshot taken during that session too: a small copy of it (about 100 KB) goes as it is, because BCD cannot take anything out of a picture the way it does from a log. The picture kept in Files stays full size.") {
                BCDSettingsToggleRow(id: BCDSettingsID.control(.logs, "shotphotos"), title: "同时存入「照片」",
                                     note: "BCD 只会新增图片，绝不读取你的照片。首次截图时 iOS 会请求权限。",
                                     isOn: backend.screenshotsToPhotos) { backend.setScreenshotsToPhotos($0) }
            }
            if backend.restartNeeded || backend.crashTuning != backend.crashTuningRunning {
                BCDSettingsNotice(text: bcdSettingsRestartNote)
            }
        }
        .sheet(item: $sharing) { BCDShareSheet(items: $0.urls) }
        .onAppear { backend.refresh() }
    }

    private func confirmSend(_ log: BCDLogFile) {
        // Round 624 (agent N S6): the newest log of a fresh start holds no game; the game played last is in another log: offer that one first.
        let items = backend.recent.map { BCDLogChoice.Item(name: $0.name, modified: $0.date, hasGame: $0.hasGame) }
        if !log.hasGame, items.first?.name == log.name, let i = BCDLogChoice.gameLogToOffer(items, now: Date()) {
            let game = backend.recent[i]
            model.ask(BCDSettingsConfirm(title: "Send \(BCDSettingsText.logName(log.name))?",
                                         message: "此日志只记录了 BCD 重新打开后的操作，其中没有运行游戏。你玩的游戏"
                                            + "is in \u{201C}\(BCDSettingsText.logName(game.name))\u{201D} (\(BCDFormat.dateTime(game.date)))."
                                            + (backend.sendLogAdvice.map { "\n\n" + $0 } ?? ""),
                                         choices: [.init(title: "Send \(BCDSettingsText.logName(game.name))") {
                                                       BCDLogComment.ask(for: URL(fileURLWithPath: game.id)) { backend.send(game, comment: $0) } },
                                                   .init(title: "仍要发送此日志") {
                                                       BCDLogComment.ask(for: URL(fileURLWithPath: log.id)) { backend.send(log, comment: $0) } }]))
            return
        }
        // An install without the increased memory limit: the setup is the usual cause, so say what fixes it
        // first (MemoryRights.swift, through the live backend); sending is still possible.
        model.ask(BCDSettingsConfirm(title: "Send \(BCDSettingsText.logName(log.name))?",
                                     message: "\(BCDFormat.bytes(log.bytes)), cleaned on this device before it leaves."
                                        + (backend.sendLogAdvice.map { "\n\n" + $0 } ?? ""),
                                     choices: [.init(title: "发送") { BCDLogComment.ask(for: URL(fileURLWithPath: log.id)) { backend.send(log, comment: $0) } }]))
    }
}

struct BCDShareItems: Identifiable {
    let id = UUID()
    var urls: [URL]
}

/// The system's share sheet.
struct BCDShareSheet: UIViewControllerRepresentable {
    let items: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

// MARK: - Updates

/// Updates: this copy's version, what GitHub names as the newest release, Check for updates and
/// Check automatically. The checker (BCDUpdates.swift) touches no engine, so the section uses it
/// straight away; it opens a release's page and never downloads anything itself.
struct BCDUpdatesSettings: View {
    @ObservedObject private var checker = BCDUpdateChecker.shared
    @Environment(\.bcdLayout) private var layout

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                BCDEyebrow(text: "此副本")
                Text("BCD \(checker.version) (\(checker.build))").font(BCDStyle.heading(layout == .pad ? 24 : 20)).monospacedDigit()
                status
                if checker.state == .updateAvailable, let latest = checker.latest {
                    Button { checker.openReleasePage() } label: {
                        Label("前往更新", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(BCDPrimaryButtonStyle())
                    .frame(maxWidth: 360)
                    .bcdSettingsControl(BCDSettingsID.control(.updates, "open"), token: latest.version, cornerRadius: 27) {
                        checker.openReleasePage()
                    }
                }
            }
            .bcdCard(padding: 18)
            BCDSettingsGroup(footer: "BCD asks GitHub which release is the newest. It never downloads or installs anything by itself: an update is yours to install.") {
                BCDSettingsActionRow(id: BCDSettingsID.control(.updates, "check"),
                                     title: checker.state == .checking ? "检查中…" : "Check for updates",
                                     symbol: "arrow.clockwise", enabled: checker.state != .checking) { checker.checkNow() }
                BCDSettingsToggleRow(id: BCDSettingsID.control(.updates, "auto"), title: "自动检查",
                                     note: "每次启动 BCD 时检查一次。有新版本时，主页会提示。",
                                     isOn: checker.autoCheck) { checker.autoCheck = $0 }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch checker.state {
        case .idle:
            Text("尚未检查。").font(BCDStyle.body(15)).foregroundStyle(BCDStyle.textSoft)
        case .checking:
            Text("检查中…").font(BCDStyle.body(15)).foregroundStyle(BCDStyle.lavender)
        case .upToDate:
            Label("你已是最新版 BCD。", systemImage: "checkmark.circle.fill")
                .font(BCDStyle.label(15)).foregroundStyle(BCDStyle.mint)
        case .updateAvailable:
            Label("BCD \(checker.latest?.version ?? "") is out.", systemImage: "sparkles")
                .font(BCDStyle.label(16)).foregroundStyle(BCDStyle.text)
        case .failed(let line):
            Text(line).font(BCDStyle.body(14)).foregroundStyle(BCDStyle.textSoft)
        }
    }
}

// MARK: - Developer

@MainActor protocol BCDDeveloperBackend: ObservableObject {
    /// Starts the Windows desktop, as a game starts (Settings has closed by then).
    func startDesktop()
    /// The end of this run's log, to read in place.
    func logTail() -> String
    func clearLog()
    /// The controller BCD sees, and what it reports right now (lines; empty without one).
    var controllerName: String? { get }
    var controllerInput: [String] { get }
}

/// Developer (About › Developer options): the Windows desktop, BCD's log read in place or
/// cleared, and a live check of the controller. The logging switches are under Logs.
struct BCDDeveloperSettings<Backend: BCDDeveloperBackend>: View {
    @ObservedObject var backend: Backend
    @EnvironmentObject private var model: BCDSettingsModel
    @Environment(\.bcdLayout) private var layout

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BCDSettingsGroup(title: "Windows") {
                BCDSettingsActionRow(id: BCDSettingsID.control(.developer, "desktop"), title: "启动 Windows 桌面",
                                     note: "资源管理器与 Windows 自带工具，全屏显示。你的游戏库也有此功能。",
                                     symbol: "desktopcomputer") { model.startDesktop() }
            }
            BCDSettingsGroup(title: "BCD 日志") {
                BCDSettingsActionRow(id: BCDSettingsID.control(.developer, "read-log"), title: "查看日志",
                                     note: "本次运行日志的最后几行。", symbol: "text.alignleft") {
                    model.read("BCD 日志", text: backend.logTail())
                }
                BCDSettingsActionRow(id: BCDSettingsID.control(.developer, "clear-log"), title: "清除日志",
                                     symbol: "trash", destructive: true) {
                    model.ask(BCDSettingsConfirm(title: "清除本次运行的日志？", message: "此前游戏的日志会保留。",
                                                 choices: [.init(title: "清除", destructive: true) { backend.clearLog() }]))
                }
                BCDSettingsActionRow(id: BCDSettingsID.control(.developer, "logs"), title: "发送、导出、日志开关",
                                     symbol: "doc.text") { model.go(to: .logs) }
            }
            BCDSettingsGroup(title: "控制器检测", footer: "Press a button or move a stick: the lines follow it.") {
                BCDSettingsInfoRow(title: backend.controllerName ?? "No controller connected", value: "")
                if !backend.controllerInput.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(backend.controllerInput, id: \.self) { line in
                            Text(line).font(.system(size: layout == .pad ? 14 : 12.5, design: .monospaced))
                                .foregroundStyle(BCDStyle.textSoft)
                        }
                    }
                    .padding(.horizontal, 14).padding(.vertical, 11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Sections still to come

/// A section another part of the interface builds: what it will hold, row by row.
struct BCDSettingsPlaceholder: View {
    let section: BCDSettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            BCDSettingsGroup(title: "即将到来", footer: footer) {
                ForEach(rows, id: \.0) { row in
                    BCDSettingsRowLabel(title: row.0, note: row.1) {
                        Text("更快响应").font(BCDStyle.label(12)).foregroundStyle(BCDStyle.lavender)
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .overlay(Capsule().strokeBorder(BCDStyle.stroke, lineWidth: 1))
                    }
                }
            }
        }
    }

    var rows: [(String, String)] {
        switch section {
        case .accounts:
            return [("Steam", "Sign in, switch account or sign out. Your Steam library and downloads use this account."),
                    ("Epic Games", "Sign in to list your Epic games and install them."),
                    ("GOG", "Sign in to list your GOG games and install them.")]
        case .jit:
            return [("How JIT turns on", "Built-in pairing, a pairing file made on a computer, or StikDebug."),
                    ("Pairing", "Pair this device again, or import a pairing file."),
                    ("LocalDevVPN", "Whether it is installed, and how to get it."),
                    ("JIT shortcut", "Lets Enable JIT connect the network by itself (iOS 27)."),
                    ("Enable JIT now", "Turns JIT on for the next game."),
                    ("Setup again", "Runs the first-start setup once more.")]
        case .dock:
            return [("Steam client files", "Download Valve's client files, check them, or start them over."),
                    ("Your Steam games", "The installed Steam games BCD Dock starts, and how each starts."),
                    ("离线游玩", "Whether Steam can start your games without a connection.")]
        default:
            return []
        }
    }

    private var footer: String {
        switch section {
        default: return "This section is being built."
        }
    }
}
