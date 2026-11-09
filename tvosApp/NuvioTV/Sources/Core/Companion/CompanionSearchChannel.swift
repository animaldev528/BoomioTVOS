//
//  CompanionSearchChannel.swift
//  NuvioTV
//
//  Boomio: what the phone's search + keyboard frames mean on the TV.
//
//  The phone drives a TV search in three frames (contract in
//  `bsc/services/phone-relay.js` and `bsc/public/companion/app.js`):
//
//    stealth_search    open the TV's search screen
//    keyboard_input    one chunk of typed text — APPEND, not replace; the phone
//                      clears its own box after each send
//    keyboard_submit   run the search for what has been typed
//
//  The tab and the two search view models live in the app shell
//  (`TVMainTabView`), which is SwiftUI state a socket callback cannot reach
//  directly. So the socket side accumulates the query here and announces it;
//  the shell observes and applies it. The channel owns the accumulation because
//  the phone's chunks are deltas and only one place may decide what "the typed
//  query" is — a view that missed a chunk would silently search for the wrong
//  thing.
//

import Foundation

extension Notification.Name {
    /// The phone asked for the TV's search screen. No payload.
    static let boomioCompanionSearchOpened = Notification.Name("boomio.companion.search.opened")
    /// `object` is the full query typed so far (a `String`).
    static let boomioCompanionSearchTyped = Notification.Name("boomio.companion.search.typed")
    /// `object` is the full query to run (a `String`).
    static let boomioCompanionSearchSubmitted = Notification.Name("boomio.companion.search.submitted")
}

@MainActor
final class CompanionSearchChannel {
    static let shared = CompanionSearchChannel()

    /// Everything the phone has typed for the search it opened.
    private(set) var query = ""

    private init() {}

    /// `stealth_search` starts a new query: the phone's box is empty too, and
    /// carrying the last search over would make the next `keyboard_submit`
    /// search for a mixture of two people's words.
    func open() {
        query = ""
        NotificationCenter.default.post(name: .boomioCompanionSearchOpened, object: nil)
    }

    /// `keyboard_input` — a delta. Empty chunks are dropped: the phone sends one
    /// on every submit of an empty box, and an empty append must not look like
    /// a reason to jump the user onto the search tab.
    func type(_ text: String) {
        guard !text.isEmpty else { return }
        query += text
        NotificationCenter.default.post(name: .boomioCompanionSearchTyped, object: query)
    }

    /// `keyboard_submit`.
    func submit() {
        guard !query.isEmpty else { return }
        NotificationCenter.default.post(name: .boomioCompanionSearchSubmitted, object: query)
    }
}
