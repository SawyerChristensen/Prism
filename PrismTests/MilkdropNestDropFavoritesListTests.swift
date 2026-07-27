//
//  MilkdropNestDropFavoritesListTests.swift
//  PrismTests
//
//  Coverage for parsing a real NestDrop bundle XML's <FavoriteList> — the shape actually found in
//  ~/Desktop/BestMilkdropPresetsPack/User Profile/Default NestDrop Bundle.xml`: a `<FavoriteN>`
//  per NestDrop favorite-list slot (1-5), only some of which are populated, each containing
//  `<Preset Name="..."/>` entries with no folder path.
//

import Foundation
import Testing
@testable import Prism

struct MilkdropNestDropFavoritesListTests {
    private func write(_ xml: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).xml")
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func parsesPresetNamesOutOfAPopulatedFavoriteSlot() throws {
        let url = try write("""
        <NestDropSettings>
          <FavoriteList>
            <Favorite1>
              <Preset Name="Waltra - Horizon.milk" />
              <Preset Name="241.milk" />
            </Favorite1>
            <Favorite2 />
            <Favorite3 />
            <Favorite4 />
            <Favorite5 />
          </FavoriteList>
        </NestDropSettings>
        """)

        let names = MilkdropNestDropFavoritesList.presetFilenames(contentsOf: url)
        #expect(names == ["Waltra - Horizon.milk", "241.milk"])
    }

    @Test func collectsNamesAcrossMultiplePopulatedSlots() throws {
        let url = try write("""
        <NestDropSettings>
          <FavoriteList>
            <Favorite1><Preset Name="a.milk" /></Favorite1>
            <Favorite2><Preset Name="b.milk" /></Favorite2>
          </FavoriteList>
        </NestDropSettings>
        """)

        let names = MilkdropNestDropFavoritesList.presetFilenames(contentsOf: url)
        #expect(names == ["a.milk", "b.milk"])
    }

    @Test func emptyFavoriteListReturnsAnEmptySet() throws {
        let url = try write("""
        <NestDropSettings>
          <FavoriteList>
            <Favorite1 />
          </FavoriteList>
        </NestDropSettings>
        """)

        #expect(MilkdropNestDropFavoritesList.presetFilenames(contentsOf: url).isEmpty)
    }

    @Test func unreadableFileReturnsAnEmptySetInsteadOfCrashing() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist.xml")
        #expect(MilkdropNestDropFavoritesList.presetFilenames(contentsOf: missing).isEmpty)
    }

    @Test func malformedXMLReturnsAnEmptySetInsteadOfCrashing() throws {
        let url = try write("<NestDropSettings><FavoriteList><Favorite1>not closed")
        #expect(MilkdropNestDropFavoritesList.presetFilenames(contentsOf: url).isEmpty)
    }
}
