//
//  FeaturedMemoryNode.swift
//  Holo
//
//  精选记忆节点（里程碑/高光），featuredStoriesSection「可回看的片段」消费。
//  从 MemoryConstellationModels.swift 迁出（P1C 删星图时保留此非星图专属类型）。
//

import Foundation

struct FeaturedMemoryNode: Identifiable {
    let section: TimelineSection
    let node: MemoryTimelineNode

    var id: UUID { node.id }
}
