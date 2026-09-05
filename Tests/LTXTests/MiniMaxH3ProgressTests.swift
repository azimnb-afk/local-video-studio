import Foundation
@testable import LTXVideoGeneratorCore

func runMiniMaxH3ProgressTests(_ t: TestKit) {
    
    t.suite("MiniMaxH3ProgressParserTests") {
        // 1. Parsing sampling steps
        let line1 = "[minimax-h3] step 1/8 sigma 1.0000 (21862 ms)"
        let ev1 = MiniMaxH3ProgressParser.parseLine(line1)
        t.checkEqual(ev1, .samplingStep(current: 1, total: 8, stepMs: 21862), "Parses 1/8 step with duration")
        
        let line2 = "[minimax-h3] step 6/10 sigma 0.9231 (35468 ms)"
        let ev2 = MiniMaxH3ProgressParser.parseLine(line2)
        t.checkEqual(ev2, .samplingStep(current: 6, total: 10, stepMs: 35468), "Parses 6/10 step with duration")
        
        let lineCached = "[minimax-h3] step 2/10 sigma 0.9908 (cached velocity, 4 ms)"
        let evCached = MiniMaxH3ProgressParser.parseLine(lineCached)
        t.checkEqual(evCached, .samplingStep(current: 2, total: 10, stepMs: 4), "Parses cached velocity step with duration")
        
        let line20 = "[minimax-h3] step 13/20 sigma 0.7000 (15000 ms)"
        let ev20 = MiniMaxH3ProgressParser.parseLine(line20)
        t.checkEqual(ev20, .samplingStep(current: 13, total: 20, stepMs: 15000), "Parses custom 20 steps line")
        
        // 2. Parsing sampling done
        let lineDone = "[minimax-h3] sampling done in 213623 ms, DiT released"
        let evDone = MiniMaxH3ProgressParser.parseLine(lineDone)
        t.checkEqual(evDone, .samplingDone(totalMs: 213623), "Parses sampling done with total duration")
        
        // 3. Parsing video decoding
        let lineVid = "[minimax-h3] video decoded in 77095 ms (load+decode)"
        let evVid = MiniMaxH3ProgressParser.parseLine(lineVid)
        t.checkEqual(evVid, .videoDecoding(totalMs: 77095), "Parses video decoded duration")
        
        // 4. Parsing audio decoding
        let lineAud = "[minimax-h3] audio decoded: 120000 samples/ch at 32000 Hz (2675 ms)"
        let evAud = MiniMaxH3ProgressParser.parseLine(lineAud)
        t.checkEqual(evAud, .audioDecoding(samples: 120000, sampleRate: 32000), "Parses audio decoded parameters")
        
        // 5. Parsing keyframe conditioning
        let lineKeyframe = "[video] minimax-h3 first keyframe conditioning engaged (512x288, vision block 512x288)"
        let evKeyframe = MiniMaxH3ProgressParser.parseLine(lineKeyframe)
        t.checkEqual(evKeyframe, .keyframeConditioning, "Parses keyframe conditioning")
        
        // 6. Parsing text conditioning & DiT loaded
        let lineText = "[minimax-h3] text encoded (48 rows, 0 vision), encoder resident 8.56 GB, released"
        let evText = MiniMaxH3ProgressParser.parseLine(lineText)
        t.checkEqual(evText, .textConditioning, "Parses text conditioning")
        
        let lineDit = "[minimax-h3] dit loaded in 97732 ms, text refined in 108 ms"
        let evDit = MiniMaxH3ProgressParser.parseLine(lineDit)
        t.checkEqual(evDit, .ditLoaded, "Parses dit loaded")
        
        // 7. Parsing final output
        let lineOut = "[video] -> 90f 288x512 (39813120 rgb bytes)"
        let evOut = MiniMaxH3ProgressParser.parseLine(lineOut)
        t.checkEqual(evOut, .generationOutput(frames: 90, width: 288, height: 512), "Parses output dimensions")
        
        // 8. Robustness: unrelated / empty / malformed lines
        t.checkEqual(MiniMaxH3ProgressParser.parseLine(""), nil, "Empty line returns nil")
        t.checkEqual(MiniMaxH3ProgressParser.parseLine("   "), nil, "Whitespace line returns nil")
        t.checkEqual(MiniMaxH3ProgressParser.parseLine("RSS: 18M  Mem: 39%  CPU: 7%  GPU: 97%"), nil, "Stats line returns nil")
        t.checkEqual(MiniMaxH3ProgressParser.parseLine("[args] model: /path/to/model"), nil, "Args line returns nil")
        t.checkEqual(MiniMaxH3ProgressParser.parseLine("[minimax-h3] invalid step format"), nil, "Malformed step line returns nil")
    }
    
    t.suite("MiniMaxH3ProgressSessionLifecycleTests") {
        var params = GenerationParameters.default
        params.numInferenceSteps = 10
        params.width = 512
        params.height = 288
        params.numFrames = 90
        
        let request = GenerationRequest(
            prompt: "Test prompt",
            sourceImagePath: "/path/to/source.png",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: params,
            preset: "standard"
        )
        
        var emittedProgress: [Double] = []
        var emittedMessages: [String] = []
        
        let session = MiniMaxH3ProgressSession(request: request) { prog, msg in
            emittedProgress.append(prog)
            emittedMessages.append(msg)
        }
        
        // 1. Initial State: preparing
        t.check(emittedProgress.count >= 1, "Emits initial progress")
        t.checkEqual(emittedProgress.first, 0.03, "Starts at 0.03")
        
        // 2. Conditioning events
        session.handleLine("[video] minimax-h3 first keyframe conditioning engaged (512x288, vision block 512x288)")
        t.check(emittedProgress.last! >= 0.08, "Advances to >= 0.08 on keyframe conditioning")
        
        session.handleLine("[minimax-h3] text encoded (48 rows, 0 vision)")
        t.check(emittedProgress.last! >= 0.12, "Advances to >= 0.12 on text conditioning")
        
        session.handleLine("[minimax-h3] dit loaded in 97732 ms")
        t.check(emittedProgress.last! >= 0.14, "Advances to >= 0.14 on DiT loaded")
        
        // 3. Sampling steps (Standard 10 steps)
        for step in 1...10 {
            session.handleLine("[minimax-h3] step \(step)/10 sigma 0.9000 (10000 ms)")
            let current = emittedProgress.last!
            t.check(current >= 0.15 && current <= 0.90, "Step \(step) progress is within sampling range [0.15, 0.90]")
            t.check(emittedMessages.last!.contains("Step \(step) of 10"), "Message indicates Step \(step) of 10")
        }
        
        // 4. Last sampling step remains < 100%
        t.check(emittedProgress.last! <= 0.90, "Step 10 remains <= 90%")
        
        // 5. Decode
        session.handleLine("[minimax-h3] sampling done in 200000 ms")
        t.check(emittedProgress.last! >= 0.90, "Sampling done is >= 90%")
        
        session.handleLine("[minimax-h3] video decoded in 50000 ms")
        t.check(emittedProgress.last! >= 0.94, "Video decoded is >= 94%")
        
        session.handleLine("[minimax-h3] audio decoded: 120000 samples/ch at 32000 Hz")
        t.check(emittedProgress.last! >= 0.96, "Audio decoded is >= 96%")
        
        // 6. Muxing
        session.recordMuxing()
        t.check(emittedProgress.last! >= 0.98, "Muxing is >= 98%")
        t.check(emittedProgress.last! < 1.0, "Muxing is < 100%")
        
        // 7. Save completion = 100%
        session.recordComplete()
        t.checkEqual(emittedProgress.last!, 1.0, "Completion reaches exact 1.0 (100%)")
        
        // 8. Progress Monotonicity Check
        var isMonotonic = true
        for i in 1..<emittedProgress.count {
            if emittedProgress[i] < emittedProgress[i - 1] {
                isMonotonic = false
                break
            }
        }
        t.check(isMonotonic, "Progress is strictly monotonic (never decreases)")
    }
    
    t.suite("MiniMaxH3PresetStepCountTests") {
        // Quick = 8 steps
        var qParams = GenerationParameters.default
        qParams.numInferenceSteps = 8
        let qReq = GenerationRequest(
            prompt: "Quick",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: qParams,
            preset: "quick"
        )
        var qProg: [Double] = []
        let qSession = MiniMaxH3ProgressSession(request: qReq) { p, _ in qProg.append(p) }
        for s in 1...8 {
            qSession.handleLine("[minimax-h3] step \(s)/8 sigma 0.5 (5000 ms)")
        }
        t.checkEqual(qProg.last!, 0.90, "Quick 8/8 reaches 0.90 sampling limit")
        
        // High = 12 steps
        var hParams = GenerationParameters.default
        hParams.numInferenceSteps = 12
        let hReq = GenerationRequest(
            prompt: "High",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: hParams,
            preset: "high"
        )
        var hProg: [Double] = []
        let hSession = MiniMaxH3ProgressSession(request: hReq) { p, _ in hProg.append(p) }
        for s in 1...12 {
            hSession.handleLine("[minimax-h3] step \(s)/12 sigma 0.5 (5000 ms)")
        }
        t.checkEqual(hProg.last!, 0.90, "High 12/12 reaches 0.90 sampling limit")
        
        // Custom 6 steps
        var c6Params = GenerationParameters.default
        c6Params.numInferenceSteps = 6
        let c6Req = GenerationRequest(
            prompt: "Custom 6",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: c6Params,
            preset: "custom"
        )
        var c6Prog: [Double] = []
        let c6Session = MiniMaxH3ProgressSession(request: c6Req) { p, _ in c6Prog.append(p) }
        for s in 1...6 {
            c6Session.handleLine("[minimax-h3] step \(s)/6 sigma 0.5 (5000 ms)")
        }
        t.checkEqual(c6Prog.last!, 0.90, "Custom 6/6 reaches 0.90 sampling limit")
        
        // Custom 20 steps
        var c20Params = GenerationParameters.default
        c20Params.numInferenceSteps = 20
        let c20Req = GenerationRequest(
            prompt: "Custom 20",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: c20Params,
            preset: "custom"
        )
        var c20Prog: [Double] = []
        let c20Session = MiniMaxH3ProgressSession(request: c20Req) { p, _ in c20Prog.append(p) }
        for s in 1...20 {
            c20Session.handleLine("[minimax-h3] step \(s)/20 sigma 0.5 (5000 ms)")
        }
        t.checkEqual(c20Prog.last!, 0.90, "Custom 20/20 reaches 0.90 sampling limit")
    }
    
    t.suite("AutoMovieWeightedProgressTests") {
        // Plan: [90, 73, 73, 56] frames, all 10 steps
        let shots = [
            AutoMovieShotWorkload(shotIndex: 0, frames: 90, steps: 10),
            AutoMovieShotWorkload(shotIndex: 1, frames: 73, steps: 10),
            AutoMovieShotWorkload(shotIndex: 2, frames: 73, steps: 10),
            AutoMovieShotWorkload(shotIndex: 3, frames: 56, steps: 10),
        ]
        
        // Start of movie
        let pStart = AutoMovieProgressWeightCalculator.calculateOverallProgress(
            shots: shots, currentShotIndex: 0, currentShotFraction: 0.0
        )
        t.checkEqual(pStart, 0.0, "Start of movie is 0.0")
        
        // Halfway through shot 1 (90 frames)
        let pShot1Half = AutoMovieProgressWeightCalculator.calculateOverallProgress(
            shots: shots, currentShotIndex: 0, currentShotFraction: 0.5
        )
        t.check(pShot1Half > 0.10 && pShot1Half < 0.20, "Shot 1 midpoint is weighted ~14.8%")
        
        // End of shot 1 / Start of shot 2 (must NOT reset to zero!)
        let pShot1End = AutoMovieProgressWeightCalculator.calculateOverallProgress(
            shots: shots, currentShotIndex: 0, currentShotFraction: 1.0
        )
        let pShot2Start = AutoMovieProgressWeightCalculator.calculateOverallProgress(
            shots: shots, currentShotIndex: 1, currentShotFraction: 0.0
        )
        t.checkEqual(pShot1End, pShot2Start, "Shot 1 end and Shot 2 start match exactly (no reset to 0)")
        t.check(pShot2Start > 0.25, "Shot 2 starts above 25%")
        
        // Start of shot 4 (56 frames)
        let pShot4Start = AutoMovieProgressWeightCalculator.calculateOverallProgress(
            shots: shots, currentShotIndex: 3, currentShotFraction: 0.0
        )
        t.check(pShot4Start > 0.70, "Shot 4 begins above 70% based on actual prior completed work")
        
        // All shots completed, entering assembly
        let pAssembling = AutoMovieProgressWeightCalculator.calculateOverallProgress(
            shots: shots, currentShotIndex: 3, currentShotFraction: 1.0, isAssembling: true
        )
        t.check(pAssembling >= 0.96 && pAssembling < 1.0, "Assembly is reserved in [0.96, 0.99]")
        
        // Assembled & Completed
        let pDone = AutoMovieProgressWeightCalculator.calculateOverallProgress(
            shots: shots, currentShotIndex: 3, currentShotFraction: 1.0, isCompleted: true
        )
        t.checkEqual(pDone, 1.0, "Completion is exact 1.0 (100%)")
    }
    
    t.suite("MiniMaxH3T2VAAndFL2VASafetyTests") {
        // T2VA (No source image)
        let t2vReq = GenerationRequest(
            prompt: "A beautiful mountain landscape at sunrise",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: .default,
            preset: "standard"
        )
        var t2vMsgs: [String] = []
        let t2vSession = MiniMaxH3ProgressSession(request: t2vReq) { _, msg in t2vMsgs.append(msg) }
        t2vSession.handleLine("[minimax-h3] text encoded (48 rows, 0 vision)")
        t.check(!t2vMsgs.last!.contains("source conditioning"), "T2VA does not claim source conditioning")
        t.check(t2vMsgs.last!.contains("Preparing text conditioning"), "T2VA reports preparing text conditioning")
        
        // FL2VA (With source image)
        let fl2vaReq = GenerationRequest(
            prompt: "A woman walks in the garden",
            sourceImagePath: "/path/to/image.png",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: .default,
            preset: "standard"
        )
        var fl2vaMsgs: [String] = []
        let fl2vaSession = MiniMaxH3ProgressSession(request: fl2vaReq) { _, msg in fl2vaMsgs.append(msg) }
        fl2vaSession.handleLine("[video] minimax-h3 first keyframe conditioning engaged")
        t.check(fl2vaMsgs.last!.contains("Preparing source image conditioning"), "FL2VA reports preparing source image")
        
        fl2vaSession.handleLine("[minimax-h3] text encoded (48 rows, 0 vision)")
        t.check(fl2vaMsgs.last!.contains("source conditioning"), "FL2VA reports source conditioning")
    }
    
    t.suite("MiniMaxH3CancellationAndIsolationTests") {
        let req1 = GenerationRequest(
            prompt: "Job 1",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: .default,
            preset: "standard"
        )
        var job1Prog: [Double] = []
        let session1 = MiniMaxH3ProgressSession(request: req1) { p, _ in job1Prog.append(p) }
        session1.handleLine("[minimax-h3] step 1/10 sigma 0.9000 (10000 ms)")
        let step1Val = job1Prog.last!
        
        // Cancel Job 1
        session1.finish()
        
        // Stale event arriving after finish must be ignored
        session1.handleLine("[minimax-h3] step 5/10 sigma 0.5000 (10000 ms)")
        t.checkEqual(job1Prog.last!, step1Val, "Late event ignored after session finished/cancelled")
        t.check(job1Prog.last! < 1.0, "Cancelled job does not flash 100%")
        
        // Job 2 starts fresh on reused server
        let req2 = GenerationRequest(
            prompt: "Job 2",
            modelId: MiniMaxH3Configuration.modelID,
            parameters: .default,
            preset: "standard"
        )
        var job2Prog: [Double] = []
        let session2 = MiniMaxH3ProgressSession(request: req2) { p, _ in job2Prog.append(p) }
        t.checkEqual(job2Prog.first!, 0.03, "Job 2 resets cleanly to 0.03 on server reuse")
        
        session2.handleLine("[minimax-h3] step 1/10 sigma 0.9000 (10000 ms)")
        t.checkEqual(job2Prog.last!, step1Val, "Job 2 advances independently")
    }
}
