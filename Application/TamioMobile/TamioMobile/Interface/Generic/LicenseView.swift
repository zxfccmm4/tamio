//
//  LicenseView.swift
//  TamioMobile
//
//  Created by Lakr Aream on 2022/3/4.
//

import SwiftUI
import TamioModule

struct LicenseView: View {
    var body: some View {
        ScrollView {
            LicenseTextView(resource: "LICENSE")
                .lineSpacing(3)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .padding(16)
        }
        .appleGroupedBackground()
        .navigationTitle("License")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A bundled text (EULA, LICENSE), read off the main thread: the read would
/// otherwise run synchronously inside `body`.
struct LicenseTextView: View {
    let resource: String
    @State private var text = ""

    var body: some View {
        Text(text)
            .textSelection(.enabled)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .task {
                guard text.isEmpty else { return }
                text = await Self.load(resource: resource)
            }
    }

    static func load(resource: String) async -> String {
        await Task.detached {
            guard let bundle = Bundle.main.url(forResource: resource, withExtension: nil),
                  let str = try? String(contentsOfFile: bundle.path)
            else {
                return String(localized: "Failed to load license info.")
            }
            return str
        }.value
    }
}

struct LicenseView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationStack {
            LicenseView()
        }
    }
}
