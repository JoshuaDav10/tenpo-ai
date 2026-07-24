import Foundation
import CoreModels
import ModeEngine
import ContentKit
import SpeechKit
import RealtimeKit

/// The conducted voice lesson (SESSION_DESIGN.md, all four acts).
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

actor GuidedLessonSession: ModeSession {
    nonisolated let events: AsyncStream<ModeEvent>
    private let continuation: AsyncStream<ModeEvent>.Continuation

    private let context: ModeContext
    private let plan: SessionPlan
    private let audio: VoiceAudioIO
    private let timing: LessonTiming

    private var loop = VoiceLoop(policy: .conducted)
    private var session: (any RealtimeSession)?
    private var script: LessonScript?
    private var steps: [LessonStep] = []
    private var stepIndex = -1
    private var phase: Phase = .idle
    private var transition: String?          // "correct"/"struggled" folded into next step
    private var attempt = 0                  // per-step correction attempts
    private var learnerPCM = Data()          // current learner turn, for pron grading
    private var collectPCM = false
    private var reviews: [ReviewEvent] = []
    private var errors: [ErrorEvent] = []
    private var struggles: [String] = []     // targets that needed retries
    /// Phrases taught since the last recap beat (drives "now you know X and Y").
    private var taughtSinceRecap: [String] = []
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
    private var timeoutGeneration = 0

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
            finishStream()
            return
        }
        guard let realtime = context.realtime else {
            continuation.yield(.info("Voice lessons need the live connection."))
            finishStream()
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
            self.script = script
            self.steps = steps
            self.session = session
            startPumps(session)
            continuation.yield(.info(script.title))
            continuation.yield(.progress(current: 0, total: steps.count))
            await advance()
        } catch {
            continuation.yield(.info("Couldn't open the voice session."))
            finishStream()
        }
    }

    func handle(_ input: LearnerInput) async {
        switch input {
        case .tap:
            let actions = loop.tapInterrupt()
            guard !actions.isEmpty else { return }
            emit(actions)
            try? await session?.interrupt()
            // The floor is the learner's now; treat it like an opened mic turn.
            if case .delivering = phase { phase = .awaitingLearner }
            if case .roleplayDelivering = phase { phase = .roleplayAwaiting }
            armTimeout(after: timing.learnerPatience)
            beginPCMCapture()
        case .text(let typed):
            // Dev/simulator path: a typed line IS the learner transcript.
            await learnerSaid(typed)
        case .requestHint:
            await sendHintStep()
        case .quit:
            quitRequested = true
            await beginWrap()
        case .speech:
            break // live audio rides VoiceAudioIO, not LearnerInput
        }
    }

    func finish() async -> ModeResult {
        let score: JSONValue = .object([
            "repeats_passed": .number(Double(repeatsPassed)),
            "repeats_total": .number(Double(repeatsTotal)),
            "praise_allowed": .bool(praiseAllowed()),
        ])
        let result = ModeResult(
            reviews: reviews, errors: errors,
            status: quitRequested ? .abandoned : .completed,
            score: score, duration: 0)
        await teardown()
        return result
    }

    // MARK: - pumps

    private func startPumps(_ session: any RealtimeSession) {
        pumpTask = Task { [weak self] in
            for await event in session.events {
                await self?.handleWire(event)
            }
        }
        micTask = Task { [weak self, audio] in
            for await chunk in audio.micChunks {
                guard let self else { return }
                await self.micChunk(chunk)
            }
        }
    }

    private func micChunk(_ chunk: CoreModels.AudioBuffer) async {
        guard loop.shouldForwardMicAudio else { return }
        if collectPCM { learnerPCM.append(chunk.data) }
        try? await session?.send(audio: chunk)
    }

    private func handleWire(_ event: RealtimeEvent) async {
        // Learner transcripts route to the conductor, everything else to the loop.
        if case .partialTranscript(let role, let text) = event, role == .learner {
            await learnerSaid(text)
            return
        }
        if case .userSpeechStopped = event, case .awaitingLearner = phase {
            phase = .awaitingTranscript
            armTimeout(after: timing.transcriptAfterEndpoint)
        }
        if case .proxyRefused(let code, let fallback) = event {
            continuation.yield(.info(fallback
                ? "Today's voice budget is used — continue this lesson in text mode from the Roleplay tab."
                : "Voice session refused (\(code))."))
            finishStream()
            return
        }
        if case .error(let message) = event {
            continuation.yield(.info("Voice session ended: \(message)"))
            finishStream()
            return
        }

        let actions = loop.handle(event)
        var said: String?
        var turnEnded = false
        for action in actions {
            switch action {
            case .play(let buffer): audio.emit(.play(buffer))
            case .stopPlayback: audio.emit(.stop)
            case .state(let state):
                audio.emit(.state(state))
                if state == .thinking { turnEnded = true }
            case .assistantSaid(let text):
                continuation.yield(.prompt(text: text, audio: nil))
                said = text
                turnEnded = true
            case .learnerSaid, .fallbackToCascade, .failed:
                break
            }
        }
        if turnEnded { await assistantTurnFinished(said) }
    }

    private func emit(_ actions: [VoiceLoopAction]) {
        for action in actions {
            switch action {
            case .play(let buffer): audio.emit(.play(buffer))
            case .stopPlayback: audio.emit(.stop)
            case .state(let state): audio.emit(.state(state))
            case .assistantSaid, .learnerSaid, .fallbackToCascade, .failed: break
            }
        }
    }

    // MARK: - the conductor

    /// AI finished speaking a beat. Open the mic (learner's turn), chain the next
    /// step (framing beat), or close out (wrap delivered).
    private func assistantTurnFinished(_ text: String?) async {
        switch phase {
        case .delivering(let thenLearner):
            if thenLearner {
                phase = .awaitingLearner
                emit(loop.openMic())
                armTimeout(after: timing.learnerPatience)
                beginPCMCapture()
            } else {
                await advance()
            }
        case .roleplayDelivering:
            if let text, let engine = roleplay {
                await engine.seedActorTurn(text)
            }
            phase = .roleplayAwaiting
            emit(loop.openMic())
            armTimeout(after: timing.learnerPatience)
            beginPCMCapture()
        case .wrapDelivering:
            finishStream()
        default:
            break
        }
    }

    /// Move to the next step and deliver it.
    private func advance() async {
        // A real tutor ties a chunk together before moving on ("now you know X
        // and Y"). Fire a recap when a run of taught phrases ends.
        if await deliverRecapIfDue() { return }

        stepIndex += 1
        guard stepIndex < steps.count else {
            await beginWrap()
            return
        }
        continuation.yield(.progress(current: stepIndex, total: steps.count))
        attempt = 0
        if case .wrap = steps[stepIndex] {
            await beginWrap()
            return
        }
        await deliverCurrentStep()
    }

    /// True when a recap beat was sent (the caller must not also advance).
    private func deliverRecapIfDue() async -> Bool {
        guard taughtSinceRecap.count >= 2 else { return false }
        // Only recap at a natural seam: the NEXT step isn't another repeat.
        let nextIsRepeat: Bool = {
            let next = stepIndex + 1
            guard next < steps.count else { return false }
            if case .modelAndRepeat = steps[next] { return true }
            return false
        }()
        guard !nextIsRepeat else { return false }

        let covered = taughtSinceRecap.joined(separator: "、")
        taughtSinceRecap.removeAll()
        phase = .delivering(thenLearner: false)
        var vars: [String: JSONValue] = ["covered": .string(covered)]
        if let transition {
            vars["transition"] = .string(transition)
            self.transition = nil
        }
        await send(step: "lesson.recap", vars)
        return true
    }

    private func deliverCurrentStep() async {
        guard let script else { return }
        var vars: [String: JSONValue] = [:]
        if let transition {
            vars["transition"] = .string(transition)
            self.transition = nil
        }

        switch steps[stepIndex] {
        case .explain(let focus):
            phase = .delivering(thenLearner: false)
            vars["topic_en"] = .string(script.topicEN)
            vars["focus_en"] = .string(focus)
            if stepIndex == 0 { vars["first"] = .bool(true) }
            await send(step: "lesson.explain", vars)

        case .modelAndRepeat(let rep):
            phase = .delivering(thenLearner: true)
            let ruby = rep.reading ?? context.pack.reading(for: rep.target)
                .map { $0.segments.map { $0.ruby ?? $0.base }.joined() }
            continuation.yield(.card(text: rep.target, reading: ruby, gloss: rep.glossEN))
            vars["target"] = .string(rep.target)
            if let reading = rep.reading { vars["reading"] = .string(reading) }
            vars["gloss_en"] = .string(rep.glossEN)
            await send(step: "lesson.model_repeat", vars)

        case .promptResponse(let probe):
            phase = .delivering(thenLearner: true)
            continuation.yield(.card(text: probe.questionJP, reading: nil, gloss: probe.expectationEN))
            vars["question_jp"] = .string(probe.questionJP)
            if let expectation = probe.expectationEN { vars["expectation_en"] = .string(expectation) }
            await send(step: "lesson.prompt_response", vars)

        case .translateToJP(let probe):
            phase = .delivering(thenLearner: true)
            continuation.yield(.card(text: "“\(probe.promptEN)”", reading: nil, gloss: "say it in Japanese"))
            vars["english_prompt"] = .string(probe.promptEN)
            await send(step: "lesson.translate_to_jp", vars)

        case .translateToEN(let probe):
            phase = .delivering(thenLearner: true)
            continuation.yield(.card(text: probe.phraseJP, reading: nil, gloss: "what does this mean?"))
            vars["phrase_jp"] = .string(probe.phraseJP)
            await send(step: "lesson.translate_to_en", vars)

        case .patternTeach(let pattern):
            // Teaching beat: chains straight into the pattern's first probe.
            phase = .delivering(thenLearner: false)
            continuation.yield(.card(text: pattern.nameEN, reading: nil, gloss: pattern.ruleEN))
            vars["name_en"] = .string(pattern.nameEN)
            vars["rule_en"] = .string(pattern.ruleEN)
            vars["examples"] = .string(pattern.examples
                .map { "\($0.jp) = \($0.en)" }.joined(separator: "; "))
            await send(step: "lesson.pattern_teach", vars)

        case .miniRoleplay(let cap, _):
            roleplayCap = cap
            roleplayTurns = 0
            let scenario = scenarioForRoleplay()
            let engine = RoleplayEngine(scenario: scenario,
                                        director: context.director ?? StubDirector(),
                                        sessionID: plan.sessionID)
            roleplay = engine
            let progress = await engine.progress()
            continuation.yield(.goalProgress(completed: progress.completed, total: progress.total))
            phase = .roleplayDelivering
            vars["setting"] = .string(scenario.setting)
            vars["persona_hint"] = .string(scenario.personaHint ?? "")
            vars["register"] = .string(scenario.register)
            vars["band"] = .string(scenario.band)
            await send(step: "lesson.roleplay_open", vars)

        case .wrap:
            await beginWrap()
        }
    }

    private func send(step kind: String, _ vars: [String: JSONValue]) async {
        try? await session?.send(step: LessonStepDirective(kind: kind, variables: vars))
    }

    /// A learner transcript arrived (voice or typed). Route by phase.
    private func learnerSaid(_ raw: String) async {
        cancelTimeout()
        collectPCM = false
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        continuation.yield(.heard(Transcription(
            text: text, confidence: 1.0, alternatives: [],
            provider: ProviderID(rawValue: "realtime"))))

        switch phase {
        case .awaitingLearner, .awaitingTranscript:
            phase = .idle
            await gradeCurrentStep(text)
        case .roleplayAwaiting:
            phase = .idle
            await roleplayTurn(text)
        case .delivering(let thenLearner) where thenLearner:
            // Typed answer landing while the AI is still mid-beat (dev path, or an
            // eager learner) — accept it rather than drop it.
            phase = .idle
            await gradeCurrentStep(text)
        case .roleplayDelivering:
            phase = .idle
            await roleplayTurn(text)
        default:
            break
        }
    }

    // MARK: - grading (D-E: transcript fast-path, honest grader on mismatch,
    // noise never advances)

    private func gradeCurrentStep(_ text: String) async {
        guard context.pack.normalizeAnswer(text).count >= 2 else {
            await noiseReprompt()
            return
        }
        switch steps[stepIndex] {
        case .modelAndRepeat(let rep): await gradeRepeat(rep, heard: text)
        case .promptResponse(let probe): await gradeProbe(probe, heard: text)
        case .translateToJP(let probe):
            // Grades exactly like a repeat: known accepted Japanese answers, honest
            // grader as the second opinion, corrective retry naming the target.
            await gradeRepeat(LessonStep.Repeat(
                target: probe.accepted[0], glossEN: probe.promptEN,
                accepted: probe.accepted, itemRef: probe.itemRef), heard: text)
        case .translateToEN(let probe): await gradeMeaning(probe, heard: text)
        default: break
        }
    }

    private func gradeMeaning(_ probe: LessonStep.TranslateEN, heard: String) async {
        if englishAnswerMatches(heard, probe.acceptedEN) {
            if let ref = probe.itemRef {
                reviews.append(ReviewEvent(itemID: ref, dimension: .recognitionListening,
                                           grade: attempt == 0 ? .good : .hard,
                                           modeID: GuidedLessonMode.descriptor.id,
                                           sessionID: plan.sessionID))
                continuation.yield(.verdict(itemID: ref, grade: attempt == 0 ? .good : .hard, diff: nil))
            }
            transition = "correct"
            await advance()
            return
        }
        attempt += 1
        if attempt > 1 {
            if let ref = probe.itemRef {
                errors.append(ErrorEvent(sessionID: plan.sessionID, itemID: ref,
                                         category: .vocab, surface: heard,
                                         expected: probe.acceptedEN.first))
                reviews.append(ReviewEvent(itemID: ref, dimension: .recognitionListening,
                                           grade: .again, modeID: GuidedLessonMode.descriptor.id,
                                           sessionID: plan.sessionID))
            }
            struggles.append(probe.phraseJP)
            transition = "struggled"
            await advance()
        } else {
            phase = .delivering(thenLearner: true)
            await send(step: "lesson.meaning_retry", [
                "heard": .string(heard),
                "phrase_jp": .string(probe.phraseJP),
            ])
        }
    }

    private func gradeRepeat(_ rep: LessonStep.Repeat, heard: String) async {
        if attempt == 0 { repeatsTotal += 1 }
        if context.pack.answersMatch(heard, rep.accepted).isMatch {
            recordPass(rep, heard: heard)
            transition = "correct"
            await advance()
            return
        }
        // Transcript mismatched — second opinion via the honest grader (R6) on the
        // captured turn audio, when we have any.
        var passed = false
        if !learnerPCM.isEmpty {
            let clip = AudioClip(data: learnerPCM, encoding: .pcm16, sampleRate: 24000)
            let item = GradableItem(
                itemID: rep.itemRef ?? ItemID(rawValue: "lesson:step"),
                acceptedAnswers: rep.accepted, canonical: rep.target,
                isPronunciationGraded: rep.pronGraded, pronThreshold: rep.pronThreshold)
            if let outcome = try? await context.speech.grade(
                audio: clip, item: item, attempt: attempt, locale: context.pack.id),
               case .pass = outcome {
                passed = true
            }
        }
        if passed {
            recordPass(rep, heard: heard)
            transition = "correct"
            await advance()
        } else {
            await repeatFailed(rep, heard: heard)
        }
    }

    private func repeatFailed(_ rep: LessonStep.Repeat, heard: String) async {
        attempt += 1
        if attempt > 2 {
            // Never blocks (R4 spirit): log honestly and move on.
            record(rep, grade: .again, heard: heard)
            struggles.append(rep.target)
            transition = "struggled"
            await advance()
        } else {
            if let ref = rep.itemRef {
                continuation.yield(.verdict(itemID: ref, grade: .again, diff: "\(heard) → \(rep.target)"))
            }
            phase = .delivering(thenLearner: true)
            var vars: [String: JSONValue] = [
                "heard": .string(heard),
                "target": .string(rep.target),
                // Lets the tutor slow down further on a second miss.
                "attempt": .number(Double(attempt)),
            ]
            if let reading = rep.reading { vars["reading"] = .string(reading) }
            await send(step: "lesson.correct_retry", vars)
        }
    }

    private func gradeProbe(_ probe: LessonStep.Probe, heard: String) async {
        let normalized = context.pack.normalizeAnswer(heard)
        let hit = probe.expectedPatterns.isEmpty
            || probe.expectedPatterns.contains { normalized.contains(context.pack.normalizeAnswer($0)) }
        if hit {
            for ref in probe.itemRefs {
                reviews.append(ReviewEvent(itemID: ref, dimension: .productionSpoken,
                                           grade: .good, modeID: GuidedLessonMode.descriptor.id,
                                           sessionID: plan.sessionID))
            }
            transition = "correct"
            await advance()
            return
        }
        attempt += 1
        if attempt > 1 {
            for ref in probe.itemRefs {
                errors.append(ErrorEvent(sessionID: plan.sessionID, itemID: ref,
                                         category: .grammar, surface: heard,
                                         expected: probe.expectationEN))
            }
            struggles.append(probe.questionJP)
            transition = "struggled"
            await advance()
        } else {
            phase = .delivering(thenLearner: true)
            await send(step: "lesson.hint", ["hint_en": .string(probe.hintEN ?? "")])
        }
    }

    private func recordPass(_ rep: LessonStep.Repeat, heard: String) {
        repeatsPassed += 1
        taughtSinceRecap.append(rep.target)
        record(rep, grade: attempt == 0 ? .good : .hard, heard: nil)
    }

    private func record(_ rep: LessonStep.Repeat, grade: ReviewGrade, heard: String?) {
        guard let ref = rep.itemRef else { return }
        reviews.append(ReviewEvent(itemID: ref, dimension: .productionSpoken, grade: grade,
                                   modeID: GuidedLessonMode.descriptor.id, sessionID: plan.sessionID))
        continuation.yield(.verdict(itemID: ref, grade: grade, diff: heard.map { "\($0) → \(rep.target)" }))
        if grade == .again {
            errors.append(ErrorEvent(sessionID: plan.sessionID, itemID: ref,
                                     category: rep.pronGraded ? .pronunciation : .vocab,
                                     surface: heard, expected: rep.target))
        }
    }

    private func noiseReprompt() async {
        phase = .delivering(thenLearner: true)
        var vars: [String: JSONValue] = [:]
        if stepIndex >= 0, stepIndex < steps.count,
           case .modelAndRepeat(let rep) = steps[stepIndex] {
            vars["target"] = .string(rep.target)
        }
        await send(step: "lesson.reprompt", vars)
    }

    private func sendHintStep() async {
        guard stepIndex >= 0, stepIndex < steps.count,
              case .promptResponse(let probe) = steps[stepIndex] else { return }
        phase = .delivering(thenLearner: true)
        await send(step: "lesson.hint", ["hint_en": .string(probe.hintEN ?? probe.expectationEN ?? "")])
    }

    // MARK: - roleplay act (Act 3 — R1/R3/R4/R8/R15 via the tested engine)

    private func roleplayTurn(_ text: String) async {
        guard let engine = roleplay else {
            await advance()
            return
        }
        let directive = await engine.processLearnerTurn(text)
        let progress = await engine.progress()
        continuation.yield(.goalProgress(completed: progress.completed, total: progress.total))
        roleplayTurns += 1

        switch directive {
        case .endScene:
            await endRoleplay(engine)
        case .injectHelp(_, let kind):
            if roleplayTurns >= roleplayCap {
                await endRoleplay(engine)
            } else {
                phase = .roleplayDelivering
                await send(step: "lesson.roleplay_help", ["kind": .string(String(describing: kind))])
            }
        case .continue(let actorDirective):
            if roleplayTurns >= roleplayCap {
                await endRoleplay(engine)
            } else {
                phase = .roleplayDelivering
                var vars: [String: JSONValue] = [:]
                if let actorDirective { vars["directive"] = .string(actorDirective) }
                await send(step: "lesson.roleplay_turn", vars)
            }
        }
    }

    private func endRoleplay(_ engine: RoleplayEngine) async {
        let outcome = await engine.finalize()
        roleplayOutcome = outcome
        reviews.append(contentsOf: outcome.reviews)
        errors.append(contentsOf: outcome.errors)
        await advance()
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

    private func beginWrap() async {
        guard !ended, !isWrapping else { return }
        isWrapping = true
        phase = .wrapDelivering
        var vars: [String: JSONValue] = ["praise_allowed": .bool(praiseAllowed())]
        if let outcome = roleplayOutcome {
            let total = outcome.missingRequiredGoals.count + completedGoals(outcome)
            vars["goals_completed"] = .number(Double(completedGoals(outcome)))
            vars["goals_total"] = .number(Double(total))
        }
        if !struggles.isEmpty {
            vars["struggles"] = .array(struggles.map { .string($0) })
        }
        // Fold the pending acknowledgment of the final graded step into the wrap.
        if let transition {
            vars["transition"] = .string(transition)
            self.transition = nil
        }
        if quitRequested { vars["transition"] = .string("struggled") }
        if session == nil {
            finishStream()
            return
        }
        await send(step: "lesson.wrap", vars)
    }

    private var isWrapping = false

    private func completedGoals(_ outcome: RoleplayOutcome) -> Int {
        // finalize() emits a .good review per completed-goal target; use goal math
        // where available, else fall back to substantive turns as a proxy.
        max(0, outcome.substantiveTurns > 0 ? outcome.reviews.filter { $0.grade == .good }.count : 0)
    }

    /// R15: code decides praise, never the model.
    private func praiseAllowed() -> Bool {
        let repeatsOK = repeatsTotal == 0 || Double(repeatsPassed) / Double(repeatsTotal) >= 0.7
        let roleplayOK = roleplayOutcome.map(\.praiseAllowed) ?? true
        return repeatsOK && roleplayOK && struggles.count <= 1 && !quitRequested
    }

    // MARK: - timeouts / teardown

    private func armTimeout(after interval: TimeInterval) {
        timeoutGeneration += 1
        let generation = timeoutGeneration
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.timeoutFired(generation: generation)
        }
    }

    private func timeoutFired(generation: Int) async {
        guard generation == timeoutGeneration, !ended else { return }
        switch phase {
        case .awaitingLearner, .awaitingTranscript, .roleplayAwaiting:
            await noiseReprompt()
        default:
            break
        }
    }

    private func cancelTimeout() {
        timeoutGeneration += 1
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private func beginPCMCapture() {
        learnerPCM = Data()
        collectPCM = true
    }

    private func finishStream() {
        guard !ended else { return }
        ended = true
        phase = .done
        continuation.yield(.finished)
        continuation.finish()
    }

    private func teardown() async {
        cancelTimeout()
        pumpTask?.cancel()
        micTask?.cancel()
        let session = self.session
        self.session = nil
        await session?.close()
        audio.finish()
    }
}
