//
//  ContentView.swift
//  Trop
//
//  Created by 686udjie on 28/06/2026.
//

import Combine
import SwiftUI

struct ContentView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var nowPlaying = NowPlaying.shared
    @State private var selectedTab = SettingsStore.shared.defaultTab
    @State private var previousTab = SettingsStore.shared.defaultTab
    @State private var isExpanded = false
    @State private var scrollState = MiniPlayerScrollState()

    var body: some View {
        tabBar
            .tabBarMinimizeBehavior(.never)
            .tabViewBottomAccessory(isEnabled: nowPlaying.isBarPresented) {
                MiniPlayerBarView(onExpand: {
                    // Dismiss the keyboard before expanding the player so the reveal is visible on the first tap.
                    UIApplication.shared.sendAction(
                        #selector(UIResponder.resignFirstResponder),
                        to: nil,
                        from: nil,
                        for: nil
                    )
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                        isExpanded = true
                    }
                })
            }
            .background {
                backgroundLayer
            }
            .overlay {
                if isExpanded {
                    FullPlayerView(onCollapse: {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            isExpanded = false
                        }
                    })
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .environment(scrollState)
        .onAppear { AppRouter.shared.selectedTabIndex = selectedTab }
        .onChange(of: selectedTab) { _, newValue in
            if newValue != 3 {
                previousTab = newValue
            }
            AppRouter.shared.selectedTabIndex = newValue
        }
        .onReceive(AppRouter.shared.$activeRoute) { route in
            // A detail page was opened from an overlay: collapse the player so
            // the pushed page is visible underneath.
            if route != nil {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    isExpanded = false
                }
            }
        }
        .onReceive(AppRouter.shared.$playerExpandToken.dropFirst()) { _ in
            withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                isExpanded = true
            }
        }
        .simultaneousGesture(backSwipeGesture)
    }

    @ViewBuilder
    private var tabBar: some View {
        tabContent
    }

    private var tabContent: some View {
        TabView(selection: $selectedTab) {
            Tab(value: 0) {
                HomeScreenView()
            } label: {
                tabLabel("Home", systemImage: "music.note.house.fill")
            }

            Tab(value: 1) {
                LibraryView()
            } label: {
                tabLabel("Library", systemImage: "music.note.square.stack")
            }

            Tab(value: 2) {
                ExploreView()
            } label: {
                tabLabel("Explore", systemImage: "flame")
            }

            Tab(value: 3) {
                SearchView(onExitSearch: { selectedTab = previousTab })
            } label: {
                tabLabel("Search", systemImage: "magnifyingglass")
            }
        }
    }

    private func tabLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .labelStyle(.iconOnly)
    }

    private var backSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let isHorizontal = abs(value.translation.width) > abs(value.translation.height)
                guard !isExpanded,
                      selectedTab != 3,
                      value.startLocation.x <= 28,
                      isHorizontal,
                      value.translation.width > 80 else { return }

                let router = AppRouter.shared
                let depth = router.activePathDepth
                guard depth > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard !isExpanded, router.activePathDepth == depth else { return }
                    router.popActiveRoute()
                }
            }
    }

    @ViewBuilder
    private var backgroundLayer: some View {
        if settings.playerBackgroundStyle == .solid {
            Color.black.ignoresSafeArea()
        } else if let accent = nowPlaying.accentColor {
            accent
                .opacity(0.06)
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.8), value: nowPlaying.accentColor)
        }
    }
}

#Preview {
    ContentView()
}
