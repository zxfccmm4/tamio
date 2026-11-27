//
//  TamioSessionAttributes.swift
//  TamioMobile & TamioMobileWidgets
//
//  Shared ActivityKit attributes for Dynamic Island and Lock Screen session
//  status.
//

import ActivityKit
import Foundation

struct TamioSessionAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var activeCount: Int
        var primaryHost: String
        var countryFlag: String
        var endpoint: String
        var detail: String
        var primarySessionID: String
        var isGhostRemote: Bool
        var cpuPercent: Int?
        var memPercent: Int?
    }

    var startedAt: Date
}
