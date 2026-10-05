//
//  SamplingPlan.swift
//  LeviathanCore
//
//  WHAT: Which temperatures to sample and how many times, and the sample points that leaves
//        to request for a model, given what its transcript already holds.
//  PIN:  A temperature outside the model's range is dropped and reported, never sent, so no
//        record carries a temperature the host clamped. A default-only model gets the same
//        number of samples, all at the host's default.
//

import Foundation

public struct SamplingPlan: Codable, Sendable, Hashable {
    public var temperatures: [Double]
    public var samplesPerTemperature: Int
    /// Nil uses the model's own default.
    public var maxTokens: Int?
    public var topP: Double?
    public var seed: Int?

    public static let defaultTemperatures: [Double] = [0, 0.4, 0.8, 1.2]

    public init(temperatures: [Double] = SamplingPlan.defaultTemperatures, samplesPerTemperature: Int = 3, maxTokens: Int? = nil,
                topP: Double? = nil, seed: Int? = nil) {
        self.temperatures = temperatures
        self.samplesPerTemperature = samplesPerTemperature
        self.maxTokens = maxTokens
        self.topP = topP
        self.seed = seed
    }
}

public struct HarvestPoint: Sendable, Hashable {
    public var prompt: Prompt
    public var temperature: Double?
    public var sampleIndex: Int
}

public struct HarvestPlan: Sendable {
    public var pending: [HarvestPoint]
    /// Points already in the transcript.
    public var skipped: Int
    /// Temperatures the model's range excludes.
    public var dropped: [Double]
    public var defaultOnly: Bool

    public var total: Int { pending.count + skipped }

    /// The points to request: every prompt × temperature × sample index not already present.
    public static func make(target: ModelTarget, prompts: [Prompt], plan: SamplingPlan, existing: Set<SampleKey>) -> HarvestPlan {
        let limits = target.sampling
        var temperatures: [Double?]
        var dropped: [Double] = []
        var perTemperature = max(0, plan.samplesPerTemperature)
        let unique = plan.temperatures.reduce(into: [Double]()) { list, t in if !list.contains(where: { abs($0 - t) < 1e-9 }) { list.append(t) } }
        if limits.temperature == .defaultOnly {
            temperatures = [nil]
            perTemperature *= max(1, unique.count)
        } else {
            temperatures = []
            for t in unique.sorted() {
                if limits.accepts(t) { temperatures.append(t) } else { dropped.append(t) }
            }
        }
        var pending: [HarvestPoint] = []
        var skipped = 0
        for prompt in prompts {
            for temperature in temperatures {
                for index in 0..<perTemperature {
                    let key = SampleKey(promptSHA: prompt.sha, temperature: SamplingPoint.key(temperature), sampleIndex: index)
                    if existing.contains(key) {
                        skipped += 1
                    } else {
                        pending.append(HarvestPoint(prompt: prompt, temperature: temperature, sampleIndex: index))
                    }
                }
            }
        }
        return HarvestPlan(pending: pending, skipped: skipped, dropped: dropped, defaultOnly: limits.temperature == .defaultOnly)
    }
}
