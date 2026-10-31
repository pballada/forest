import Foundation

/// A line segment inside one graph row. Columns are lane indexes; `color` indexes a palette.
public struct GraphEdge: Hashable, Sendable {
    public let from: Int
    public let to: Int
    public let color: Int
}

public struct GraphRow: Hashable, Sendable {
    /// Lane holding this commit's node.
    public let column: Int
    public let color: Int
    /// Lanes passing straight through this row without touching the node.
    public let passThrough: [GraphEdge]
    /// Lines from the top edge (`from` lane) into the node.
    public let incoming: [GraphEdge]
    /// Lines from the node to the bottom edge (`to` lane).
    public let outgoing: [GraphEdge]
    public let laneCount: Int
}

public enum GraphLayout {
    /// Assigns lanes to commits listed newest-first in topological order (`git log --date-order`).
    ///
    /// When `head` is given, lane 0 is reserved for it so the checked-out branch's mainline
    /// stays straight down the left edge even when newer commits exist on other branches.
    public static func layout(_ commits: [Commit], head: String? = nil) -> [GraphRow] {
        var lanes: [String?] = []
        var colors: [Int] = []
        var nextColor = 0
        var reserved: String?
        if let head, commits.contains(where: { $0.id == head }) {
            lanes = [head]
            colors = [0]
            nextColor = 1
            reserved = head
        }
        var rows: [GraphRow] = []
        rows.reserveCapacity(commits.count)

        func freeLane(excluding: Int? = nil) -> Int {
            if let index = lanes.indices.first(where: { lanes[$0] == nil && $0 != excluding }) { return index }
            lanes.append(nil)
            colors.append(0)
            return lanes.count - 1
        }

        for commit in commits {
            let before = lanes
            let matching = lanes.indices.filter { lanes[$0] == commit.id }

            let column: Int
            if let first = matching.first {
                column = first
            } else {
                column = freeLane()
                colors[column] = nextColor
                nextColor += 1
            }
            let nodeColor = colors[column]

            // The reserved lane has no child above HEAD, so it draws nothing until HEAD is reached.
            let incoming = matching
                .filter { !(commit.id == reserved && $0 == 0) }
                .map { GraphEdge(from: $0, to: column, color: colors[$0]) }
            if commit.id == reserved { reserved = nil }
            for index in matching { lanes[index] = nil }

            let passThrough = before.indices.compactMap { index -> GraphEdge? in
                guard let sha = before[index], sha != commit.id, sha != reserved else { return nil }
                return GraphEdge(from: index, to: index, color: colors[index])
            }

            var outgoing: [GraphEdge] = []
            for (position, parent) in commit.parents.enumerated() {
                if position == 0 {
                    // The first parent keeps this lane even if another lane also expects it;
                    // duplicate lanes converge where the parent is drawn, keeping mainlines straight.
                    lanes[column] = parent
                    outgoing.append(GraphEdge(from: column, to: column, color: nodeColor))
                } else if let existing = lanes.firstIndex(where: { $0 == parent }) {
                    outgoing.append(GraphEdge(from: column, to: existing, color: colors[existing]))
                } else {
                    let lane = freeLane(excluding: column)
                    lanes[lane] = parent
                    colors[lane] = nextColor
                    nextColor += 1
                    outgoing.append(GraphEdge(from: column, to: lane, color: colors[lane]))
                }
            }

            while let last = lanes.last, last == nil {
                lanes.removeLast()
                colors.removeLast()
            }

            let laneCount = max(before.count, lanes.count, column + 1,
                                (outgoing.map(\.to).max() ?? 0) + 1)
            rows.append(GraphRow(column: column, color: nodeColor, passThrough: passThrough,
                                 incoming: incoming, outgoing: outgoing, laneCount: laneCount))
        }
        return rows
    }
}
