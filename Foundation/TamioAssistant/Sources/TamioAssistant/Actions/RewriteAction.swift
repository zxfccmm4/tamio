//
//  RewriteAction.swift
//  TamioAssistant
//
//  FlowDown-inspired one-tap message rewrite presets tailored for server
//  operations and engineering reports.
//

import Foundation

public nonisolated enum AssistantRewriteAction: String, CaseIterable, Identifiable, Hashable, Sendable {
    case summarize
    case moreDetails
    case drawTable
    case listKeyPoints
    case commandChecklist

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .summarize: String(localized: "Summarize")
        case .moreDetails: String(localized: "Add More Details")
        case .drawTable: String(localized: "Organize as Table")
        case .listKeyPoints: String(localized: "List Key Points")
        case .commandChecklist: String(localized: "Extract Command Checklist")
        }
    }

    public var systemImage: String {
        switch self {
        case .summarize: "text.quote"
        case .moreDetails: "plus.square"
        case .drawTable: "tablecells"
        case .listKeyPoints: "list.bullet"
        case .commandChecklist: "terminal"
        }
    }

    public var prompt: String {
        switch self {
        case .summarize:
            "Rewrite the content into a crisp, executive summary preserving all server names, key findings, metrics, and risks. Match the original language."
        case .moreDetails:
            "Expand the content with clearer explanations, context, and actionable troubleshooting details without inventing unverified server outputs. Match the original language."
        case .drawTable:
            "Reorganize the content into clean Markdown table(s) with clear columns and rows for easy scanning across servers. Match the original language."
        case .listKeyPoints:
            "Distill the content into concise bullet points ordered by priority (Critical -> Warning -> Next Steps). Match the original language."
        case .commandChecklist:
            "Extract every actionable step into a numbered runbook with fenced ```sh code blocks ready to verify or run, keeping safety warnings intact. Match the original language."
        }
    }
}
