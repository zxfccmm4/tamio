//
//  TamioSessionAttributes.swift
//  TamioMobile & TamioMobileWidgets
//
//  Shared ActivityKit attributes for Dynamic Island and Lock Screen session
//  status (inspired by iGhostVT's TerminalSessionAttributes).
//

import ActivityKit
import Foundation

struct TamioSessionAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var activeCount: Int
        var primaryHost: String
        var detail: String
        var primarySessionID: String
        var isGhostRemote: Bool
    }

    var startedAt: Date
}
