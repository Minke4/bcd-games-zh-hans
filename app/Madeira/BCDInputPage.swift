// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// The sections round 604's input features add to a game's page (Options), as plain values built from the game's
// BCDInputProfile. They know nothing of the engine: BCDInputLive.swift hands them the profile and carries out a change.
// The preview app shows them on sample data.

enum BCDInputPage {
    /// The ids of the sections `groups` makes (the preview app opens them by name: -BCDTab game-<id>-<id>).
    static let groupIDs = ["turbo", "radial", "aim", "gestures", "pencil", "touchlook"]

    /// The sections, in the order Options lists them.
    static func groups(_ profile: BCDInputProfile) -> [BCDGameSettingGroup] {
        [turboGroup(profile), radialGroup(profile), aimGroup(profile), gestureGroup(profile), pencilGroup(profile), touchLookGroup(profile)]
    }

    // MARK: Things BCD can do (the radial menu's slots, the gestures' bindings)

    /// Every action, under its group's heading; built once and shared by every row that offers them.
    private static let actionChoices: [BCDGameChoice] = {
        var out: [BCDGameChoice] = []
        var group = ""
        for choice in BCDInputAction.choices {
            out.append(BCDGameChoice(value: choice.id, label: choice.title, group: choice.group == group ? nil : choice.group))
            group = choice.group
        }
        return out
    }()

    /// A row's choices: "" first (what it is without a line), then the actions.
    private static func actionList(first: BCDGameChoice, extra: [BCDGameChoice] = []) -> [BCDGameChoice] { [first] + extra + actionChoices }

    // MARK: Radial menu

    static func radialGroup(_ profile: BCDInputProfile) -> BCDGameSettingGroup {
        let radial = profile.radial
        var settings = [
            BCDGameSetting(id: "radial", title: "环形菜单", kind: .toggle, value: radial.isOn ? "1" : "0", defaultValue: "0",
                           note: "A small button at the edge of the screen. Put a finger on it and a ring of up to eight things opens round it: keys, Alt+Tab, a click, BCD's menu, a button of the controller. Slide to one and let go, or lift at once and tap one. Off until you turn it on; nothing is drawn while it is closed."),
        ]
        guard radial.isOn else {
            return BCDGameSettingGroup(id: "radial", title: "环形菜单", symbol: "circle.grid.cross", settings: settings, headline: "关闭")
        }
        settings.append(BCDGameSetting(id: "radial-place", title: "按钮的位置",
                                       kind: .choice(BCDRadialSettings.Place.allCases.map { BCDGameChoice(value: $0.rawValue, label: $0.title) }),
                                       value: radial.place.rawValue, defaultValue: ""))
        for n in 1...BCDRadialSettings.slotCount {
            let stored = profile.get(BCDInputLines.radial, "radial-\(n)") ?? ""
            let fallback = BCDRadialSettings.defaultSlots[n - 1]
            let list = actionList(first: BCDGameChoice(value: "", label: "默认：" + (fallback?.title ?? "empty")),
                                  extra: [BCDGameChoice(value: "none", label: "空")])
            settings.append(BCDGameSetting(id: "radial-\(n)", title: "Slot \(n)" + (n == 1 ? ", at the top" : ""), kind: .choice(list),
                                           value: stored, defaultValue: "",
                                           note: n == 1 ? "The slots go clockwise from the top." : nil))
        }
        return BCDGameSettingGroup(id: "radial", title: "环形菜单", symbol: "circle.grid.cross", settings: settings,
                                   headline: "On · \(radial.filled.count) slots · " + radial.place.title)
    }

    // MARK: Aim mode

    static func aimGroup(_ profile: BCDInputProfile) -> BCDGameSettingGroup {
        let aim = profile.aim
        func number(_ v: Double) -> String { String(format: "%g", v) }
        var settings = [
            BCDGameSetting(id: "aim-zone", title: "手指转动镜头",
                           kind: .choice(BCDAimSettings.Zone.allCases.map { BCDGameChoice(value: $0.rawValue, label: $0.title) }),
                           value: aim.zone.rawValue, defaultValue: "",
                           note: "针对第一/第三人称游戏：在该区域拖动手指即可转动视角，如同鼠标转动；手指在此处不移动指针。落在触摸控件上的手指不会触发它。默认关闭，需手动选择。"),
        ]
        if aim.isOn {
            settings += [
                BCDGameSetting(id: "aim-sens", title: "速度", kind: .choice(BCDAimSettings.sensitivityChoices.map { BCDGameChoice(value: number($0), label: number($0) + "×") }),
                               value: number(aim.sensitivity), defaultValue: "1",
                               note: "1× 表示手指每移动一个点对应两个鼠标计数。对画面的实际影响取决于游戏自身的鼠标灵敏度。"),
                BCDGameSetting(id: "aim-vertical", title: "上下与左右的对比",
                               kind: .choice(BCDAimSettings.verticalChoices.map { BCDGameChoice(value: String($0), label: "\($0) %") }),
                               value: String(aim.vertical), defaultValue: "100"),
                BCDGameSetting(id: "aim-invert", title: "反转上下", kind: .toggle, value: aim.invertY ? "1" : "0", defaultValue: "0"),
                BCDGameSetting(id: "aim-tap", title: "轻点即点击", kind: .toggle, value: aim.tapClicks ? "1" : "0", defaultValue: "0",
                               note: "在该区域轻点即点击鼠标左键（开火）。关闭后轻点不做任何操作；请在触摸控件上放一个开火按钮。"),
            ]
        }
        return BCDGameSettingGroup(id: "aim", title: "瞄准模式", symbol: "scope", settings: settings,
                                   headline: aim.isOn ? aim.zone.title + " · " + number(aim.sensitivity) + "×" : "关闭")
    }

    // MARK: Touch gestures

    static func gestureGroup(_ profile: BCDInputProfile) -> BCDGameSettingGroup {
        let map = profile.gestures
        let none = BCDGameChoice(value: "", label: "不操作（照常）")
        let settings = BCDGesture.allCases.enumerated().map { i, gesture in
            BCDGameSetting(id: gesture.line, title: gesture.title, kind: .choice(actionList(first: none)),
                           value: map.bindings[gesture]?.id ?? "", defaultValue: "",
                           note: i == 0 ? "Taps, swipes and pinches with several fingers, each running one thing: a key, Alt+Tab, a click, the wheel, BCD's menu, the key bar. They work wherever the game takes touches; with the touch controls on, a finger on a control is that control's. A game that also takes the first finger as a click may see it; the usual pointer setting decides." : nil,
                           heading: i == 0 ? "Fingers on the game" : nil)
        }
        return BCDGameSettingGroup(id: "gestures", title: "触摸手势", symbol: "hand.draw", settings: settings,
                                   headline: map.isOn ? "\(map.bindings.count) bound" : "无")
    }

    // MARK: Apple Pencil

    static func pencilGroup(_ profile: BCDInputProfile) -> BCDGameSettingGroup {
        let pencil = profile.pencil
        var settings = [
            BCDGameSetting(id: "pencil", title: "Apple Pencil 充当鼠标", kind: .toggle, value: pencil.isOn ? "1" : "0", defaultValue: "0",
                           note: "笔尖会把指针精确放到触点处，笔尖触玻璃即左键；在支持悬停的 iPad 上，悬停会移动指针而不点击。手指仍按指针设置的行为工作。默认关闭，需手动开启。"),
        ]
        if pencil.isOn {
            settings.append(BCDGameSetting(id: "pencil-tap", title: "Apple Pencil 捏一下或双击",
                                           kind: .choice(BCDPencilSettings.Tap.allCases.map { BCDGameChoice(value: $0.rawValue, label: $0.title) }),
                                           value: pencil.tap.rawValue, defaultValue: "",
                                           note: "Pencil Pro 的捏合与 Pencil 的双击。会在 Pencil 所在位置点击。"))
        }
        return BCDGameSettingGroup(id: "pencil", title: "Apple Pencil", symbol: "pencil.tip", settings: settings, headline: pencil.isOn ? "A mouse" : "关闭")
    }

    // MARK: Touch control look

    static func touchLookGroup(_ profile: BCDInputProfile) -> BCDGameSettingGroup {
        let look = profile.touchLook
        func choice<T: CaseIterable & RawRepresentable>(_ id: String, _ title: String, _ all: [T], _ current: T, _ name: (T) -> String,
                                                        note: String? = nil) -> BCDGameSetting where T.RawValue == String {
            BCDGameSetting(id: id, title: title, kind: .choice(all.map { BCDGameChoice(value: $0.rawValue, label: name($0)) }),
                           value: current.rawValue, defaultValue: "", note: note)
        }
        let settings = [
            choice("look-body", "Body colour", Array(BCDTouchLook.Body.allCases), look.body, { $0.title },
                   note: "绘制在游戏画面上的按键与摇杆颜色。对所有游戏统一生效；游戏内菜单会显示示例。"),
            choice("look-accent", "Colour when pressed", Array(BCDTouchLook.Accent.allCases), look.accent, { $0.title }),
            choice("look-press", "How a press shows", Array(BCDTouchLook.Press.allCases), look.press, { $0.title }),
            choice("look-icons", "符号", Array(BCDTouchLook.Icons.allCases), look.icons, { $0.title },
                   note: "作用在控制器布局的面键与肩键上：A B X Y 与 LB RB LT RT，或 PlayStation 符号与 L1 R1 L2 R2。游戏实际接收到的内容不会改变。"),
        ]
        return BCDGameSettingGroup(id: "touchlook", title: "控件外观", symbol: "paintpalette", settings: settings, headline: look.summary)
    }

    // MARK: Turbo and macros

    static func turboGroup(_ profile: BCDInputProfile) -> BCDGameSettingGroup {
        let turbo = profile.turbo, macros = profile.macros
        var settings: [BCDGameSetting] = []
        let turboNote = "While you hold the button, the game sees it pressed and let go again and again. It works on the controller the game sees: the on-screen one or a paired one. Off until you turn it on."
        for (i, input) in BCDPadInput.main.enumerated() {
            settings.append(BCDGameSetting(id: BCDInputLines.turboToggle + input.rawValue, title: "连发 " + input.title, kind: .toggle,
                                           value: turbo.pad.contains(input) ? "1" : "0", defaultValue: "0",
                                           note: i == 0 ? turboNote : nil, heading: i == 0 ? "Controller buttons" : nil))
        }
        settings.append(BCDGameSetting(id: BCDInputLines.turboToggle + BCDTurboSettings.mouseLeftName, title: "连发左键", kind: .toggle,
                                       value: turbo.mouseLeft ? "1" : "0", defaultValue: "0",
                                       note: "针对触摸控件：按住触摸控件上的鼠标键或按键会连发。按键用名称表示，如 space、e、f。",
                                       heading: "Touch controls' mouse and keys"))
        settings.append(BCDGameSetting(id: BCDInputLines.turboToggle + BCDTurboSettings.mouseRightName, title: "连发右键", kind: .toggle,
                                       value: turbo.mouseRight ? "1" : "0", defaultValue: "0"))
        settings.append(BCDGameSetting(id: "turbo-keys", title: "连发按键", kind: .text(prompt: "space, e, f"),
                                       value: BCDKeyNames.listText(turbo.keys), defaultValue: "",
                                       note: "最多八个按键，用逗号分隔：字母、数字、space、enter、tab、shift、ctrl、alt、方向键（up、down、left、right）、f1 至 f12。"))
        settings.append(BCDGameSetting(id: "turbo-rate", title: "每秒按压次数",
                                       kind: .choice(BCDTurboSettings.rateChoices.map { BCDGameChoice(value: String($0), label: String($0)) }),
                                       value: String(turbo.rate), defaultValue: String(BCDTurboSettings.defaultRate)))

        settings.append(macroHeading(profile))
        var shown = 0
        for n in 1...BCDMacroSettings.slots {
            let button = BCDPadInput.named(profile.get(BCDInputLines.turbo, "macro\(n)-button") ?? "")
            // A slot appears once the one before it has a button.
            if n > 1 && shown < n - 1 { break }
            shown = button == nil ? shown : n
            settings.append(BCDGameSetting(id: "macro\(n)-button", title: "Macro \(n) button",
                                           kind: .choice([BCDGameChoice(value: "", label: "关闭")] + BCDPadInput.main.map { BCDGameChoice(value: $0.rawValue, label: $0.title) }),
                                           value: button?.rawValue ?? "", defaultValue: ""))
            guard button != nil else { continue }
            let mode = profile.get(BCDInputLines.turbo, "macro\(n)-mode") ?? ""
            settings.append(BCDGameSetting(id: "macro\(n)-mode", title: "Macro \(n) plays",
                                           kind: .choice([BCDGameChoice(value: "", label: "每次按键触发一次"),
                                                          BCDGameChoice(value: "repeat", label: "按住时连续触发"),
                                                          BCDGameChoice(value: "hold", label: "按住不放，直到再次按下")]),
                                           value: BCDMacro.Mode(rawValue: mode)?.rawValue ?? "", defaultValue: ""))
            settings.append(BCDGameSetting(id: "macro\(n)-steps", title: "Macro \(n) steps", kind: .text(prompt: "a, a, lb+a, -, b"),
                                           value: profile.get(BCDInputLines.turbo, "macro\(n)-steps") ?? "", defaultValue: "",
                                           note: n == 1 ? "Presses in order, separated by commas: a, b, x, y, lb, rb, lt, rt, l3, r3, up, down, left, right, start, back. Join buttons that go together with +, like lb+a; a dash is a pause. Up to 12 steps." : nil))
        }
        settings.append(BCDGameSetting(id: "macro-step", title: "单步时长",
                                       kind: .choice(BCDMacroSettings.stepChoices.map { BCDGameChoice(value: String($0), label: "\($0) ms") }),
                                       value: String(macros.stepMillis), defaultValue: String(BCDMacroSettings.defaultStep),
                                       note: "宏的每个步骤按住多久，以及之后的停顿。"))
        return BCDGameSettingGroup(id: "turbo", title: "连发与宏", symbol: "bolt.fill", settings: settings,
                                   headline: turboHeadline(turbo, macros))
    }

    private static func macroHeading(_ profile: BCDInputProfile) -> BCDGameSetting {
        BCDGameSetting(id: "macro-info", title: "关于宏",
                       kind: .info, value: "A button of the controller plays a chain of presses instead of itself. The button is not sent to the game while its macro is set.",
                       heading: "Macros")
    }

    static func turboHeadline(_ turbo: BCDTurboSettings, _ macros: BCDMacroSettings) -> String {
        var parts: [String] = []
        let names = turbo.pad.map(\.title) + (turbo.mouseLeft ? ["left click"] : []) + (turbo.mouseRight ? ["right click"] : []) + turbo.keys.compactMap(BCDKeyNames.label)
        if !names.isEmpty { parts.append("连发 " + names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " +\(names.count - 3)" : "")) }
        if macros.isOn { parts.append("\(macros.macros.count) macro" + (macros.macros.count == 1 ? "" : "s")) }
        return parts.isEmpty ? "关闭" : parts.joined(separator: " · ")
    }
}
