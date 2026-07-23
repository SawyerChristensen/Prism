//
//  Item.swift
//  Prism
//
//  Created by Sawyer Christensen on 7/23/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
