//
//  MilkdropPresetRatingStoreTests.swift
//  PrismTests
//
//  Coverage for MilkdropPresetRatingStore's filename-keyed persistence — stars and issue flags must
//  round-trip through a fresh instance sharing the same UserDefaults (simulating a relaunch),
//  independently of one another and of each other flag, and filenames(flaggedWith:) must surface
//  exactly what was flagged with that issue. Each test uses its own UserDefaults suite (not
//  .standard) so this never touches the real app's actual persisted ratings.
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
        #expect(store.rating(for: url) == MilkdropPresetRating(stars: 4, issues: []))
    }

    @Test func flagRecordsAndReturnsTheIssueWithoutTouchingStars() {
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: emptyBundle())
        let url = makeURL("a.milk")
        store.setStars(3, for: url)
        store.flag(.allWhite, for: url)
        #expect(store.rating(for: url) == MilkdropPresetRating(stars: 3, issues: [.allWhite]))
    }

    @Test func settingStarsAfterFlaggingLeavesTheFlagSet() {
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: emptyBundle())
        let url = makeURL("a.milk")
        store.flag(.allWhite, for: url)
        store.setStars(1, for: url)
        #expect(store.rating(for: url) == MilkdropPresetRating(stars: 1, issues: [.allWhite]))
    }

    @Test func multipleFlagsAccumulateOnTheSamePreset() {
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: emptyBundle())
        let url = makeURL("a.milk")
        store.flag(.tooJittery, for: url)
        store.flag(.strobing, for: url)
        #expect(store.rating(for: url)?.issues == [.tooJittery, .strobing])
    }

    @Test func ratingsPersistAcrossANewInstanceSharingTheSameDefaults() {
        let defaults = freshDefaults()
        let url = makeURL("relaunch.milk")
        MilkdropPresetRatingStore(defaults: defaults, bundle: emptyBundle()).setStars(5, for: url)

        let secondLaunch = MilkdropPresetRatingStore(defaults: defaults, bundle: emptyBundle())
        #expect(secondLaunch.rating(for: url)?.stars == 5)
    }

    @Test func flagsPersistAcrossANewInstanceSharingTheSameDefaults() {
        let defaults = freshDefaults()
        let url = makeURL("relaunch.milk")
        MilkdropPresetRatingStore(defaults: defaults, bundle: emptyBundle()).flag(.strobing, for: url)

        let secondLaunch = MilkdropPresetRatingStore(defaults: defaults, bundle: emptyBundle())
        #expect(secondLaunch.rating(for: url)?.issues == [.strobing])
    }

    @Test func filenamesFlaggedWithReturnsOnlyPresetsCarryingThatSpecificIssue() {
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: emptyBundle())
        let white = makeURL("white.milk")
        let jittery = makeURL("jittery.milk")
        let fine = makeURL("fine.milk")
        store.flag(.allWhite, for: white)
        store.flag(.tooJittery, for: jittery)
        store.setStars(5, for: fine)

        #expect(store.filenames(flaggedWith: .allWhite) == ["white.milk"])
        #expect(store.filenames(flaggedWith: .tooJittery) == ["jittery.milk"])
        #expect(store.filenames(flaggedWith: .strobing) == [])
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

    @Test func bundledSeedIsUsedWhenLocalDefaultsHaveNoRatingForThatPreset() {
        let bundle = seededBundle(["seeded.milk": MilkdropPresetRating(stars: 4, issues: [])])
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: bundle)
        #expect(store.rating(for: makeURL("seeded.milk")) == MilkdropPresetRating(stars: 4, issues: []))
    }

    @Test func localDefaultsOverrideTheBundledSeedForTheSamePreset() {
        let bundle = seededBundle(["seeded.milk": MilkdropPresetRating(stars: 1, issues: [.allWhite])])
        let defaults = freshDefaults()
        let store = MilkdropPresetRatingStore(defaults: defaults, bundle: bundle)
        store.setStars(5, for: makeURL("seeded.milk"))
        #expect(store.rating(for: makeURL("seeded.milk")) == MilkdropPresetRating(stars: 5, issues: []))
    }

    @Test func presetsWithNoLocalRatingAndNoBundledSeedRemainUnrated() {
        let bundle = seededBundle(["seeded.milk": MilkdropPresetRating(stars: 4, issues: [])])
        let store = MilkdropPresetRatingStore(defaults: freshDefaults(), bundle: bundle)
        #expect(store.rating(for: makeURL("unrelated.milk")) == nil)
    }
}
