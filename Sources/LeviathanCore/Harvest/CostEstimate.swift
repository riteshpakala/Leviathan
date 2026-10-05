//
//  CostEstimate.swift
//  LeviathanCore
//
//  WHAT: What a harvest plan will cost before anything is sent: a worst case, where every
//        answer runs to its token cap and the prompt counts one token per three characters, and
//        a typical case, from what this model's answers have run to before.
//  PIN:  Needs both prices on the model; without them the cost is unknown and says so. A
//        reasoning model's thinking is billed as output and counts against the token cap, so the
//        cap bounds it too.
//

import Foundation

public struct CostEstimate: Codable, Sendable, Hashable {
    public var requests: Int
    public var inputTokens: Int
    public var worstOutputTokens: Int
    public var typicalOutputTokens: Int
    /// Dollars; nil when the model has no prices.
    public var worst: Double?
    public var typical: Double?
    /// Where the typical output length came from.
    public var basis: String

    public static func make(plan: HarvestPlan, target: ModelTarget, sampling: SamplingPlan, history: [TranscriptRecord]) -> CostEstimate {
        let cap = sampling.maxTokens ?? target.sampling.maxTokens
        let characters = plan.pending.map { point in point.prompt.messages.reduce(0) { $0 + $1.content.count } }
        let worstInput = characters.reduce(0) { $0 + ($1 + 2) / 3 }
        let typicalInput = characters.reduce(0) { $0 + ($1 + 3) / 4 }
        let seen = history.compactMap { $0.usage?.completionTokens }
        let perAnswer = seen.isEmpty ? cap / 3 : min(cap, seen.reduce(0, +) / seen.count)
        let basis = seen.isEmpty ? "a third of the token cap, as nothing was harvested from this model yet"
            : "the mean of \(seen.count) earlier answer\(seen.count == 1 ? "" : "s") from this model"
        let requests = plan.pending.count
        return CostEstimate(
            requests: requests, inputTokens: worstInput, worstOutputTokens: requests * cap, typicalOutputTokens: requests * perAnswer,
            worst: target.pricing?.cost(input: worstInput, output: requests * cap),
            typical: target.pricing?.cost(input: typicalInput, output: requests * perAnswer), basis: basis)
    }

    /// "about $0.42, at most $1.30", or a note that the prices are unknown.
    public var summary: String {
        guard let worst, let typical else { return "cost unknown: the model has no prices (leviathan models add … --input-price --output-price)" }
        return "about \(KeyStatus.dollars(typical)), at most \(KeyStatus.dollars(worst))"
    }
}
