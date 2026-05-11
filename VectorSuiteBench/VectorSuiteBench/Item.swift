//
//  Item.swift
//  VectorSuiteBench
//
//  Created by Gifton Okoronkwo on 5/10/26.
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
