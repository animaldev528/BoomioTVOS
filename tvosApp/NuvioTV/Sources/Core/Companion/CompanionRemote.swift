//
//  CompanionRemote.swift
//  NuvioTV
//
//  Boomio: the one seam between the companion socket and the running UI.
//
//  Transport commands land directly on the active `PlayerViewModel` through
//  `CompanionPlayerRegistry`, so they need nothing here. The rest cannot be
//  expressed that way:
//
//   - BACK has to unwind whatever screen is in front, and only the player
//     scene knows how to close its own panels before leaving.
//   - `stealth_search` / `keyboard_input` / `keyboard_submit` belong to the
//     search screen, which owns its view model and its focus.
//
//  tvOS gives an app no way to synthesise a remote key press into the focus
//  engine (the Android client's `dispatchKeyEvent` seam), so the phone's D-pad
//  is applied by the surfaces themselves — the player maps it onto transport,
//  and the root view uses it to leave an overlay. These notifications are how
//  a frame that arrives on a socket becomes an action on the right screen.
//

import Foundation

extension Notification.Name {
    /// Phone D-pad BACK. The player handles it like the Siri remote's Menu
    /// button while it is mounted; the root view closes an overlay or returns
    /// to Home otherwise. Narrower than `showSearch()`.
    static let companionBackPressed = Notification.Name("com.nuvio.tv.boomio.companion.back")
    /// `stealth_search`: open the TV's search screen.
    static let companionSearchRequested = Notification.Name("com.nuvio.tv.boomio.companion.search.open")
    /// `keyboard_input`: whole-query replacement, carried in `userInfo["text"]`.
    static let companionSearchText = Notification.Name("com.nuvio.tv.boomio.companion.search.text")
    /// `keyboard_submit`: run the query the field currently holds.
    static let companionSearchSubmitted = Notification.Name("com.nuvio.tv.boomio.companion.search.submit")
}

enum CompanionRemote {
    /// Key `userInfo` carries a `keyboard_input` replacement under.
    static let searchTextKey = "text"

    static func post(_ name: Notification.Name, text: String? = nil) {
        NotificationCenter.default.post(
            name: name,
            object: nil,
            userInfo: text.map { [searchTextKey: $0] }
        )
    }
}
