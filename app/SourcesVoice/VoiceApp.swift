import SwiftUI

@main
struct VoiceApp: App {
    /// background URLSession 的事件交付必须有 AppDelegate 接，见 VoiceAppDelegate.swift
    @UIApplicationDelegateAdaptor(VoiceAppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
