//
//  MobileWhatsNewSheet.swift
//  TamioMobile
//
//  Presents the Apple-native What's New sheet with Tamio's app icon and
//  haptic confirmation.
//

import SwiftUI
import TamioDesign

struct MobileWhatsNewSheet: View {
    var release: WhatsNewRelease = WhatsNewCatalog.currentRelease()
    var showsCloseButton: Bool = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        WhatsNewSheet(
            release: release,
            showsCloseButton: showsCloseButton,
            onContinue: {
                HapticsPreference.impact()
                WhatsNewStore.markSeen(version: release.version)
                dismiss()
            }
        ) {
            Image("TamioLogo")
                .resizable()
                .scaledToFit()
        }
    }
}
