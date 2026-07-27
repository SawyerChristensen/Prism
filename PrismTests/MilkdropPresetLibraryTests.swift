//
//  MilkdropPresetLibraryTests.swift
//  PrismTests
//
//  Coverage for MilkdropPresetLibrary's folder-scan, sequential-discovery order, and security-
//  scoped-bookmark persistence — the things easy to get subtly wrong here: a stale/deleted
//  bookmark must degrade to "unconfigured" rather than crash, switching to a new root must fully
//  replace the previous scan rather than accumulate stale entries, and sequential discovery must
//  be a stable, repeatable (sorted-by-path) order that wraps around at the end. Each test uses its
//  own UserDefaults suite (not .standard) so this never touches the real app's actual persisted
//  preset-library setting.
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
        #expect(library.nextSequentialPresetURL(after: nil) == nil)
    }

    @Test func setLibraryRootScansRecursivelyAndIgnoresNonMilkFiles() throws {
        let folder = try makeFolder(fileNames: ["a.milk", "b.milk", "readme.txt", "c.MILK"])
        let library = MilkdropPresetLibrary(defaults: freshDefaults())
        library.setLibraryRoot(folder)
        #expect(library.isConfigured == true)
        #expect(library.presetURLs.count == 4) // a, b, c.MILK (case-insensitive extension) + nested
        #expect(library.presetURLs.allSatisfy { $0.pathExtension.lowercased() == "milk" })
    }

    @Test func nextSequentialPresetURLStartsAtTheFirstFileWhenNothingIsLoadedYet() throws {
        let folder = try makeFolder(fileNames: ["a.milk", "b.milk"])
        let library = MilkdropPresetLibrary(defaults: freshDefaults())
        library.setLibraryRoot(folder)
        let first = try #require(library.nextSequentialPresetURL(after: nil))
        #expect(first == library.presetURLs.first)
    }

    @Test func nextSequentialPresetURLWalksTheFullSortedOrderAndWraps() throws {
        let folder = try makeFolder(fileNames: ["a.milk", "b.milk"])
        let library = MilkdropPresetLibrary(defaults: freshDefaults())
        library.setLibraryRoot(folder)

        // 3 total (a, b, nested.milk under SubFolder), sorted by path.
        var current: URL? = nil
        var visited: [URL] = []
        for _ in 0..<library.presetURLs.count {
            current = library.nextSequentialPresetURL(after: current)
            visited.append(try #require(current))
        }
        #expect(visited == library.presetURLs)

        // One more step wraps back around to the first file.
        #expect(library.nextSequentialPresetURL(after: current) == library.presetURLs.first)
    }

    @Test func nextSequentialPresetURLStartsOverIfCurrentURLIsntInTheScan() throws {
        let folder = try makeFolder(fileNames: ["a.milk", "b.milk"])
        let library = MilkdropPresetLibrary(defaults: freshDefaults())
        library.setLibraryRoot(folder)

        let outsideFile = FileManager.default.temporaryDirectory.appendingPathComponent("outside.milk")
        #expect(library.nextSequentialPresetURL(after: outsideFile) == library.presetURLs.first)
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

    @Test func emptyFolderIsConfiguredButHasNoSequentialPick() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let library = MilkdropPresetLibrary(defaults: freshDefaults())
        library.setLibraryRoot(empty)
        #expect(library.isConfigured == true)
        #expect(library.nextSequentialPresetURL(after: nil) == nil)
    }

    @Test func presetURLsAreSortedByPath() throws {
        let folder = try makeFolder(fileNames: ["z.milk", "a.milk", "m.milk"])
        let library = MilkdropPresetLibrary(defaults: freshDefaults())
        library.setLibraryRoot(folder)
        #expect(library.presetURLs == library.presetURLs.sorted { $0.path < $1.path })
    }

    private func makeBundleXML(favoriting names: [String]) throws -> URL {
        let presets = names.map { "<Preset Name=\"\($0)\" />" }.joined()
        let xml = "<NestDropSettings><FavoriteList><Favorite1>\(presets)</Favorite1></FavoriteList></NestDropSettings>"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xml")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func filterToFavoritesNarrowsToOnlyTheNamedFiles() throws {
        let folder = try makeFolder(fileNames: ["a.milk", "b.milk"])
        let library = MilkdropPresetLibrary(defaults: freshDefaults())
        library.setLibraryRoot(folder)
        let bundle = try makeBundleXML(favoriting: ["a.milk"])

        library.filterToFavorites(from: bundle)
        #expect(library.isShowingFavoritesOnly == true)
        #expect(library.presetURLs.map(\.lastPathComponent) == ["a.milk"])
    }

    @Test func clearFavoritesFilterRestoresTheFullScan() throws {
        let folder = try makeFolder(fileNames: ["a.milk", "b.milk"])
        let library = MilkdropPresetLibrary(defaults: freshDefaults())
        library.setLibraryRoot(folder)
        let fullCount = library.presetURLs.count
        let bundle = try makeBundleXML(favoriting: ["a.milk"])

        library.filterToFavorites(from: bundle)
        library.clearFavoritesFilter()
        #expect(library.isShowingFavoritesOnly == false)
        #expect(library.presetURLs.count == fullCount)
    }

    @Test func settingANewRootClearsAnActiveFavoritesFilter() throws {
        let folderA = try makeFolder(fileNames: ["a.milk"])
        let folderB = try makeFolder(fileNames: ["onlyInB.milk"])
        let library = MilkdropPresetLibrary(defaults: freshDefaults())
        library.setLibraryRoot(folderA)
        library.filterToFavorites(from: try makeBundleXML(favoriting: ["a.milk"]))

        library.setLibraryRoot(folderB)
        #expect(library.isShowingFavoritesOnly == false)
        #expect(library.presetURLs.contains { $0.lastPathComponent == "onlyInB.milk" })
    }

    @Test func filterToFavoritesWithNoMatchingNamesLeavesPresetURLsEmpty() throws {
        let folder = try makeFolder(fileNames: ["a.milk"])
        let library = MilkdropPresetLibrary(defaults: freshDefaults())
        library.setLibraryRoot(folder)
        library.filterToFavorites(from: try makeBundleXML(favoriting: ["doesNotExist.milk"]))
        #expect(library.presetURLs.isEmpty)
        #expect(library.nextSequentialPresetURL(after: nil) == nil)
    }
}
