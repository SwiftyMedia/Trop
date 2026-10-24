//
//  EqualizerView.swift
//  Trop
//
//  Created by 686udjie on 20/08/2026.
//

import SwiftUI

/// A Spotify-style equalizer: a line graph across 10 band frequencies whose
/// points can be dragged up/down (±12 dB), plus a horizontal preset strip.
struct EqualizerView: View {
    @Environment(\.settingsStore) private var settings
    @State private var dragIndex: Int?

    var body: some View {
        @Bindable var settings = settings

        ScrollView {
            VStack(spacing: 24) {
                equalizerCard(settings: settings)
                    .padding(.horizontal, 20)

                presetStrip(settings: settings)
            }
            .padding(.top, 20)
        }
        .navigationTitle("Equalizer")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Graph

    private func equalizerCard(settings: SettingsStore) -> some View {
        @Bindable var settings = settings
        return VStack(spacing: 12) {
            HStack {
                Text(LocalizedStringKey(settings.equalizerEnabled ? "Equalizer On" : "Equalizer Off"))
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Toggle("", isOn: $settings.equalizerEnabled)
                    .labelsHidden()
            }

            EqualizerGraph(
                gains: $settings.equalizerGains,
                accentColor: settings.accentColor,
                activeDrag: $dragIndex
            )
            .frame(height: 260)

            HStack {
                Text("\(Int(equalizerMinGain)) dB")
                Spacer()
                Text("0 dB")
                Spacer()
                Text("+\(Int(equalizerMaxGain)) dB")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .onChange(of: settings.equalizerEnabled) { _, enabled in
            _ = enabled
            PlayerController.shared.applyPlaybackSettings()
        }
    }

    // MARK: - Presets

    private func presetStrip(settings: SettingsStore) -> some View {
        @Bindable var settings = settings
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(EqualizerPresets.all, id: \.id) { preset in
                    let isSelected = settings.equalizerPresetID == preset.id
                    Button {
                        settings.equalizerGains = preset.gains
                        settings.equalizerPresetID = preset.id
                        PlayerController.shared.applyPlaybackSettings()
                    } label: {
                        Text(LocalizedStringKey(preset.name))
                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                Capsule().fill(isSelected ? settings.accentColor : Color(.secondarySystemGroupedBackground))
                            )
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

/// The interactive band graph. Each point sits at a fixed x (band index) and
/// a y derived from its dB gain; dragging a point updates that band and flags
/// the preset as custom.
private struct EqualizerGraph: View {
    @Binding var gains: [Double]
    let accentColor: Color
    @Binding var activeDrag: Int?

    private let horizontalInset: CGFloat = 14
    private let verticalInset: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let drawWidth = size.width - horizontalInset * 2
            let drawHeight = size.height - verticalInset * 2
            let points = gains.enumerated().map { index, gain -> CGPoint in
                let x = horizontalInset + drawWidth * CGFloat(index) / CGFloat(max(1, gains.count - 1))
                let normalized = (gain - equalizerMinGain) / (equalizerMaxGain - equalizerMinGain)
                let y = verticalInset + drawHeight * CGFloat(1 - normalized)
                return CGPoint(x: x, y: y)
            }

            ZStack {
                graphGrid(size: size)

                if points.count >= 2 {
                    linePath(points)
                        .stroke(
                            LinearGradient(
                                colors: [accentColor, accentColor.opacity(0.4)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round)
                        )
                }

                if points.count >= 2 {
                    fillPath(points)
                        .fill(
                            LinearGradient(
                                colors: [accentColor.opacity(0.18), accentColor.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                }

                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    Circle()
                        .fill(.white)
                        .frame(width: 14, height: 14)
                        .overlay(Circle().stroke(accentColor, lineWidth: 2))
                        .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                        .position(point)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = bandIndex(for: value.location, size: size)
                        let gain = gain(for: value.location, size: size)
                        activeDrag = index
                        setGain(gain, at: index)
                    }
                    .onEnded { _ in
                        activeDrag = nil
                    }
            )
        }
    }

    // MARK: - Drawing helpers

    private func graphGrid(size: CGSize) -> some View {
        Canvas { context, _ in
            let drawWidth = size.width - horizontalInset * 2
            let drawHeight = size.height - verticalInset * 2
            var path = Path()
            path.move(to: CGPoint(x: horizontalInset, y: verticalInset))
            path.addLine(to: CGPoint(x: horizontalInset + drawWidth, y: verticalInset))
            path.addLine(to: CGPoint(x: horizontalInset + drawWidth, y: verticalInset + drawHeight))
            path.addLine(to: CGPoint(x: horizontalInset, y: verticalInset + drawHeight))
            path.closeSubpath()
            context.stroke(path, with: .color(.secondary.opacity(0.15)), lineWidth: 1)
        }
        .overlay {
            GeometryReader { geo in
                let drawWidth = geo.size.width - horizontalInset * 2
                let drawHeight = geo.size.height - verticalInset * 2
                let zeroY = verticalInset + drawHeight * (1 - (0 - equalizerMinGain) / (equalizerMaxGain - equalizerMinGain))
                Path { p in
                    p.move(to: CGPoint(x: horizontalInset, y: zeroY))
                    p.addLine(to: CGPoint(x: horizontalInset + drawWidth, y: zeroY))
                }
                .stroke(.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
    }

    private func linePath(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    private func fillPath(_ points: [CGPoint]) -> Path {
        var path = linePath(points)
        if let last = points.last {
            path.addLine(to: CGPoint(x: last.x, y: last.y + 10))
        }
        if let first = points.first {
            path.addLine(to: CGPoint(x: first.x, y: first.y + 10))
        }
        path.closeSubpath()
        return path
    }

    // MARK: - Hit testing

    private func bandIndex(for location: CGPoint, size: CGSize) -> Int {
        let drawWidth = size.width - horizontalInset * 2
        let x = max(0, min(1, (location.x - horizontalInset) / drawWidth))
        let raw = x * CGFloat(gains.count - 1)
        let index = min(max(0, Int(raw.rounded())), gains.count - 1)
        return index
    }

    private func gain(for location: CGPoint, size: CGSize) -> Double {
        let drawHeight = size.height - verticalInset * 2
        let y = max(0, min(1, (location.y - verticalInset) / drawHeight))
        let gain = equalizerMinGain + (1 - Double(y)) * (equalizerMaxGain - equalizerMinGain)
        return min(equalizerMaxGain, max(equalizerMinGain, gain.rounded()))
    }

    private func setGain(_ gain: Double, at index: Int) {
        guard gains.indices.contains(index), gains[index] != gain else { return }
        gains[index] = gain
        SettingsStore.shared.equalizerPresetID = "custom"
        PlayerController.shared.applyPlaybackSettings()
    }
}
