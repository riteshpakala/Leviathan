//
//  Harvester.swift
//  LeviathanCore
//
//  WHAT: Runs a harvest plan against one model: requests in flight up to the provider's limit,
//        each success appended to the transcript as it arrives, progress reported as it goes.
//  PIN:  It stops, and says why, rather than carry on into a wall: when the host rejects the
//        temperature (the model should be default-only), when it answers with any other error
//        that retrying cannot fix (a bad key, an unknown model), after three requests in a
//        row run out of retries, once the spend the host reports reaches the run's limit, or
//        after five refusals. A refusal is recorded as it came and never asked again: no prompt
//        is reworded to get past one. What completed before the stop is kept.
//        The raw response is kept without its logprobs block, which the record already holds.
//

import Foundation

public enum HarvestEvent: Sendable {
    case completed(promptID: String, temperature: Double?, sampleIndex: Int, completionTokens: Int?)
    case failed(promptID: String, temperature: Double?, sampleIndex: Int, message: String)
}

public struct HarvestStop: Codable, Sendable, Hashable {
    public var message: String
    public var hint: String?
    public var code: Int32
}

public struct HarvestSummary: Codable, Sendable {
    public var runID: String
    public var model: String
    public var set: String
    public var planned: Int
    public var skipped: Int
    public var requested: Int
    public var completed: Int
    public var failed: Int
    public var dropped: [Double]
    public var defaultOnly: Bool
    public var promptTokens: Int
    public var completionTokens: Int
    /// Answers the host refused or filtered.
    public var refused: Int = 0
    /// Dollars, from the host's token counts and the model's prices; nil without prices.
    public var spent: Double?
    public var stop: HarvestStop?
}

extension ChatCompletion {
    /// The host declined to answer: a refusal, or its content filter.
    public var isRefusal: Bool { Harvester.refusalReasons.contains(finishReason ?? "") }
}

public struct Harvester: Sendable {
    public let target: ModelTarget
    public let provider: Provider
    public let set: PromptSet
    public let client: any ChatClient
    public let store: TranscriptStore

    public init(target: ModelTarget, provider: Provider, set: PromptSet, client: any ChatClient, store: TranscriptStore) {
        self.target = target
        self.provider = provider
        self.set = set
        self.client = client
        self.store = store
    }

    public static func newRunID(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: now) + "-" + String(UUID().uuidString.lowercased().prefix(6))
    }

    func request(for point: HarvestPoint, plan: SamplingPlan) -> ChatRequest {
        ChatRequest(
            model: target.requestModel, messages: point.prompt.messages, temperature: point.temperature, topP: plan.topP, seed: plan.seed,
            maxTokens: plan.maxTokens ?? target.sampling.maxTokens, maxTokensField: target.sampling.maxTokensField,
            logprobs: target.sampling.logprobs, topLogprobs: target.sampling.logprobs ? 5 : nil)
    }

    func record(_ completion: ChatCompletion, point: HarvestPoint, request: ChatRequest, runID: String) -> TranscriptRecord {
        var rawResponse = completion.rawResponse
        if case .object(var object) = rawResponse, case .array(var choices) = object["choices"] ?? .null {
            for i in choices.indices {
                if case .object(var choice) = choices[i], choice["logprobs"] != nil {
                    choice["logprobs"] = nil
                    choices[i] = .object(choice)
                }
            }
            object["choices"] = .array(choices)
            rawResponse = .object(object)
        }
        return TranscriptRecord(
            id: UUID().uuidString.lowercased(), createdAt: Date(), runID: runID, pack: set.id,
            task: TranscriptTask(promptID: point.prompt.id, promptSHA: point.prompt.sha, messages: point.prompt.messages),
            teacher: Teacher(company: target.company, modelID: target.modelID, provider: provider.id, baseURL: provider.baseURL,
                             requestModel: target.requestModel, reportedModel: completion.reportedModel),
            sampling: SamplingPoint(temperature: point.temperature, topP: request.topP, maxTokens: request.maxTokens, seed: request.seed,
                                    sampleIndex: point.sampleIndex),
            response: completion.content, trace: completion.reasoning, finishReason: completion.finishReason, usage: completion.usage,
            latencyMS: completion.latencyMS, logprobs: completion.logprobs, verification: nil, judge: nil,
            lineage: Lineage(synthesisMethod: "manual", seedID: "\(set.id)/\(point.prompt.id)", trainingUse: target.terms.trainingUse,
                             licence: target.terms.licence),
            raw: RawExchange(request: completion.rawRequest, response: rawResponse))
    }

    private enum Outcome: Sendable {
        case success(HarvestPoint, ChatCompletion, ChatRequest)
        case failure(HarvestPoint, ChatError)
    }

    public static let refusalReasons: Set<String> = ["refusal", "content_filter"]
    public static let refusalLimit = 5

    /// Runs the plan. `maxSpend` (dollars) stops launching requests once the reported spend reaches it.
    public func run(_ plan: HarvestPlan, sampling: SamplingPlan, runID: String, maxSpend: Double? = nil,
                    onEvent: @escaping @Sendable (HarvestEvent) -> Void = { _ in }) async throws -> HarvestSummary {
        var summary = HarvestSummary(
            runID: runID, model: target.ref.description, set: set.id, planned: plan.total, skipped: plan.skipped, requested: 0,
            completed: 0, failed: 0, dropped: plan.dropped, defaultOnly: plan.defaultOnly, promptTokens: 0, completionTokens: 0, stop: nil)
        let client = self.client
        let width = max(1, provider.maxConcurrent)
        var consecutiveExhausted = 0

        do {
            try await withThrowingTaskGroup(of: Outcome.self) { group in
                var queue = plan.pending[...]
                func launch() {
                    guard let point = queue.popFirst() else { return }
                    let request = request(for: point, plan: sampling)
                    summary.requested += 1
                    group.addTask {
                        do {
                            return .success(point, try await client.complete(request), request)
                        } catch let error as ChatError {
                            return .failure(point, error)
                        }
                    }
                }
                for _ in 0..<width { launch() }

                while let outcome = try await group.next() {
                    switch outcome {
                    case .success(let point, let completion, let request):
                        consecutiveExhausted = 0
                        try await store.append(record(completion, point: point, request: request, runID: runID))
                        summary.completed += 1
                        summary.promptTokens += completion.usage?.promptTokens ?? 0
                        summary.completionTokens += completion.usage?.completionTokens ?? 0
                        if let cost = target.pricing?.cost(input: completion.usage?.promptTokens ?? 0, output: completion.usage?.completionTokens ?? 0) {
                            summary.spent = (summary.spent ?? 0) + cost
                        }
                        onEvent(.completed(promptID: point.prompt.id, temperature: point.temperature, sampleIndex: point.sampleIndex,
                                           completionTokens: completion.usage?.completionTokens))
                        if completion.isRefusal {
                            summary.refused += 1
                            if summary.refused >= Self.refusalLimit, summary.stop == nil {
                                summary.stop = HarvestStop(
                                    message: "\(target.requestModel) declined \(summary.refused) prompts in this run",
                                    hint: "the refusals are recorded and set aside; read them before running this set again",
                                    code: LeviathanFailure.ExitCode.noPermission)
                            }
                        }
                        if let maxSpend, let spent = summary.spent, spent >= maxSpend, summary.stop == nil {
                            summary.stop = HarvestStop(
                                message: "the spend reported so far, \(KeyStatus.dollars(spent)), reached the limit of \(KeyStatus.dollars(maxSpend))",
                                hint: "what completed is kept; raise --max-cost and run again to fill the gaps",
                                code: LeviathanFailure.ExitCode.tempFail)
                        }
                    case .failure(let point, let error):
                        summary.failed += 1
                        onEvent(.failed(promptID: point.prompt.id, temperature: point.temperature, sampleIndex: point.sampleIndex,
                                        message: error.description))
                        if case .exhausted = error { consecutiveExhausted += 1 } else { consecutiveExhausted = 0 }
                        if summary.stop == nil { summary.stop = stop(for: error, consecutiveExhausted: consecutiveExhausted) }
                    }
                    // After a stop, drain what is already in flight (it is paid for) and send nothing new.
                    if summary.stop == nil { launch() }
                }
            }
        } catch {
            await store.close()
            throw error
        }
        await store.close()
        return summary
    }

    /// Whether a failure should stop the run, and what to tell the person running it.
    func stop(for error: ChatError, consecutiveExhausted: Int) -> HarvestStop? {
        if error.rejectsTemperature {
            return HarvestStop(
                message: "\(provider.id) rejected the temperature for \(target.requestModel): \(error)",
                hint: "if the model takes no temperature, mark it default-only: leviathan models add … --default-only",
                code: LeviathanFailure.ExitCode.config)
        }
        if case .exhausted = error {
            guard consecutiveExhausted >= 3 else { return nil }
            return HarvestStop(message: "three requests in a row ran out of retries; last: \(error)",
                               hint: "the host may be down or rate limiting; run again later to fill the gaps",
                               code: LeviathanFailure.ExitCode.tempFail)
        }
        return HarvestStop(message: "\(provider.id) refused the request: \(error)",
                           hint: "check the key, the model id and the base URL (leviathan providers test \(provider.id))",
                           code: LeviathanFailure.ExitCode.unavailable)
    }
}
