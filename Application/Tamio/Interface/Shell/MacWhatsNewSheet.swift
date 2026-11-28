//
//  MacWhatsNewSheet.swift
//  Tamio (macOS)
//
//  Presents the Apple-native What's New sheet using the macOS app icon.
//

import AppKit
import SwiftUI
import TamioDesign

struct MacWhatsNewSheet: View {
    var release: WhatsNewRelease = WhatsNewCatalog.currentRelease()
    var showsCloseButton: Bool = false

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        WhatsNewSheet(
            release: release,
            showsCloseButton: showsCloseButton,
            onContinue: {
                WhatsNewStore.markSeen(version: release.version)
                dismiss()
            }
        ) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
        }
    }
}
