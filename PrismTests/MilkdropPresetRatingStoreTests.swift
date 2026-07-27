//
//  MilkdropPresetRatingStoreTests.swift
//  PrismTests
//
//  Coverage for MilkdropPresetRatingStore's path-keyed persistence — stars and issue flags must
//  round-trip through a fresh instance sharing the same UserDefaults (simulating a relaunch),
//  independently of one another and of each other flag, and urls(flaggedWith:) must surface
//  exactly what was flagged with that issue. Each test uses its own UserDefaults suite (not
//  .standard) so this never touches the real app's actual persisted ratings.
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

    @Test func freshStoreHasNoRatingForAnyURL() {
        let store = MilkdropPresetRatingStore(defaults: freshDefaults())
        #expect(store.rating(for: makeURL("a.milk")) == nil)
    }

    @Test func setStarsRecordsAndReturnsTheRating() {
        let store = MilkdropPresetRatingStore(defaults: freshDefaults())
        let url = makeURL("a.milk")
        store.setStars(4, for: url)
        #expect(store.rating(for: url) == MilkdropPresetRating(stars: 4, issues: []))
    }

    @Test func flagRecordsAndReturnsTheIssueWithoutTouchingStars() {
        let store = MilkdropPresetRatingStore(defaults: freshDefaults())
        let url = makeURL("a.milk")
        store.setStars(3, for: url)
        store.flag(.allWhite, for: url)
        #expect(store.rating(for: url) == MilkdropPresetRating(stars: 3, issues: [.allWhite]))
    }

    @Test func settingStarsAfterFlaggingLeavesTheFlagSet() {
        let store = MilkdropPresetRatingStore(defaults: freshDefaults())
        let url = makeURL("a.milk")
        store.flag(.allWhite, for: url)
        store.setStars(1, for: url)
        #expect(store.rating(for: url) == MilkdropPresetRating(stars: 1, issues: [.allWhite]))
    }

    @Test func multipleFlagsAccumulateOnTheSamePreset() {
        let store = MilkdropPresetRatingStore(defaults: freshDefaults())
        let url = makeURL("a.milk")
        store.flag(.tooJittery, for: url)
        store.flag(.strobing, for: url)
        #expect(store.rating(for: url)?.issues == [.tooJittery, .strobing])
    }

    @Test func ratingsPersistAcrossANewInstanceSharingTheSameDefaults() {
        let defaults = freshDefaults()
        let url = makeURL("relaunch.milk")
        MilkdropPresetRatingStore(defaults: defaults).setStars(5, for: url)

        let secondLaunch = MilkdropPresetRatingStore(defaults: defaults)
        #expect(secondLaunch.rating(for: url)?.stars == 5)
    }

    @Test func flagsPersistAcrossANewInstanceSharingTheSameDefaults() {
        let defaults = freshDefaults()
        let url = makeURL("relaunch.milk")
        MilkdropPresetRatingStore(defaults: defaults).flag(.strobing, for: url)

        let secondLaunch = MilkdropPresetRatingStore(defaults: defaults)
        #expect(secondLaunch.rating(for: url)?.issues == [.strobing])
    }

    @Test func urlsFlaggedWithReturnsOnlyPresetsCarryingThatSpecificIssue() {
        let store = MilkdropPresetRatingStore(defaults: freshDefaults())
        let white = makeURL("white.milk")
        let jittery = makeURL("jittery.milk")
        let fine = makeURL("fine.milk")
        store.flag(.allWhite, for: white)
        store.flag(.tooJittery, for: jittery)
        store.setStars(5, for: fine)

        #expect(store.urls(flaggedWith: .allWhite) == [white])
        #expect(store.urls(flaggedWith: .tooJittery) == [jittery])
        #expect(store.urls(flaggedWith: .strobing) == [])
    }

    @Test func settingStarsForANewURLDoesNotAffectAnExistingRating() {
        let store = MilkdropPresetRatingStore(defaults: freshDefaults())
        let urlA = makeURL("a.milk")
        let urlB = makeURL("b.milk")
        store.setStars(2, for: urlA)
        store.setStars(5, for: urlB)
        #expect(store.rating(for: urlA)?.stars == 2)
        #expect(store.rating(for: urlB)?.stars == 5)
    }
}
