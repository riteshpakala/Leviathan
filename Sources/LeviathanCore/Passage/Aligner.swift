//
//  Aligner.swift
//  LeviathanCore
//
//  WHAT: Lines one sample up against the baseline, token by token: which baseline tokens the
//        sample kept, and where.
//  PIN:  Patience-style. Common prefix and suffix first; then anchors on tokens that occur
//        exactly once in each side of the range, chained by the longest increasing run; then the
//        same inside every gap between anchors; an LCS only where no anchor is left. Common words
//        and commas are rarely unique, so they cannot tie two unrelated sentences together; the
//        passage builder absorbs the few that still match by chance. Iterative, so a long
//        response cannot overflow a task's stack. An LCS over more than `cellCap` cells matches
//        nothing in that gap, so cost stays bounded.
//

import Foundation

public struct Alignment: Sendable, Hashable {
    /// For each baseline token, the sample token it matched, or nil if the sample did not keep it.
    public var map: [Int?]
    public var sampleCount: Int

    public var matched: Int { map.reduce(0) { $0 + ($1 == nil ? 0 : 1) } }

    /// Kept tokens over the longer of the two texts.
    public var overlap: Double {
        let longest = max(map.count, sampleCount)
        return longest == 0 ? 1 : Double(matched) / Double(longest)
    }

    public func kept(_ index: Int) -> Bool { map[index] != nil }

    /// Runs of kept baseline tokens.
    public var keptRuns: [IndexRange] {
        var runs: [IndexRange] = []
        var start: Int?
        for i in map.indices {
            if map[i] != nil {
                if start == nil { start = i }
            } else if let s = start {
                runs.append(IndexRange(s, i))
                start = nil
            }
        }
        if let s = start { runs.append(IndexRange(s, map.count)) }
        return runs
    }
}

/// A half-open range of indices, written as [lower, upper].
public struct IndexRange: Codable, Sendable, Hashable, Comparable {
    public var lower: Int
    public var upper: Int

    public init(_ lower: Int, _ upper: Int) {
        self.lower = lower
        self.upper = upper
    }

    public var range: Range<Int> { lower..<upper }
    public var isEmpty: Bool { lower >= upper }
    public var count: Int { max(0, upper - lower) }

    public func contains(_ other: IndexRange) -> Bool { lower <= other.lower && other.upper <= upper }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        lower = try c.decode(Int.self)
        upper = try c.decode(Int.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(lower)
        try c.encode(upper)
    }

    public static func < (a: IndexRange, b: IndexRange) -> Bool { (a.lower, a.upper) < (b.lower, b.upper) }
}

public enum Aligner {
    public static let defaultCellCap = 4_000_000

    public static func align(baseline: [Token], sample: [Token], cellCap: Int = defaultCellCap) -> Alignment {
        let pairs = matchPairs(baseline.map(\.key), sample.map(\.key), cellCap: cellCap)
        var map = [Int?](repeating: nil, count: baseline.count)
        for (i, j) in pairs { map[i] = j }
        return Alignment(map: map, sampleCount: sample.count)
    }

    private enum Work {
        case range(Int, Int, Int, Int)
        case pair(Int, Int)
    }

    /// Matched (baseline index, sample index) pairs, increasing in both.
    public static func matchPairs<Key: Hashable>(_ a: [Key], _ b: [Key], cellCap: Int = defaultCellCap) -> [(Int, Int)] {
        var output: [(Int, Int)] = []
        var stack: [Work] = [.range(0, a.count, 0, b.count)]
        while let work = stack.popLast() {
            switch work {
            case .pair(let i, let j):
                output.append((i, j))
            case .range(var aLo, var aHi, var bLo, var bHi):
                while aLo < aHi, bLo < bHi, a[aLo] == b[bLo] {
                    output.append((aLo, bLo))
                    aLo += 1
                    bLo += 1
                }
                var suffix: [(Int, Int)] = []
                while aLo < aHi, bLo < bHi, a[aHi - 1] == b[bHi - 1] {
                    suffix.append((aHi - 1, bHi - 1))
                    aHi -= 1
                    bHi -= 1
                }
                var items: [Work] = []
                if aLo < aHi, bLo < bHi {
                    let anchors = uniqueAnchors(a, aLo, aHi, b, bLo, bHi)
                    if !anchors.isEmpty {
                        var pa = aLo
                        var pb = bLo
                        for (i, j) in anchors {
                            items.append(.range(pa, i, pb, j))
                            items.append(.pair(i, j))
                            pa = i + 1
                            pb = j + 1
                        }
                        items.append(.range(pa, aHi, pb, bHi))
                    } else if (aHi - aLo) * (bHi - bLo) <= cellCap {
                        items = lcs(a, aLo, aHi, b, bLo, bHi).map { .pair($0.0, $0.1) }
                    }
                }
                items.append(contentsOf: suffix.reversed().map { .pair($0.0, $0.1) })
                stack.append(contentsOf: items.reversed())
            }
        }
        return output
    }

    /// Tokens unique on both sides of the range, matched, then cut to the longest chain that
    /// increases on both sides.
    static func uniqueAnchors<Key: Hashable>(_ a: [Key], _ aLo: Int, _ aHi: Int, _ b: [Key], _ bLo: Int, _ bHi: Int) -> [(Int, Int)] {
        var countA: [Key: Int] = [:]
        var positionA: [Key: Int] = [:]
        for i in aLo..<aHi {
            countA[a[i], default: 0] += 1
            positionA[a[i]] = i
        }
        var countB: [Key: Int] = [:]
        var positionB: [Key: Int] = [:]
        for j in bLo..<bHi {
            countB[b[j], default: 0] += 1
            positionB[b[j]] = j
        }
        var candidates: [(Int, Int)] = []
        for (key, count) in countA where count == 1 && countB[key] == 1 {
            candidates.append((positionA[key]!, positionB[key]!))
        }
        guard !candidates.isEmpty else { return [] }
        candidates.sort { $0.0 < $1.0 }
        return longestIncreasing(candidates)
    }

    /// The longest subsequence of pairs (already increasing in .0) that also increases in .1.
    static func longestIncreasing(_ pairs: [(Int, Int)]) -> [(Int, Int)] {
        var tails: [Int] = []
        var tailIndex: [Int] = []
        var previous = [Int](repeating: -1, count: pairs.count)
        for (k, pair) in pairs.enumerated() {
            var lo = 0
            var hi = tails.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if tails[mid] < pair.1 { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 { previous[k] = tailIndex[lo - 1] }
            if lo == tails.count {
                tails.append(pair.1)
                tailIndex.append(k)
            } else {
                tails[lo] = pair.1
                tailIndex[lo] = k
            }
        }
        var result: [(Int, Int)] = []
        var k = tailIndex.last ?? -1
        while k >= 0 {
            result.append(pairs[k])
            k = previous[k]
        }
        return result.reversed()
    }

    /// A longest common subsequence of the two ranges.
    static func lcs<Key: Hashable>(_ a: [Key], _ aLo: Int, _ aHi: Int, _ b: [Key], _ bLo: Int, _ bHi: Int) -> [(Int, Int)] {
        let n = aHi - aLo
        let m = bHi - bLo
        let width = m + 1
        var table = [Int32](repeating: 0, count: (n + 1) * width)
        if n > 0, m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    table[i * width + j] = a[aLo + i] == b[bLo + j]
                        ? table[(i + 1) * width + j + 1] + 1
                        : max(table[(i + 1) * width + j], table[i * width + j + 1])
                }
            }
        }
        var pairs: [(Int, Int)] = []
        var i = 0
        var j = 0
        while i < n, j < m {
            if a[aLo + i] == b[bLo + j] {
                pairs.append((aLo + i, bLo + j))
                i += 1
                j += 1
            } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }
}
