//
//  MilkdropPresetLibraryTests.swift
//  PrismTests
//
//  Coverage for MilkdropPresetLibrary's folder-scan and security-scoped-bookmark persistence — the
//  two things easy to get subtly wrong here: a stale/deleted bookmark must degrade to "unconfigured"
//  rather than crash, and switching to a new root must fully replace the previous scan rather than
//  accumulate stale entries. Each test uses its own UserDefaults suite (not .standard) so this never
//  touches the real app's actual persisted preset-library setting.
//

import Foundation
import Testing
@testable import Prism

struct MilkdropPresetLibraryTests {
    private func makeFolder(fileNames: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sub = root.appendingPathComponent("SubFolder", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        for name in fileNames {
            try "data".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        // Confirms the scan recurses into subfolders, not just the top level.
        try "data".write(to: sub.appendingPathComponent("nested.milk"), atomically: true, encoding: .utf8)
        return root
    }

    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "MilkdropPresetLibraryTestSuite_\(UUID().uuidString)")!
    }

    @Test func freshLibraryIsNotConfigured() {
        let library = MilkdropPresetLibrary(defaults: freshDefaults())
        #expect(library.isConfigured == false)
        #expect(library.randomPresetURL() == nil)
    }

    @Test func setLibraryRootScansRecursivelyAndIgnoresNonMilkFiles() throws {
        let folder = try makeFolder(fileNames: ["a.milk", "b.milk", "readme.txt", "c.MILK"])
        let library = MilkdropPresetLibrary(defaults: freshDefaults())
        library.setLibraryRoot(folder)
        #expect(library.isConfigured == true)
        #expect(library.presetURLs.count == 4) // a, b, c.MILK (case-insensitive extension) + nested
        #expect(library.presetURLs.allSatisfy { $0.pathExtension.lowercased() == "milk" })
    }

    @Test func randomPresetURLAlwaysReturnsAScannedFile() throws {
        let folder = try makeFolder(fileNames: ["a.milk", "b.milk"])
        let library = MilkdropPresetLibrary(defaults: freshDefaults())
        library.setLibraryRoot(folder)
        for _ in 0..<10 {
            let picked = try #require(library.randomPresetURL())
            #expect(library.presetURLs.contains(picked))
        }
    }

    @Test func bookmarkPersistsAcrossANewInstanceSharingTheSameDefaults() throws {
        let folder = try makeFolder(fileNames: ["x.milk", "y.milk"])
        let defaults = freshDefaults()
        let first = MilkdropPresetLibrary(defaults: defaults)
        first.setLibraryRoot(folder)

        let second = MilkdropPresetLibrary(defaults: defaults)
        #expect(second.isConfigured == true)
        #expect(second.rootURL?.standardizedFileURL == folder.standardizedFileURL)
        #expect(second.presetURLs.count == first.presetURLs.count)
    }

    @Test func deletedBookmarkedFolderDegradesToUnconfiguredInsteadOfCrashing() throws {
        let folder = try makeFolder(fileNames: ["z.milk"])
        let defaults = freshDefaults()
        let first = MilkdropPresetLibrary(defaults: defaults)
        first.setLibraryRoot(folder)
        try FileManager.default.removeItem(at: folder)

        let second = MilkdropPresetLibrary(defaults: defaults)
        #expect(second.isConfigured == false)
    }

    @Test func settingANewRootReplacesThePreviousScanEntirely() throws {
        let folderA = try makeFolder(fileNames: ["onlyInA.milk"])
        let folderB = try makeFolder(fileNames: ["onlyInB.milk"])
        let library = MilkdropPresetLibrary(defaults: freshDefaults())

        library.setLibraryRoot(folderA)
        #expect(library.presetURLs.contains { $0.lastPathComponent == "onlyInA.milk" })

        library.setLibraryRoot(folderB)
        #expect(!library.presetURLs.contains { $0.lastPathComponent == "onlyInA.milk" })
        #expect(library.presetURLs.contains { $0.lastPathComponent == "onlyInB.milk" })
    }

    @Test func emptyFolderIsConfiguredButHasNoRandomPick() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let library = MilkdropPresetLibrary(defaults: freshDefaults())
        library.setLibraryRoot(empty)
        #expect(library.isConfigured == true)
        #expect(library.randomPresetURL() == nil)
    }
}
