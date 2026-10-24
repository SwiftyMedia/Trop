//
//  SectionLabel.swift
//  Trop
//
//  Created by 686udjie on 28/08/2026.
//

import SwiftUI

struct SectionLabel: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(LocalizedStringKey(title), systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .padding(.leading, 4)
            .padding(.bottom, 4)
    }
}
