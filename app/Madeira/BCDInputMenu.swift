// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// What round 604's input features add to the in-game menu's Controls tab, as plain values built from the running
// game's BCDInputProfile. Every row id starts with "in.": the rest of it is the game page's setting id, so one
// change goes to the same line whichever screen made it (BCDInputLines.write). BCDInputLive.swift answers the rows.

enum BCDInputMenu {
    static let prefix = "in."

    static func handles(_ row: String) -> Bool { row.hasPrefix(prefix) }

    /// The game page's setting id behind a row.
    static func setting(of row: String) -> String { String(row.dropFirst(prefix.count)) }

    static func sections(_ profile: BCDInputProfile, players: BCDPlayersSnapshot = BCDPlayersSnapshot()) -> [BCDMenuSection] {
        [playersSection(profile, players), turboSection(profile), radialSection(profile), aimSection(profile), gestureSection(profile), pencilSection(profile),
         touchLookSection(profile)]
    }

    // MARK: Radial menu, aim mode, gestures and the Pencil

    static func radialSection(_ profile: BCDInputProfile) -> BCDMenuSection {
        let radial = profile.radial
        var rows = [BCDMenuRow(id: "in.radial", title: "环形菜单", detail: "A button at the edge opens a ring of keys and actions round your thumb.", symbol: "circle.grid.cross", kind: .toggle(radial.isOn))]
        if radial.isOn {
            rows.append(BCDMenuRow(id: "in.radial-place", title: "按钮的位置",
                                   kind: .choice(BCDRadialSettings.Place.allCases.map { BCDChoice(id: $0.rawValue, title: $0.title) }, selected: radial.place.rawValue)))
            rows.append(BCDMenuRow(id: "in.radial.note", title: "槽位在游戏页面中设置：选项 › 环形菜单。", kind: .note(.soft)))
        }
        return BCDMenuSection(id: "radial", title: "环形菜单", rows: rows)
    }

    static func aimSection(_ profile: BCDInputProfile) -> BCDMenuSection {
        let aim = profile.aim
        func number(_ v: Double) -> String { String(format: "%g", v) }
        var rows = [BCDMenuRow(id: "in.aim-zone", title: "手指转动镜头",
                               detail: "For first- and third-person games. A finger on a touch control never turns it.",
                               kind: .choice(BCDAimSettings.Zone.allCases.map { BCDChoice(id: $0.rawValue, title: $0.title) }, selected: aim.zone.rawValue))]
        if aim.isOn {
            rows.append(BCDMenuRow(id: "in.aim-sens", title: "速度",
                                   kind: .choice(BCDAimSettings.sensitivityChoices.map { BCDChoice(id: number($0), title: number($0) + "×") }, selected: number(aim.sensitivity))))
            rows.append(BCDMenuRow(id: "in.aim-vertical", title: "上下与左右的对比",
                                   kind: .choice(BCDAimSettings.verticalChoices.map { BCDChoice(id: String($0), title: "\($0) %") }, selected: String(aim.vertical))))
            rows.append(BCDMenuRow(id: "in.aim-invert", title: "反转上下", kind: .toggle(aim.invertY)))
            rows.append(BCDMenuRow(id: "in.aim-tap", title: "轻点即点击", kind: .toggle(aim.tapClicks)))
        }
        return BCDMenuSection(id: "aim", title: "瞄准模式", rows: rows)
    }

    static func gestureSection(_ profile: BCDInputProfile) -> BCDMenuSection {
        let map = profile.gestures
        let text = map.isOn
            ? map.bindings.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.title): \($0.value.title)" }.joined(separator: "  ·  ")
            : "No gesture is bound. Taps, swipes and pinches with several fingers can each run a key or an action: Options › Touch gestures."
        return BCDMenuSection(id: "gestures", title: "触摸手势", rows: [BCDMenuRow(id: "in.gestures.note", title: text, kind: .note(.soft))])
    }

    static func pencilSection(_ profile: BCDInputProfile) -> BCDMenuSection {
        let pencil = profile.pencil
        var rows = [BCDMenuRow(id: "in.pencil", title: "Apple Pencil 充当鼠标",
                               detail: "Its tip puts the pointer exactly where it touches; a squeeze or a double tap clicks.", symbol: "pencil.tip", kind: .toggle(pencil.isOn))]
        if pencil.isOn {
            rows.append(BCDMenuRow(id: "in.pencil-tap", title: "捏一下或双击",
                                   kind: .choice(BCDPencilSettings.Tap.allCases.map { BCDChoice(id: $0.rawValue, title: $0.title) }, selected: pencil.tap.rawValue)))
        }
        return BCDMenuSection(id: "pencil", title: "Apple Pencil", rows: rows)
    }

    /// The page a `.page` row names, or nil.
    static func page(_ id: String, _ profile: BCDInputProfile, players: BCDPlayersSnapshot = BCDPlayersSnapshot()) -> BCDMenuPage? {
        switch id {
        case playersPage: return playersPageContent(profile, players)
        case turboPage: return turbo(profile)
        case lookPage: return lookPageContent(profile)
        default: return nil
        }
    }

    // MARK: Players

    static let playersPage = "in.players"
    static let assignRow = "in.players.assign."
    static let cancelRow = "in.players.cancel"
    static let resetRow = "in.players.reset"

    static func playersSection(_ profile: BCDInputProfile, _ players: BCDPlayersSnapshot) -> BCDMenuSection {
        let count = players.connected
        return BCDMenuSection(id: "players", title: "玩家", rows: [
            BCDMenuRow(id: playersPage, title: "玩家", detail: "Which controller is Player 1, 2, 3 or 4, how hard each rumbles, and which player the touch controls are.",
                       symbol: "person.2.fill", kind: .page(playersPage, value: count == 0 ? "No controller" : count == 1 ? "1 controller" : "\(count) controllers")),
        ])
    }

    static func playersPageContent(_ profile: BCDInputProfile, _ players: BCDPlayersSnapshot) -> BCDMenuPage {
        var sections: [BCDMenuSection] = []
        for row in players.rows {
            let listening = players.listening == row.slot
            let rows = [
                BCDMenuRow(id: assignRow + String(row.slot), title: row.title,
                           detail: listening ? "Press a button on the controller now." : (row.name ?? "No controller"),
                           symbol: listening ? "dot.radiowaves.left.and.right" : "gamecontroller", kind: .action(primary: listening)),
                BCDMenuRow(id: "in.p\(row.slot + 1)-rumble", title: "振动",
                           kind: .choice(BCDPlayerSettings.rumbleChoices.map { BCDChoice(id: String($0), title: BCDPlayerWords.rumble($0)) }, selected: String(row.rumble))),
            ]
            sections.append(BCDMenuSection(id: "players.\(row.slot)", rows: rows))
        }
        var last = [BCDMenuRow(id: "in.touch-player", title: "触摸控件以玩家身份",
                               kind: .choice((0..<BCDPlayerSlots.count).map { BCDChoice(id: String($0 + 1), title: "P\($0 + 1)") }, selected: String(players.touchSlot + 1)))]
        if players.listening != nil {
            last.insert(BCDMenuRow(id: cancelRow, title: "取消选择", kind: .action()), at: 0)
        }
        last.append(BCDMenuRow(id: resetRow, title: "恢复为先到先得", kind: .action()))
        last.append(BCDMenuRow(id: "in.players.note", title: "在你做出选择之前不会被记住。触摸控件默认作为玩家 1，除非你在此更改。", kind: .note(.soft)))
        sections.append(BCDMenuSection(id: "players.rest", rows: last))
        return BCDMenuPage(id: playersPage, title: "玩家", sections: sections)
    }

    // MARK: Touch control look

    static let lookCustom = "touchlook"
    static let lookPage = "in.look"

    /// One row on the Controls tab; the choices and a sample are on its page.
    static func touchLookSection(_ profile: BCDInputProfile) -> BCDMenuSection {
        BCDMenuSection(id: "touchlook", title: "控件外观", rows: [
            BCDMenuRow(id: lookPage, title: "颜色与符号", detail: "How the buttons and sticks over the game look and light up.",
                       symbol: "paintpalette", kind: .page(lookPage, value: profile.touchLook.summary)),
        ])
    }

    static func lookPageContent(_ profile: BCDInputProfile) -> BCDMenuPage {
        let look = profile.touchLook
        func chips<T: CaseIterable & RawRepresentable>(_ id: String, _ title: String, _ all: [T], _ current: T, _ name: (T) -> String) -> BCDMenuRow where T.RawValue == String {
            BCDMenuRow(id: "in." + id, title: title, kind: .choice(all.map { BCDChoice(id: $0.rawValue, title: name($0)) }, selected: current.rawValue))
        }
        return BCDMenuPage(id: lookPage, title: "控件外观", sections: [
            BCDMenuSection(id: "touchlook.sample", rows: [BCDMenuRow(id: "in.look-sample", title: "示例", kind: .custom(lookCustom))]),
            BCDMenuSection(id: "touchlook.choices", rows: [
                chips("look-body", "Body", Array(BCDTouchLook.Body.allCases), look.body) { $0.title },
                chips("look-accent", "Colour when pressed", Array(BCDTouchLook.Accent.allCases), look.accent) { $0.title },
                chips("look-press", "How a press shows", Array(BCDTouchLook.Press.allCases), look.press) { $0.title },
                chips("look-icons", "符号", Array(BCDTouchLook.Icons.allCases), look.icons) { $0.title },
                BCDMenuRow(id: "in.look-note", title: "对所有游戏统一生效。符号只改变按键上显示的内容，不改变游戏接收到的输入。「触摸控件」中选择的颜色只影响 Night 外壳的边框与标签；其他外壳各有自带颜色。", kind: .note(.soft)),
            ]),
        ])
    }

    // MARK: Turbo and macros

    static let turboPage = "in.turbo"

    static func turboSection(_ profile: BCDInputProfile) -> BCDMenuSection {
        let turbo = profile.turbo, macros = profile.macros
        var rows = [BCDMenuRow(id: turboPage, title: "连发按钮",
                               detail: "Hold a button and the game sees it pressed again and again.", symbol: "bolt.fill",
                               kind: .page(turboPage, value: BCDInputPage.turboHeadline(turbo, BCDMacroSettings())))]
        if macros.isOn {
            rows.append(BCDMenuRow(id: "in.macros.note", title: macros.macros.map { "\($0.trigger.title): " + BCDMacroSettings.stepsText($0.steps) }.joined(separator: "  ·  "),
                                   kind: .note(.soft)))
        }
        rows.append(BCDMenuRow(id: "in.macros.edit", title: "宏在游戏页面中设置：选项 › 连发与宏。", kind: .note(.soft)))
        return BCDMenuSection(id: "turbo", title: "连发与宏", rows: rows)
    }

    static func turbo(_ profile: BCDInputProfile) -> BCDMenuPage {
        let s = profile.turbo
        var rows: [BCDMenuRow] = [
            BCDMenuRow(id: "in.turbo-rate", title: "每秒按压次数",
                       kind: .choice(BCDTurboSettings.rateChoices.map { BCDChoice(id: String($0), title: String($0)) }, selected: String(s.rate))),
        ]
        for input in BCDPadInput.main {
            rows.append(BCDMenuRow(id: "in." + BCDInputLines.turboToggle + input.rawValue, title: input.title, kind: .toggle(s.pad.contains(input))))
        }
        rows.append(BCDMenuRow(id: "in." + BCDInputLines.turboToggle + BCDTurboSettings.mouseLeftName, title: "左键点击（触摸控件）", kind: .toggle(s.mouseLeft)))
        rows.append(BCDMenuRow(id: "in." + BCDInputLines.turboToggle + BCDTurboSettings.mouseRightName, title: "右键点击（触摸控件）", kind: .toggle(s.mouseRight)))
        return BCDMenuPage(id: turboPage, title: "连发按钮", sections: [BCDMenuSection(id: "turbo.buttons", rows: rows)])
    }
}
