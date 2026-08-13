//
//  MilkdropPresetRatingStoreTests.swift
//  PrismTests
//
//  Coverage for MilkdropPresetRatingStore's filename-keyed persistence — stars and issue flags must
//  round-trip through a fresh instance sharing the same UserDefaults (simulating a relaunch),
//  independently of one another and of each other flag. Each test uses its own UserDefaults suite
//  (not .standard) so this never touches the real app's actual persisted ratings.
//
//  Every test below also passes `bundle: .empty` explicitly (an empty in-memory Bundle with no
//  Resources/PresetRatings.json) rather than relying on the real Prism.app bundle's default not
//  colliding with test fixture filenames like "a.milk" — PrismTests is a hosted test bundle
//  (TEST_HOST = Prism.app), so Bundle.main during a test run actually IS the real app bundle, and
//  would otherwise silently seed these stores from whatever's really shipped. The bundled-seed
//  merge behavior itself is covered separately below with a real fixture bundle.
//

import Foundation
import Testing
@testable import Prism

struct MilkdropPresetRatingStoreTests {
    private func freshDefaults() -> UserDefaults {
        UserDefaults(suiteName: "MilkdropPresetRatingStoreTestSuite_\(UUID().uuidString)")!
    }

    private func makeURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(name)
    }

    /// A real Bundle backed by a scratch directory containing no PresetRatings.json — an "empty"
    /// bundle .main-equivalent, since Bundle itself has no such built-in fixture.
    private func emptyBundle() -> Bundle {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Bundle(url: dir)!
    }

    /// A Bundle whose Resources/-equivalent root contains a PresetRatings.json seeded with
    /// `seed`, for exercising the bundled-seed merge behavior.
    private func seededBundle(_ seed: [String: MilkdropPresetRating]) -> Bundle {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try! JSONEncoder().encode(seed)
        try! data.write(to: dir.appendingPathComponent("PresetRatings.json"))
        return Bundle(url: dir)!
    }

    @Test func freshStoreHasNoRatingForAnyURL() {
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: emptyBundle())
        #expect(store.rating(for: makeURL("a.milk")) == nil)
    }

    @Test func setStarsRecordsAndReturnsTheRating() {
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: emptyBundle())
        let url = makeURL("a.milk")
        store.setStars(4, for: url)
        #expect(store.rating(for: url) == MilkdropPresetRating(stars: 4))
    }

    @Test func ratingsPersistAcrossANewInstanceSharingTheSameDefaults() {
        let defaults = freshDefaults()
        let url = makeURL("relaunch.milk")
        MilkdropPresetRatingStore(defaults: defaults, bundle: emptyBundle()).setStars(5, for: url)

        let secondLaunch = MilkdropPresetRatingStore(defaults: defaults, bundle: emptyBundle())
        #expect(secondLaunch.rating(for: url)?.stars == 5)
    }

    @Test func settingStarsForANewURLDoesNotAffectAnExistingRating() {
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: emptyBundle())
        let urlA = makeURL("a.milk")
        let urlB = makeURL("b.milk")
        store.setStars(2, for: urlA)
        store.setStars(5, for: urlB)
        #expect(store.rating(for: urlA)?.stars == 2)
        #expect(store.rating(for: urlB)?.stars == 5)
    }

    @Test func settingStarsAgainOverwritesThePreviousRating() {
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: emptyBundle())
        let url = makeURL("a.milk")
        store.setStars(2, for: url)
        store.setStars(5, for: url)
        #expect(store.rating(for: url)?.stars == 5)
    }

    @Test func bundledSeedIsUsedWhenLocalDefaultsHaveNoRatingForThatPreset() {
        let bundle = seededBundle(["seeded.milk": MilkdropPresetRating(stars: 4)])
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: bundle)
        #expect(store.rating(for: makeURL("seeded.milk")) == MilkdropPresetRating(stars: 4))
    }

    @Test func localDefaultsOverrideTheBundledSeedForTheSamePreset() {
        let bundle = seededBundle(["seeded.milk": MilkdropPresetRating(stars: 1)])
        let defaults = freshDefaults()
        let store = MilkdropPresetRatingStore(defaults: defaults, bundle: bundle)
        store.setStars(5, for: makeURL("seeded.milk"))
        #expect(store.rating(for: makeURL("seeded.milk")) == MilkdropPresetRating(stars: 5))
    }

    @Test func presetsWithNoLocalRatingAndNoBundledSeedRemainUnrated() {
        let bundle = seededBundle(["seeded.milk": MilkdropPresetRating(stars: 4)])
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: bundle)
        #expect(store.rating(for: makeURL("unrelated.milk")) == nil)
    }

    @Test func freshStoreReportsNothingAsFlagged() {
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: emptyBundle())
        #expect(store.isFlagged(makeURL("a.milk")) == false)
    }

    @Test func flagRecordsAndReturnsTheIssueWithoutTouchingStars() {
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: emptyBundle())
        let url = makeURL("a.milk")
        store.setStars(3, for: url)
        store.flag(.tooJittery, for: url)
        #expect(store.rating(for: url) == MilkdropPresetRating(stars: 3, issues: [.tooJittery]))
        #expect(store.isFlagged(url))
    }

    @Test func settingStarsAfterFlaggingLeavesTheFlagSet() {
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: emptyBundle())
        let url = makeURL("a.milk")
        store.flag(.strobing, for: url)
        store.setStars(1, for: url)
        #expect(store.rating(for: url) == MilkdropPresetRating(stars: 1, issues: [.strobing]))
        #expect(store.isFlagged(url))
    }

    @Test func multipleFlagsAccumulateOnTheSamePreset() {
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: emptyBundle())
        let url = makeURL("a.milk")
        store.flag(.tooJittery, for: url)
        store.flag(.strobing, for: url)
        store.flag(.tooDark, for: url)
        store.flag(.tooBright, for: url)
        store.flag(.tooFast, for: url)
        #expect(store.rating(for: url)?.issues == [.tooJittery, .strobing, .tooDark, .tooBright, .tooFast])
    }

    @Test func flagsPersistAcrossANewInstanceSharingTheSameDefaults() {
        let defaults = freshDefaults()
        let url = makeURL("relaunch.milk")
        MilkdropPresetRatingStore(defaults: defaults, bundle: emptyBundle()).flag(.tooDark, for: url)

        let secondLaunch = MilkdropPresetRatingStore(defaults: defaults, bundle: emptyBundle())
        #expect(secondLaunch.isFlagged(url))
        #expect(secondLaunch.rating(for: url)?.issues == [.tooDark])
    }

    @Test func flaggingOnePresetDoesNotAffectAnother() {
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: emptyBundle())
        let flagged = makeURL("flagged.milk")
        let clean = makeURL("clean.milk")
        store.flag(.strobing, for: flagged)
        #expect(store.isFlagged(flagged))
        #expect(store.isFlagged(clean) == false)
    }

    @Test func isFlaggedReadsFromTheBundledSeedWhenLocalHasNothingForThatPreset() {
        // Not a realistic seed in production (nothing ever writes issues into
        // Resources/PresetRatings.json - see MilkdropPresetRatingStore's own top-of-file doc
        // comment), but the store itself merges bundled+local per-key with no special-casing of the
        // `issues` field, so isFlagged has no reason to behave differently than `rating(for:)` does here.
        let bundle = seededBundle(["seeded.milk": MilkdropPresetRating(stars: 4, issues: [.tooJittery])])
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: bundle)
        #expect(store.isFlagged(makeURL("seeded.milk")))
    }

    // MARK: - DEBUG direct-to-repo writes (setRepoRoot/setStars/flag)

    /// A scratch directory shaped like the real repo root: `Prism/Resources/PresetRatings.json`
    /// plus a repo-root `FlaggedPresets.json`, optionally pre-seeded — for exercising
    /// setRepoRoot/writeStarsDirectlyToRepo/writeFlagDirectlyToRepo without touching the real repo.
    private func makeRepoRoot(
        existingRatings: [String: MilkdropPresetRating] = [:],
        existingFlags: [String: [String]] = [:]
    ) -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resourcesDir = root.appendingPathComponent("Prism/Resources", isDirectory: true)
        try! FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)
        try! JSONEncoder().encode(existingRatings).write(to: resourcesDir.appendingPathComponent("PresetRatings.json"))
        try! JSONEncoder().encode(existingFlags).write(to: root.appendingPathComponent("FlaggedPresets.json"))
        return root
    }

    private func readRepoRatings(_ root: URL) -> [String: MilkdropPresetRating] {
        let data = try! Data(contentsOf: root.appendingPathComponent("Prism/Resources/PresetRatings.json"))
        return try! JSONDecoder().decode([String: MilkdropPresetRating].self, from: data)
    }

    private func readRepoFlags(_ root: URL) -> [String: [String]] {
        let data = try! Data(contentsOf: root.appendingPathComponent("FlaggedPresets.json"))
        return try! JSONDecoder().decode([String: [String]].self, from: data)
    }

    @Test func settingRepoRootFlushesInMemoryStateWithoutDroppingWhatWasAlreadyOnDisk() {
        let repoRoot = makeRepoRoot(existingRatings: ["untouched.milk": MilkdropPresetRating(stars: 2)])
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: emptyBundle())
        // Recorded before repo access exists - lands in UserDefaults via the ordinary fallback path.
        store.setStars(4, for: makeURL("accumulated-before-grant.milk"))

        store.setRepoRoot(repoRoot)

        let onDisk = readRepoRatings(repoRoot)
        #expect(onDisk["untouched.milk"]?.stars == 2)
        #expect(onDisk["accumulated-before-grant.milk"]?.stars == 4)
    }

    @Test func afterRepoRootIsSetStarsAreWrittenDirectlyToTheRepoFile() {
        let repoRoot = makeRepoRoot(existingRatings: ["other.milk": MilkdropPresetRating(stars: 1)])
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: emptyBundle())
        store.setRepoRoot(repoRoot)

        store.setStars(5, for: makeURL("live.milk"))

        let onDisk = readRepoRatings(repoRoot)
        #expect(onDisk["live.milk"]?.stars == 5)
        // The pre-existing entry survives untouched - a single-entry write is never a full replace.
        #expect(onDisk["other.milk"]?.stars == 1)
    }

    @Test func afterRepoRootIsSetFlagsAreWrittenDirectlyToTheRepoFileAndAccumulate() {
        let repoRoot = makeRepoRoot(existingFlags: ["other.milk": ["strobing"]])
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: emptyBundle())
        store.setRepoRoot(repoRoot)
        let url = makeURL("live.milk")

        store.flag(.tooJittery, for: url)
        store.flag(.tooDark, for: url)

        let onDisk = readRepoFlags(repoRoot)
        #expect(Set(onDisk["live.milk"] ?? []) == ["tooJittery", "tooDark"])
        // The pre-existing entry survives untouched - same never-a-full-replace guarantee as stars.
        #expect(onDisk["other.milk"] == ["strobing"])
    }

    @Test func settingStarsAfterRepoRootIsSetDoesNotWriteToUserDefaults() {
        let repoRoot = makeRepoRoot()
        let defaults = freshDefaults()
        let store = MilkdropPresetRatingStore(defaults: defaults, bundle: emptyBundle())
        store.setRepoRoot(repoRoot)

        store.setStars(5, for: makeURL("live.milk"))

        #expect(defaults.data(forKey: "MilkdropPresetRatings") == nil)
    }
}
