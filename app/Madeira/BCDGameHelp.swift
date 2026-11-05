// SPDX-License-Identifier: GPL-3.0-only
// Copyright 2026 thebcd69 (BCD)
// BCD Material: additional terms under GPL-3.0 section 7 apply; see LICENSE-BCD.md.

import Foundation

// "此游戏的帮助" on a game's page (round 604): the section of Options in BCD's words. No views and no engine types, like
// the save backups section: the live backend (BCDGamePageLiveHelp.swift) fills the state in, the page's own lists draw the section from the
// settings below, and the preview app can build it from sample state.
//
// Three things: a debug run (say what goes wrong and what you will do; BCD starts the game with more detail recorded and offers to send the
// log with your notes afterwards), "运行得怎么样？" (a result, what went wrong and a few words go to BCD through the Feedback intake, after
// the whole message is shown), and the launch check (what the game's programs want that this device does not have yet).

/// What the section shows, filled in by the live backend.
struct BCDHelpState: Equatable {
    /// nil: the player did not say.
    var problem: BCDHelpProblem?
    var steps = ""
    var feedback = BCDGameFeedbackDraft()
    /// The message "Send feedback" would send, as the intake sees it; nil until a result is chosen.
    var message: String?
    /// What the last feedback did ("Sent. Your code: K7Q2MX", a reason, "Sending…").
    var status: String?
    var sending = false
    /// The game has a log from an earlier session (the feedback may send it, and carries its numbers).
    var hasLog = false
    /// The launch check's note, or nil when nothing is missing (or the check has not finished).
    var readiness: String?
    var readinessChecked = false
}

enum BCDGameHelp {
    static let groupID = "help"
    static let problem = "help.problem"
    static let steps = "help.steps"
    static let start = "help.start"
    static let result = "help.fb.result"
    static let issuePrefix = "help.fb.issue."
    static let words = "help.fb.words"
    static let numbers = "help.fb.numbers"
    static let attach = "help.fb.log"
    static let send = "help.fb.send"
    static let status = "help.fb.status"
    static let ready = "help.ready"

    static func issueID(_ issue: BCDFeedbackIssue) -> String { issuePrefix + issue.rawValue }
    static func issue(ofID id: String) -> BCDFeedbackIssue? { id.hasPrefix(issuePrefix) ? BCDFeedbackIssue(rawValue: String(id.dropFirst(issuePrefix.count))) : nil }

    static let startQuestion = BCDGameQuestion(
        title: "开始调试运行？",
        message: "BCD turns on the detailed log and the performance trace for this one run and starts the game. When you come back, it asks whether to send the log with your notes; nothing is sent unless you choose Send. A run slows the game a little. Both are off again afterwards.",
        confirm: "Start the game", destructive: false)

    static func headline(_ s: BCDHelpState) -> String {
        if let ready = s.readiness, !ready.isEmpty { return "Something is missing" }
        if s.status?.hasPrefix("已发送") == true { return "Feedback sent" }
        return "Debug run, feedback"
    }

    static func group(_ s: BCDHelpState) -> BCDGameSettingGroup {
        var rows: [BCDGameSetting] = []

        rows.append(BCDGameSetting(
            id: ready, title: "启动检查", kind: .info,
            value: !s.readinessChecked ? "Looking…" : s.readiness == nil ? "Nothing missing" : "See below",
            note: s.readiness ?? "BCD reads which Windows files the game's programs ask for and tells you here, and above Play, when this device does not have one yet. It changes nothing.",
            heading: "Before you play"))

        rows.append(BCDGameSetting(
            id: problem, title: "出现了什么问题",
            kind: .choice([BCDGameChoice(value: "", label: "未说明")] + BCDHelpProblem.allCases.map { BCDGameChoice(value: $0.rawValue, label: $0.title) }),
            value: s.problem?.rawValue ?? "", defaultValue: "",
            note: "调试运行会比对平常更详细地记录游戏启动过程。",
            heading: "Debug run"))
        rows.append(BCDGameSetting(
            id: steps, title: "你将要做的事", kind: .text(prompt: "例如：打开商店，然后按购买"), value: s.steps,
            note: "可选。若选择发送，这段文字会随日志一起发出。请勿填写个人信息。"))
        rows.append(BCDGameSetting(
            id: start, title: "开始调试运行", kind: .action,
            note: "立即启动游戏。之后 BCD 会询问是否发送其日志，附带你的备注与性能追踪数据（每秒一行）。",
            question: startQuestion))

        rows.append(BCDGameSetting(
            id: result, title: "运行得怎么样？",
            kind: .choice([BCDGameChoice(value: "", label: "未选择")] + BCDFeedbackResult.allCases.map { BCDGameChoice(value: $0.rawValue, label: $0.title) }),
            value: s.feedback.result?.rawValue ?? "", defaultValue: "",
            note: "告诉 BCD 此游戏在本设备上的运行情况，有助于判断需要修复什么。",
            heading: "Tell BCD how it ran"))
        for issue in BCDFeedbackIssue.allCases {
            rows.append(BCDGameSetting(id: issueID(issue), title: issue.title, kind: .toggle,
                                       value: s.feedback.issues.contains(issue) ? "1" : "0", defaultValue: "0"))
        }
        rows.append(BCDGameSetting(id: words, title: "用你自己的话描述", kind: .text(prompt: "可选：发生了什么、在何处"), value: s.feedback.words))
        rows.append(BCDGameSetting(
            id: numbers, title: "包含上次会话的数据", kind: .toggle, value: s.feedback.includeNumbers ? "1" : "0", defaultValue: "1",
            note: s.hasLog ? "Frame rate, play time and graphics API from the summary at the end of this game's last log. No names or paths."
                           : "This game has no log yet, so there are no numbers to include."))
        rows.append(BCDGameSetting(
            id: attach, title: "同时发送游戏上次的日志", kind: .toggle, value: s.feedback.attachLog ? "1" : "0", defaultValue: "0",
            note: "日志会先在本设备上脱敏处理，与「发送日志」相同。其代码会随消息一起发出。", locked: s.hasLog ? nil : "This game has no log yet."))
        var sendRow = BCDGameSetting(
            id: send, title: s.sending ? "Sending…" : "Send feedback", kind: .action,
            note: "发送前你可以看到完整内容。会附带 BCD 版本、iOS 版本与设备型号；不含姓名或账号。",
            locked: s.sending ? "Sending…" : s.feedback.result == nil ? "Choose how it ran first." : nil)
        if let message = s.message {
            sendRow.question = BCDGameQuestion(title: "发送此反馈？",
                                               message: BCDGameFeedbackCore.confirmation(message: message, attachLog: s.feedback.attachLog && s.hasLog),
                                               confirm: "发送", destructive: false)
        }
        rows.append(sendRow)
        if let status = s.status, !status.isEmpty {
            rows.append(BCDGameSetting(id: self.status, title: "上次反馈", kind: .info, value: "", note: status))
        }

        return BCDGameSettingGroup(id: groupID, title: "此游戏的帮助", symbol: "lifepreserver", settings: rows, headline: headline(s))
    }
}
