//
//  MilkdropNestDropFavoritesList.swift
//  Prism
//
//  Parses a NestDrop "bundle" XML export's <FavoriteList> into the set of preset filenames it
//  names (`User Profile/*.xml` in a NestDrop-exported preset pack, e.g.
//  ~/Desktop/BestMilkdropPresetsPack/User Profile/Default NestDrop Bundle.xml`). NestDrop
//  (a Milkdrop-preset VJ app) records favorites by filename only, no folder path — safe to match
//  that way here since the real corpus this targets has zero duplicate filenames across its
//  ~9,795 files (checked directly, not assumed).
//

import Foundation

enum MilkdropNestDropFavoritesList {
    /// Every filename referenced by any `<FavoriteN><Preset Name="..."/></FavoriteN>` block in a
    /// NestDrop bundle XML file — `Favorite1`-`Favorite5` are NestDrop's 5 fixed favorite-list
    /// slots, only some of which are necessarily populated. Returns an empty set (not an error)
    /// for a bundle with nothing favorited, or if the file can't be read/parsed at all.
    static func presetFilenames(contentsOf url: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.filenames
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var filenames: Set<String> = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            guard elementName == "Preset", let name = attributeDict["Name"] else { return }
            filenames.insert(name)
        }
    }
}
