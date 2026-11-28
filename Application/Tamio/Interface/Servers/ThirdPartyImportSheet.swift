//
//  ThirdPartyImportSheet.swift
//  Tamio (macOS)
//
//  Imports saved SSH servers from Xshell (.xsh), WindTerm (.sessions),
//  FinalShell (JSON), Termius (JSON), and generic CSV files.
//

import AppKit
import SwiftUI
import TamioDesign
import TamioModule

struct ThirdPartyImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var store: TamioStore

    @State private var format: ThirdPartyImportFormat = .auto
    @State private var hosts: [ImportedHostRecord] = []
    @State private var selectedIDs: Set<UUID> = []
    @State private var warnings: [String] = []
    @State private var importedCount: Int?
    @State private var sourceSummary = ""

    private var selectedHosts: [ImportedHostRecord] {
        hosts.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Import from Other Clients")
                    .font(.rxSheetTitle)
                Spacer()
                Button { dismiss() } label: {
                    Label("Close", rx: "xmark")
                }
                .buttonStyle(.rx(.plain, iconOnly: true))
                .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, RX.Space.s5)
            .frame(height: 52)

            Hairline()

            VStack(alignment: .leading, spacing: RX.Space.s4) {
                HStack(spacing: RX.Space.s3) {
                    Picker("Format", selection: $format) {
                        ForEach(ThirdPartyImportFormat.allCases) { item in
                            Text(item.localizedTitle).tag(item)
                        }
                    }
                    .frame(width: 220)

                    Button("Choose Files or Folder…") { pickFiles() }
                        .buttonStyle(.rxPrimary)

                    if !sourceSummary.isEmpty {
                        Text(sourceSummary)
                            .font(.rxHelp)
                            .foregroundStyle(.rxInkSecondary)
                    }
                    Spacer()
                }

                if !warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(warnings.prefix(5), id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.rxHelp)
                                .foregroundStyle(.rxWarning)
                        }
                    }
                }

                if let importedCount {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.rxSuccess)
                        Text("Imported \(importedCount) server(s). Assign keys or passwords in Edit Server when needed.")
                            .font(.rxBody)
                    }
                    .padding(RX.Space.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.rxSurfaceSunken, in: RoundedRectangle(cornerRadius: 10))
                } else if hosts.isEmpty {
                    EmptyStateView(
                        "Choose an export file",
                        systemImage: "square.and.arrow.down",
                        message: "Supports Xshell (.xsh files or folders), WindTerm (.sessions), FinalShell (JSON), Termius (JSON), and CSV."
                    )
                    .frame(maxWidth: .infinity, minHeight: 220)
                } else {
                    HStack {
                        Text("\(selectedHosts.count) of \(hosts.count) selected")
                            .font(.rxHelp)
                            .foregroundStyle(.rxInkSecondary)
                        Spacer()
                        Button("Select All") { selectedIDs = Set(hosts.map(\.id)) }
                            .buttonStyle(.rx(.plain, size: .small))
                        Button("Select None") { selectedIDs = [] }
                            .buttonStyle(.rx(.plain, size: .small))
                    }

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(hosts) { item in
                                let existing = matchesExisting(item)
                                HStack(spacing: 10) {
                                    Toggle("", isOn: Binding(
                                        get: { selectedIDs.contains(item.id) },
                                        set: { on in
                                            if on { selectedIDs.insert(item.id) } else { selectedIDs.remove(item.id) }
                                        }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.checkbox)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(verbatim: item.name)
                                                .font(.rxBodyStrong)
                                            if !item.group.isEmpty {
                                                RXTag(item.group)
                                            }
                                            if existing {
                                                RXTag(String(localized: "Already saved"))
                                            }
                                        }
                                        Text(verbatim: "\(item.username)@\(item.address):\(item.port)")
                                            .font(.rxCode)
                                            .foregroundStyle(.rxInkSecondary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(Color.rxSurfaceSunken.opacity(0.65), in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .frame(minHeight: 220, maxHeight: 340)
                }
            }
            .padding(RX.Space.s5)

            Hairline()

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.rx)
                Button("Import \(selectedHosts.count)") { commitImport() }
                    .buttonStyle(.rxPrimary)
                    .disabled(selectedHosts.isEmpty)
            }
            .padding(.horizontal, RX.Space.s5)
            .frame(height: 54)
        }
        .frame(width: 620)
    }

    private func pickFiles() {
        Mac.openPanel(
            message: String(localized: "Choose exported server files or a folder of .xsh sessions"),
            prompt: String(localized: "Open"),
            directory: nil,
            canChooseFiles: true,
            canChooseDirectories: true,
            allowsMultipleSelection: true,
            canCreateDirectories: false,
            showsHiddenFiles: true
        ) { urls in
            guard !urls.isEmpty else { return }
            let result = ThirdPartyHostImporter.parse(urls: urls, format: format)
            hosts = result.hosts
            warnings = result.warnings
            importedCount = nil
            sourceSummary = urls.count == 1 ? urls[0].lastPathComponent : String(localized: "\(urls.count) items")
            selectedIDs = Set(result.hosts.filter { !matchesExisting($0) }.map(\.id))
        }
    }

    private func matchesExisting(_ item: ImportedHostRecord) -> Bool {
        store.machineGroup.machines.contains {
            $0.remoteAddress.caseInsensitiveCompare(item.address) == .orderedSame
                && (Int($0.remotePort) ?? 22) == item.port
                && $0.loginUsername(with: store.associatedIdentity(for: $0)) == item.username
        }
    }

    private func commitImport() {
        var count = 0
        for item in selectedHosts {
            store.machineGroup.insert(item.toMachine())
            count += 1
        }
        importedCount = count
        hosts = []
        selectedIDs = []
    }
}
