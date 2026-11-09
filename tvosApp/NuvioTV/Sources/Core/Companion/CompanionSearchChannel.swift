//
//  CompanionSearchChannel.swift
//  NuvioTV
//
//  Boomio: what the phone's search + keyboard frames mean on the TV.
//
//  The phone drives a TV search in three frames (contract in
//  `bsc/services/phone-relay.js`):
//
//    stealth_search    open the TV's search screen
//    keyboard_input    the search field's FULL current text — a replacement,
//                      never a delta. Both phone clients send it this way: the
//                      native app sends its field wholesale so backspace and
//                      mid-edit stay unambiguous (and a dropped frame only
//                      means the next keystroke carries the newest text), and
//                      the web remote sends one chunk at submit. Appending
//                      would double every character.
//    keyboard_submit   run the search for what is in the field
//
//  The tab and the two search view models live in the app shell
//  (`TVMainTabView`), which is state a socket callback cannot reach directly.
//  So the socket side keeps the current text here and announces it; the shell
//  observes and applies it.
//

import Foundation

extension Notification.Name {
    /// The phone asked for the TV's search screen. No payload.
    static let boomioCompanionSearchOpened = Notification.Name("boomio.companion.search.opened")
    /// `object` is the search field's full text (a `String`; may be empty).
    static let boomioCompanionSearchTyped = Notification.Name("boomio.companion.search.typed")
    /// `object` is the full query to run (a `String`).
    static let boomioCompanionSearchSubmitted = Notification.Name("boomio.companion.search.submitted")
}

@MainActor
final class CompanionSearchChannel {
    static let shared = CompanionSearchChannel()

    /// The search field's text as the phone last reported it.
    private(set) var query = ""

    private init() {}

    /// `stealth_search` starts a new query: the phone's box is empty too, and
    /// carrying the last search over would make the next `keyboard_submit`
    /// search for a mixture of two people's words.
    func open() {
        query = ""
        NotificationCenter.default.post(name: .boomioCompanionSearchOpened, object: nil)
    }

    /// `keyboard_input` — the whole field, not a delta. An empty string is a
    /// real value (the user backspaced to nothing) and must clear the field,
    /// so it is applied rather than dropped.
    func replace(_ text: String) {
        query = text
        NotificationCenter.default.post(name: .boomioCompanionSearchTyped, object: query)
    }

    /// `keyboard_submit`. Nothing to run for an empty field.
    func submit() {
        guard !query.isEmpty else { return }
        NotificationCenter.default.post(name: .boomioCompanionSearchSubmitted, object: query)
    }
}
