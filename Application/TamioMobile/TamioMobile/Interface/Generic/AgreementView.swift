//
//  AgreementView.swift
//  TamioMobile
//
//  Native Apple onboarding license agreement sheet.
//

import SwiftUI
import TamioModule

struct AgreementView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LicenseTextView(resource: "EULA")
                        .padding(16)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .padding(16)
            }
            .appleGroupedBackground()
            .navigationTitle("License Agreement")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    Divider()
                    Button {
                        UIBridge.requiresConfirmation(
                            message: String(localized: "Accept the license?"),
                            confirmTitle: String(localized: "Agree"),
                            destructive: false
                        ) { yes in
                            if yes {
                                TamioStore.shared.licenseAgreed = true
                                dismiss()
                            }
                        }
                    } label: {
                        Text("I Agree")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .appleProminentButton()
                    .controlSize(.large)
                    .padding(16)
                }
                .background(.bar)
            }
        }
    }
}
