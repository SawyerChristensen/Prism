//
//  MilkdropLastPresetStoreTests.swift
//  PrismTests
//
//  Coverage for MilkdropLastPresetStore's security-scoped-bookmark persistence — the same shape
//  of coverage as MilkdropPresetLibraryTests, but for a single remembered file rather than a
//  scanned folder: a deleted/moved file must degrade to nil rather than crash, the bookmark must
//  survive a fresh instance sharing the same UserDefaults (simulating a relaunch), and
//  remembering a new file must replace whichever one was remembered before. Each test uses its
//  own UserDefaults suite (not .standard) so this never touches the real app's actual persisted
//  setting. Verified first via a standalone swiftc harness (MilkdropLastPresetStore.swift has no
//  AppKit/Metal/CoreAudio dependency) per TO DO.md's testing policy.
//

import Foundation
import Testing
@testable import Prism

struct MilkdropLastPresetStoreTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "MilkdropLastPresetStoreTestSuite_\(UUID().uuidString)")!
    }

    private func makeFile(named name: String = "test.milk") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try "data".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func freshStoreHasNothingRemembered() {
        let store = MilkdropLastPresetStore(defaults: freshDefaults())
        var called = false
        let result: Int? = store.withLastPreset { _ in called = true; return 1 }
        #expect(result == nil)
        #expect(called == false)
    }

    @Test func rememberedFileResolvesOnTheSameInstance() throws {
        let store = MilkdropLastPresetStore(defaults: freshDefaults())
        let file = try makeFile()
        store.rememberLoaded(file)

        var resolved: URL?
        store.withLastPreset { resolved = $0 }
        #expect(resolved?.standardizedFileURL == file.standardizedFileURL)
    }

    @Test func bookmarkPersistsAcrossANewInstanceSharingTheSameDefaults() throws {
        let defaults = freshDefaults()
        let file = try makeFile(named: "relaunch.milk")
        MilkdropLastPresetStore(defaults: defaults).rememberLoaded(file)

        let secondLaunch = MilkdropLastPresetStore(defaults: defaults)
        var resolved: URL?
        secondLaunch.withLastPreset { resolved = $0 }
        #expect(resolved?.standardizedFileURL == file.standardizedFileURL)
    }

    @Test func deletedRememberedFileDegradesToNilInsteadOfCrashing() throws {
        let defaults = freshDefaults()
        let file = try makeFile(named: "deleteme.milk")
        let store = MilkdropLastPresetStore(defaults: defaults)
        store.rememberLoaded(file)
        try FileManager.default.removeItem(at: file)

        var called = false
        let result: Int? = store.withLastPreset { _ in called = true; return 1 }
        #expect(result == nil)
        #expect(called == false)
    }

    @Test func rememberingANewFileReplacesThePreviousOne() throws {
        let defaults = freshDefaults()
        let fileA = try makeFile(named: "a.milk")
        let fileB = try makeFile(named: "b.milk")
        let store = MilkdropLastPresetStore(defaults: defaults)
        store.rememberLoaded(fileA)
        store.rememberLoaded(fileB)

        var resolved: URL?
        store.withLastPreset { resolved = $0 }
        #expect(resolved?.standardizedFileURL == fileB.standardizedFileURL)
    }

    @Test func withLastPresetPropagatesBodysReturnValue() throws {
        let defaults = freshDefaults()
        let file = try makeFile()
        let store = MilkdropLastPresetStore(defaults: defaults)
        store.rememberLoaded(file)

        let result = store.withLastPreset { url in url.lastPathComponent }
        #expect(result == "test.milk")
    }
}
