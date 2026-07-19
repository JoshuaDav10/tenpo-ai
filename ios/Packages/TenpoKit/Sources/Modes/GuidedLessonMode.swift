import Foundation
import CoreModels
import ModeEngine
import ContentKit
import SpeechKit
import RealtimeKit

/// Mode 12-adjacent: the conducted voice lesson (SESSION_DESIGN.md, all four acts).
/// The session is the CONDUCTOR: it walks a LessonScript step by step, tells the
/// realtime AI exactly what to do each beat (via server-side templates, §7), opens
/// the mic only when a learner turn is expected, grades what comes back, and never
/// advances on noise. Runs through SessionRunner like every mode → persistence
/// (R12) + FSRS/error commits (R8) for free.
public struct GuidedLessonMode: LearningMode {
    public static let descriptor = ModeDescriptor(
        id: "lesson.guided",
        name: "Guided Lesson",
        dimensions: [.productionSpoken, .recognitionListening],
        needsRealtime: true,
        needsNetwork: true,
        supportedBands: ["N5"]
    )

    private let context: ModeContext
    private let audio: VoiceAudioIO
    private let timing: LessonTiming

    public init(context: ModeContext) {
        self.init(context: context, audio: VoiceAudioIO())
    }

    public init(context: ModeContext, audio: VoiceAudioIO, timing: LessonTiming = .live) {
        self.context = context
        self.audio = audio
        self.timing = timing
    }

    public func makeSession(plan: SessionPlan) -> any ModeSession {
        GuidedLessonSession(context: context, plan: plan, audio: audio, timing: timing)
    }
}

/// Injectable waits so tests run in milliseconds.
public struct LessonTiming: Sendable {
    /// Max wait for a transcript after the learner's endpoint (transcription lags VAD).
    public var transcriptAfterEndpoint: TimeInterval
    /// Max wait for the learner to say anything at all before a gentle re-prompt.
    public var learnerPatience: TimeInterval

    public static let live = LessonTiming(transcriptAfterEndpoint: 4, learnerPatience: 30)
    public init(transcriptAfterEndpoint: TimeInterval, learnerPatience: TimeInterval) {
        self.transcriptAfterEndpoint = transcriptAfterEndpoint
        self.learnerPatience = learnerPatience
    }
}

final class GuidedLessonSession: ModeSession, @unchecked Sendable {
    nonisolated let events: AsyncStream<ModeEvent>
    private let continuation: AsyncStream<ModeEvent>.Continuation

    private let context: ModeContext
    private let plan: SessionPlan
    private let audio: VoiceAudioIO
    private let timing: LessonTiming

    // Serialized on `queue` (the conductor is event-driven, not thread-hot).
    private let queue = DispatchQueue(label: "lesson.conductor")
    private var loop = VoiceLoop(policy: .conducted)
    private var session: (any RealtimeSession)?
    private var script: LessonScript?
    private var steps: [LessonStep] = []
    private var stepIndex = -1
    private var phase: Phase = .idle
    private var transition: String?          // "correct"/"struggled" folded into next step
    private var attempt = 0                  // per-step correction attempts
    private var noiseRetries = 0
    private var learnerPCM = Data()          // current learner turn, for pron grading
    private var collectPCM = false
    private var reviews: [ReviewEvent] = []
    private var errors: [ErrorEvent] = []
    private var struggles: [String] = []     // target phrases that needed retries
    private var repeatsPassed = 0
    private var repeatsTotal = 0
    private var roleplay: RoleplayEngine?
    private var roleplayTurns = 0
    private var roleplayCap = 6
    private var roleplayOutcome: RoleplayOutcome?
    private var quitRequested = false
    private var ended = false
    private var pumpTask: Task<Void, Never>?
    private var micTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    private enum Phase {
        case idle
        case delivering(thenLearner: Bool)   // AI speaking a step; open mic after?
        case awaitingLearner                 // mic open, waiting for endpoint+transcript
        case awaitingTranscript              // endpointed; transcript may lag
        case roleplayDelivering
        case roleplayAwaiting
        case wrapDelivering
        case done
    }

    init(context: ModeContext, plan: SessionPlan, audio: VoiceAudioIO, timing: LessonTiming) {
        self.context = context
        self.plan = plan
        self.audio = audio
        self.timing = timing
        var cont: AsyncStream<ModeEvent>.Continuation!
        self.events = AsyncStream { cont = $0 }
        self.continuation = cont
    }

    // MARK: - ModeSession

    func start() async {
        guard let scriptItem = plan.items.first(where: { $0.kind == .lesson }),
              let script = LessonScript(scriptItem) else {
            continuation.yield(.info("No lesson content available."))
            finishStream(abandoned: true)
            return
        }
        guard let realtime = context.realtime else {
            continuation.yield(.info("Voice lessons need the live connection."))
            finishStream(abandoned: true)
            return
        }

        var steps = script.steps
        // Act 1 weaving: returning learners get their weak items as extra repeats,
        // inserted before the roleplay so the scene can then demand them.
        if let weak = try? await context.learner.weakItems(bandPrefix: String(script.band.prefix(2)), count: 2),
           !weak.isEmpty {
            let woven = weak.map { item -> LessonStep in
                let fields = VocabFields(item)
                return .modelAndRepeat(LessonStep.Repeat(
                    target: fields.lemma,
                    reading: fields.reading,
                    glossEN: fields.glosses.joined(separator: ", "),
                    accepted: [fields.lemma, fields.reading].compactMap { $0 },
                    itemRef: item.id))
            }
            let insertAt = steps.firstIndex {
                if case .miniRoleplay = $0 { return true }
                if case .wrap = $0 { return true }
                return false
            } ?? steps.endIndex
            steps.insert(contentsOf: woven, at: insertAt)
        }

        do {
            let session = try await realtime.openSession(RealtimeConfig(
                actorTemplateID: "lesson", variables: [:],
                voice: VoiceID(rawValue: "alloy"), locale: LanguageID(rawValue: "ja"),
                mode: "lesson"))
            queue.sync {
                self.script = script
                self.steps = steps
                self.session = session
            }
            startPumps(session)
            continuation.yield(.info(script.title))
            continuation.yield(.progress(current: 0, total: steps.count))
            advance()
        } catch {
            continuation.yield(.info("Couldn't open the voice session."))
            finishStream(abandoned: true)
        }
    }

    func handle(_ input: LearnerInput) async {
        switch input {
        case .tap:
            let actions = queue.sync { loop.tapInterrupt() }
            apply(actions)
            if !actions.isEmpty {
                try? await queue.sync { session }?.interrupt()
                // The floor is the learner's now; treat it like an opened mic turn.
                queue.sync { if case .delivering = phase { phase = .awaitingLearner } }
                armPatienceTimeout()
            }
        case .text(let typed):
            // Dev/simulator path: a typed line IS the learner transcript.
            learnerSaid(typed)
        case .requestHint:
            sendHintStep()
        case .quit:
            queue.sync { quitRequested = true }
            beginWrap(interrupted: true)
        case .speech:
            break // live audio rides VoiceAudioIO, not LearnerInput
        }
    }

    func finish() async -> ModeResult {
        let (reviews, errors, abandoned) = queue.sync { (self.reviews, self.errors, self.quitRequested) }
        let score: JSONValue = queue.sync {
            .object([
                "repeats_passed": .number(Double(repeatsPassed)),
                "repeats_total": .number(Double(repeatsTotal)),
                "praise_allowed": .bool(praiseAllowed()),
            ])
        }
        await teardown()
        return ModeResult(
            reviews: reviews, errors: errors,
            status: abandoned ? .abandoned : .completed,
            score: score, duration: 0)
    }

    // MARK: - pumps

    private func startPumps(_ session: any RealtimeSession) {
        pumpTask = Task { [weak self] in
            for await event in session.events {
                self?.handleWire(event)
            }
        }
        micTask = Task { [weak self] in
            guard let stream = self?.audio.micChunks else { return }
            for await chunk in stream {
                guard let self else { return }
                let (forward, collect) = self.queue.sync { (self.loop.shouldForwardMicAudio, self.collectPCM) }
                if forward {
                    if collect { self.queue.sync { self.learnerPCM.append(chunk.data) } }
                    try? await self.queue.sync { self.session }?.send(audio: chunk)
                }
            }
        }
    }

    private func handleWire(_ event: RealtimeEvent) {
        // Learner transcripts route to the conductor, everything else to the loop.
        if case .partialTranscript(let role, let text) = event, role == .learner {
            learnerSaid(text)
            return
        }
        if case .userSpeechStopped = event {
            let relevant = queue.sync { if case .awaitingLearner = phase { return true } else { return false } }
            if relevant {
                queue.sync { phase = .awaitingTranscript }
                armTranscriptTimeout()
            }
        }
        if case .proxyRefused(let code, let fallback) = event {
            continuation.yield(.info(fallback
                ? "Today's voice budget is used — continue this lesson in text mode from the Roleplay tab."
                : "Voice session refused (\(code))."))
            finishStream(abandoned: true)
            return
        }
        if case .error(let message) = event {
            continuation.yield(.info("Voice session ended: \(message)"))
            finishStream(abandoned: true)
            return
        }

        let actions = queue.sync { loop.handle(event) }
        apply(actions)
    }

    private func apply(_ actions: [VoiceLoopAction]) {
        var said: String?
        var turnEnded = false
        for action in actions {
            switch action {
            case .play(let buffer): audio.emit(.play(buffer))
            case .stopPlayback: audio.emit(.stop)
            case .state(let state):
                audio.emit(.state(state))
                // In conducted policy an assistant turn always lands in .thinking.
                if state == .thinking { turnEnded = true }
            case .assistantSaid(let text):
                continuation.yield(.prompt(text: text, audio: nil))
                said = text
                turnEnded = true
            case .learnerSaid, .fallbackToCascade, .failed:
                break // handled in handleWire / conductor
            }
        }
        // Hand the floor off only after every emission above is out, so the orb
        // never shows a stale state after openMic flips to listening.
        if turnEnded { assistantTurnFinished(said) }
    }

    // MARK: - the conductor

    /// AI finished speaking a step. Either open the mic (learner's beat) or chain
    /// the next step (framing beats).
    private func assistantTurnFinished(_ text: String?) {
        let next: (() -> Void)? = queue.sync {
            switch phase {
            case .delivering(let thenLearner):
                if thenLearner {
                    phase = .awaitingLearner
                    let actions = loop.openMic()
                    return { [weak self] in
                        self?.apply(actions)
                        self?.armPatienceTimeout()
                        self?.beginPCMCapture()
                    }
                }
                return { [weak self] in self?.advance() }
            case .roleplayDelivering:
                if let text { roleplay.map { engine in Task { await engine.seedActorTurn(text) } } }
                phase = .roleplayAwaiting
                let actions = loop.openMic()
                return { [weak self] in
                    self?.apply(actions)
                    self?.armPatienceTimeout()
                    self?.beginPCMCapture()
                }
            case .wrapDelivering:
                return { [weak self] in self?.finishStream(abandoned: false) }
            default:
                return nil
            }
        }
        next?()
    }

    /// Move to the next step and deliver it.
    private func advance() {
        let directive: LessonStepDirective? = queue.sync {
            stepIndex += 1
            guard stepIndex < steps.count else {
                return nil
            }
            continuation.yield(.progress(current: stepIndex, total: steps.count))
            attempt = 0
            noiseRetries = 0
            return directiveForCurrentStep()
        }
        if let directive {
            deliver(directive)
        } else {
            beginWrap(interrupted: false)
        }
    }

    /// Build the wire directive for steps[stepIndex] and set phase/card state.
    private func directiveForCurrentStep() -> LessonStepDirective? {
        guard let script else { return nil }
        let t = transition
        transition = nil
        var vars: [String: JSONValue] = [:]
        if let t { vars["transition"] = .string(t) }

        switch steps[stepIndex] {
        case .explain(let focus):
            phase = .delivering(thenLearner: false)
            vars["topic_en"] = .string(script.topicEN)
            vars["focus_en"] = .string(focus)
            if stepIndex == 0 { vars["first"] = .bool(true) }
            return LessonStepDirective(kind: "lesson.explain", variables: vars)

        case .modelAndRepeat(let rep):
            phase = .delivering(thenLearner: true)
            let ruby = rep.reading ?? context.pack.reading(for: rep.target)
                .map { $0.segments.map { $0.ruby ?? $0.base }.joined() }
            continuation.yield(.card(text: rep.target, reading: ruby, gloss: rep.glossEN))
            vars["target"] = .string(rep.target)
            if let reading = rep.reading { vars["reading"] = .string(reading) }
            vars["gloss_en"] = .string(rep.glossEN)
            return LessonStepDirective(kind: "lesson.model_repeat", variables: vars)

        case .promptResponse(let probe):
            phase = .delivering(thenLearner: true)
            continuation.yield(.card(text: probe.questionJP, reading: nil, gloss: probe.expectationEN))
            vars["question_jp"] = .string(probe.questionJP)
            if let expectation = probe.expectationEN { vars["expectation_en"] = .string(expectation) }
            return LessonStepDirective(kind: "lesson.prompt_response", variables: vars)

        case .miniRoleplay(let cap, _):
            roleplayCap = cap
            roleplayTurns = 0
            let scenario = scenarioForRoleplay()
            roleplay = RoleplayEngine(scenario: scenario,
                                      director: context.director ?? StubDirector(),
                                      sessionID: plan.sessionID)
            phase = .roleplayDelivering
            if let engine = roleplay {
                Task { [continuation] in
                    let progress = await engine.progress()
                    continuation.yield(.goalProgress(completed: progress.completed, total: progress.total))
                }
            }
            vars["setting"] = .string(scenario.setting)
            vars["persona_hint"] = .string(scenario.personaHint ?? "")
            vars["register"] = .string(scenario.register)
            vars["band"] = .string(scenario.band)
            return LessonStepDirective(kind: "lesson.roleplay_open", variables: vars)

        case .wrap:
            return nil // handled by beginWrap via advance()
        }
    }

    private func deliver(_ directive: LessonStepDirective) {
        let isWrapStep = queue.sync { () -> Bool in
            if stepIndex < steps.count, case .wrap = steps[stepIndex] { return true }
            return false
        }
        if isWrapStep {
            beginWrap(interrupted: false)
            return
        }
        Task { [weak self] in
            guard let session = self?.queue.sync(execute: { self?.session }) else { return }
            try? await session.send(step: directive)
        }
    }

    /// A learner transcript arrived (voice or typed). Route by phase.
    private func learnerSaid(_ raw: String) {
        cancelTimeout()
        endPCMCapture()
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        continuation.yield(.heard(Transcription(text: text, confidence: 1.0, alternatives: [], provider: ProviderID(rawValue: "realtime"))))

        let route: (() -> Void)? = queue.sync {
            switch phase {
            case .awaitingLearner, .awaitingTranscript:
                phase = .idle
                return { [weak self] in self?.gradeCurrentStep(text) }
            case .roleplayAwaiting:
                phase = .idle
                return { [weak self] in self?.roleplayTurn(text) }
            default:
                return nil
            }
        }
        route?()
    }

    // MARK: - grading (D-E: transcript fast-path, honest grader on mismatch, noise never advances)

    private func gradeCurrentStep(_ text: String) {
        // Noise/empty: re-prompt, no grade, no advance.
        guard context.pack.normalizeAnswer(text).count >= 2 else {
            noiseReprompt()
            return
        }
        let step = queue.sync { steps[stepIndex] }
        switch step {
        case .modelAndRepeat(let rep): gradeRepeat(rep, heard: text)
        case .promptResponse(let probe): gradeProbe(probe, heard: text)
        default: break
        }
    }

    private func gradeRepeat(_ rep: LessonStep.Repeat, heard: String) {
        queue.sync { if attempt == 0 { repeatsTotal += 1 } }
        let matched = context.pack.answersMatch(heard, rep.accepted).isMatch
        if matched {
            recordPass(rep)
            queue.sync { transition = "correct" }
            advance()
            return
        }
        // Transcript mismatched — second opinion via the honest grader (R6) using
        // the captured turn audio when we have it.
        let clip = queue.sync { learnerPCM.isEmpty ? nil : AudioClip(data: learnerPCM, encoding: .pcm16, sampleRate: 24000) }
        Task { [weak self] in
            guard let self else { return }
            var passed = false
            if let clip {
                let item = GradableItem(
                    itemID: rep.itemRef ?? ItemID(rawValue: "lesson:step"),
                    acceptedAnswers: rep.accepted, canonical: rep.target,
                    isPronunciationGraded: rep.pronGraded, pronThreshold: rep.pronThreshold)
                let attemptNo = self.queue.sync { self.attempt }
                if let outcome = try? await self.context.speech.grade(
                    audio: clip, item: item, attempt: attemptNo, locale: self.context.pack.id),
                   case .pass = outcome {
                    passed = true
                }
            }
            if passed {
                self.recordPass(rep)
                self.queue.sync { self.transition = "correct" }
                self.advance()
            } else {
                self.repeatFailed(rep, heard: heard)
            }
        }
    }

    private func repeatFailed(_ rep: LessonStep.Repeat, heard: String) {
        let exhausted = queue.sync { () -> Bool in
            attempt += 1
            return attempt > 2
        }
        if exhausted {
            // Never blocks (R4 spirit): log honestly and move on.
            record(rep, grade: .again, heard: heard)
            queue.sync {
                struggles.append(rep.target)
                transition = "struggled"
            }
            advance()
        } else {
            if let ref = rep.itemRef {
                continuation.yield(.verdict(itemID: ref, grade: .again, diff: "\(heard) → \(rep.target)"))
            }
            queue.sync { phase = .delivering(thenLearner: true) }
            deliver(LessonStepDirective(kind: "lesson.correct_retry", variables: [
                "heard": .string(heard),
                "target": .string(rep.target),
                "reading": .string(rep.reading ?? ""),
            ]))
        }
    }

    private func gradeProbe(_ probe: LessonStep.Probe, heard: String) {
        let normalized = context.pack.normalizeAnswer(heard)
        let hit = probe.expectedPatterns.isEmpty
            || probe.expectedPatterns.contains { normalized.contains(context.pack.normalizeAnswer($0)) }
        if hit {
            for ref in probe.itemRefs {
                let review = ReviewEvent(itemID: ref, dimension: .productionSpoken,
                                         grade: .good, modeID: GuidedLessonMode.descriptor.id,
                                         sessionID: plan.sessionID)
                queue.sync { reviews.append(review) }
            }
            queue.sync { transition = "correct" }
            advance()
            return
        }
        let exhausted = queue.sync { () -> Bool in
            attempt += 1
            return attempt > 1
        }
        if exhausted {
            for ref in probe.itemRefs {
                let error = ErrorEvent(sessionID: plan.sessionID, itemID: ref,
                                       category: .grammar, surface: heard,
                                       expected: probe.expectationEN)
                queue.sync { errors.append(error) }
            }
            queue.sync {
                struggles.append(probe.questionJP)
                transition = "struggled"
            }
            advance()
        } else {
            queue.sync { phase = .delivering(thenLearner: true) }
            deliver(LessonStepDirective(kind: "lesson.hint", variables: [
                "hint_en": .string(probe.hintEN ?? ""),
            ]))
        }
    }

    private func recordPass(_ rep: LessonStep.Repeat) {
        queue.sync { repeatsPassed += 1 }
        record(rep, grade: queue.sync { attempt } == 0 ? .good : .hard, heard: nil)
    }

    private func record(_ rep: LessonStep.Repeat, grade: ReviewGrade, heard: String?) {
        guard let ref = rep.itemRef else { return }
        let review = ReviewEvent(itemID: ref, dimension: .productionSpoken, grade: grade,
                                 modeID: GuidedLessonMode.descriptor.id, sessionID: plan.sessionID)
        queue.sync { reviews.append(review) }
        continuation.yield(.verdict(itemID: ref, grade: grade, diff: heard.map { "\($0) → \(rep.target)" }))
        if grade == .again {
            let error = ErrorEvent(sessionID: plan.sessionID, itemID: ref,
                                   category: rep.pronGraded ? .pronunciation : .vocab,
                                   surface: heard, expected: rep.target)
            queue.sync { errors.append(error) }
        }
    }

    private func noiseReprompt() {
        let target: String? = queue.sync {
            noiseRetries += 1
            phase = .delivering(thenLearner: true)
            if case .modelAndRepeat(let rep) = steps[stepIndex] { return rep.target }
            return nil
        }
        var vars: [String: JSONValue] = [:]
        if let target { vars["target"] = .string(target) }
        deliver(LessonStepDirective(kind: "lesson.reprompt", variables: vars))
    }

    private func sendHintStep() {
        let hint: String? = queue.sync {
            guard stepIndex >= 0, stepIndex < steps.count,
                  case .promptResponse(let probe) = steps[stepIndex] else { return nil }
            phase = .delivering(thenLearner: true)
            return probe.hintEN ?? probe.expectationEN
        }
        guard let hint else { return }
        deliver(LessonStepDirective(kind: "lesson.hint", variables: ["hint_en": .string(hint)]))
    }

    // MARK: - roleplay act (Act 3 — R1/R3/R4/R8/R15 via the tested engine)

    private func roleplayTurn(_ text: String) {
        guard let engine = queue.sync(execute: { roleplay }) else {
            advance()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let directive = await engine.processLearnerTurn(text)
            let progress = await engine.progress()
            self.continuation.yield(.goalProgress(completed: progress.completed, total: progress.total))
            let turns = self.queue.sync { () -> Int in
                self.roleplayTurns += 1
                return self.roleplayTurns
            }
            switch directive {
            case .endScene:
                await self.endRoleplay(engine)
            case .injectHelp(_, let kind):
                if turns >= self.queue.sync(execute: { self.roleplayCap }) {
                    await self.endRoleplay(engine)
                } else {
                    self.queue.sync { self.phase = .roleplayDelivering }
                    self.deliver(LessonStepDirective(kind: "lesson.roleplay_help", variables: [
                        "kind": .string(String(describing: kind)),
                    ]))
                }
            case .continue(let actorDirective):
                if turns >= self.queue.sync(execute: { self.roleplayCap }) {
                    await self.endRoleplay(engine)
                } else {
                    self.queue.sync { self.phase = .roleplayDelivering }
                    var vars: [String: JSONValue] = [:]
                    if let actorDirective { vars["directive"] = .string(actorDirective) }
                    self.deliver(LessonStepDirective(kind: "lesson.roleplay_turn", variables: vars))
                }
            }
        }
    }

    private func endRoleplay(_ engine: RoleplayEngine) async {
        let outcome = await engine.finalize()
        queue.sync {
            roleplayOutcome = outcome
            reviews.append(contentsOf: outcome.reviews)
            errors.append(contentsOf: outcome.errors)
        }
        advance()
    }

    private func scenarioForRoleplay() -> Scenario {
        if let item = plan.items.first(where: { $0.kind == .scenario }),
           let scenario = Scenario(item) {
            return scenario
        }
        return Scenario(id: "scenario:lesson_fallback", title: "会話練習",
                        register: "polite", band: "N5.1",
                        setting: "Friendly conversation practice.",
                        personaHint: "friendly conversation partner",
                        goals: [], complicationPool: [], seedWeakItems: false)
    }

    // MARK: - wrap (Act 4)

    private func beginWrap(interrupted: Bool) {
        let vars: [String: JSONValue] = queue.sync {
            guard !ended else { return [:] }
            phase = .wrapDelivering
            var vars: [String: JSONValue] = [
                "praise_allowed": .bool(praiseAllowed()),
            ]
            if let outcome = roleplayOutcome {
                let progress = outcome.missingRequiredGoals.isEmpty
                vars["goals_completed"] = .number(Double(progress ? outcome.reviews.count : 0))
            }
            if !struggles.isEmpty {
                vars["struggles"] = .array(struggles.map { .string($0) })
            }
            if interrupted { vars["transition"] = .string("struggled") }
            return vars
        }
        guard !vars.isEmpty || !queue.sync(execute: { ended }) else { return }
        deliver(LessonStepDirective(kind: "lesson.wrap", variables: vars))
        // If the wire is already gone (quit before open), close out directly.
        if queue.sync(execute: { session == nil }) {
            finishStream(abandoned: interrupted)
        }
    }

    /// R15: code decides praise, never the model.
    private func praiseAllowed() -> Bool {
        let repeatsOK = repeatsTotal == 0 || Double(repeatsPassed) / Double(repeatsTotal) >= 0.7
        let roleplayOK = roleplayOutcome.map(\.praiseAllowed) ?? true
        return repeatsOK && roleplayOK && struggles.count <= 1 && !quitRequested
    }

    // MARK: - timeouts / teardown

    private func armPatienceTimeout() {
        scheduleTimeout(after: timing.learnerPatience)
    }

    private func armTranscriptTimeout() {
        scheduleTimeout(after: timing.transcriptAfterEndpoint)
    }

    private func scheduleTimeout(after interval: TimeInterval) {
        cancelTimeout()
        let task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            let waiting = self.queue.sync { () -> Bool in
                switch self.phase {
                case .awaitingLearner, .awaitingTranscript: return true
                case .roleplayAwaiting: return true
                default: return false
                }
            }
            if waiting { self.noiseReprompt() }
        }
        queue.sync { timeoutTask = task }
    }

    private func cancelTimeout() {
        queue.sync {
            timeoutTask?.cancel()
            timeoutTask = nil
        }
    }

    private func beginPCMCapture() {
        queue.sync {
            learnerPCM = Data()
            collectPCM = true
        }
    }

    private func endPCMCapture() {
        queue.sync { collectPCM = false }
    }

    private func finishStream(abandoned: Bool) {
        let alreadyEnded = queue.sync { () -> Bool in
            if ended { return true }
            ended = true
            if abandoned { quitRequested = quitRequested || abandoned }
            phase = .done
            return false
        }
        guard !alreadyEnded else { return }
        continuation.yield(.finished)
        continuation.finish()
    }

    private func teardown() async {
        cancelTimeout()
        pumpTask?.cancel()
        micTask?.cancel()
        let session = queue.sync { () -> (any RealtimeSession)? in
            let s = self.session
            self.session = nil
            return s
        }
        await session?.close()
        audio.finish()
    }
}

