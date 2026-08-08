import Foundation
@testable import LTXVideoGeneratorCore

func runAPITests(_ t: TestKit) {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("LTXTests-api-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    t.suite("Token auth") {
        let store = APIv1.TokenStore(directory: tmpDir)
        t.check(store.token.hasPrefix("ltx_"), "token generated with prefix")
        t.check(store.token.count > 40, "token has sufficient entropy")
        let store2 = APIv1.TokenStore(directory: tmpDir)
        t.checkEqual(store.token, store2.token, "installation token stable across instances")

        t.check(APIv1.authorize(headerValue: "Bearer \(store.token)", expectedToken: store.token), "bearer accepted")
        t.check(APIv1.authorize(headerValue: store.token, expectedToken: store.token), "raw token accepted")
        t.check(!APIv1.authorize(headerValue: nil, expectedToken: store.token), "missing token rejected")
        t.check(!APIv1.authorize(headerValue: "Bearer wrong", expectedToken: store.token), "wrong token rejected")
        t.check(!APIv1.authorize(headerValue: "Bearer \(store.token)x", expectedToken: store.token), "length-mismatch token rejected")
    }

    t.suite("Asset sandbox") {
        let assets = APIv1.AssetStore(directory: tmpDir.appendingPathComponent("assets"))
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00])
        do {
            let assetID = try assets.store(imageData: png)
            t.check(UUID(uuidString: assetID) != nil, "asset id is a UUID")
            t.check(assets.path(forAssetID: assetID) != nil, "stored asset resolves")
        } catch { t.check(false, "asset store threw \(error)") }

        t.check(assets.path(forAssetID: "../../../etc/passwd") == nil, "path traversal rejected")
        t.check(assets.path(forAssetID: "/etc/passwd") == nil, "absolute path rejected")
        t.check(assets.path(forAssetID: "not-a-uuid") == nil, "non-uuid rejected")
        t.check(assets.path(forAssetID: UUID().uuidString) == nil, "unknown asset rejected")
    }

    t.suite("Job payload validation") {
        do {
            let payload = try APIv1.parseJobPayload([
                "task": "text_to_video", "prompt": "a fox", "duration": 4.0,
                "quality": "auto", "variations": 3, "seed": 42,
            ])
            t.checkEqual(payload.variations, 3, "variations parsed")
            t.checkEqual(payload.seed, 42, "seed parsed")
            t.check(payload.audio, "audio defaults true")
        } catch { t.check(false, "valid payload threw \(error)") }

        t.checkThrows(APIv1.ValidationError.missingField("prompt"), "missing prompt rejected") {
            _ = try APIv1.parseJobPayload(["task": "text_to_video"])
        }
        t.checkThrows(APIv1.ValidationError.variationsOutOfRange, "21 variations rejected") {
            _ = try APIv1.parseJobPayload(["prompt": "x", "variations": 21])
        }
        t.checkThrows(APIv1.ValidationError.variationsOutOfRange, "0 variations rejected") {
            _ = try APIv1.parseJobPayload(["prompt": "x", "variations": 0])
        }
        t.checkThrows(APIv1.ValidationError.i2vRequiresAsset, "i2v without asset rejected") {
            _ = try APIv1.parseJobPayload(["prompt": "x", "task": "image_to_video"])
        }
        t.checkThrows(APIv1.ValidationError.unknownTask("video_to_video"), "unknown task rejected") {
            _ = try APIv1.parseJobPayload(["prompt": "x", "task": "video_to_video"])
        }
        t.checkThrows(APIv1.ValidationError.invalidValue("quality"), "bad quality rejected") {
            _ = try APIv1.parseJobPayload(["prompt": "x", "quality": "ultra"])
        }
        t.checkThrows(APIv1.ValidationError.invalidValue("duration"), "25s duration rejected") {
            _ = try APIv1.parseJobPayload(["prompt": "x", "duration": 25.0])
        }
    }

    t.suite("API adult policy") {
        let suiteName = "LTXTests.api.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = ModelRegistry(userDefaults: defaults)

        // Official model via API: allowed.
        do {
            let payload = try APIv1.parseJobPayload(["prompt": "x", "model": LTXModelCatalog.defaultModelID])
            let model = try APIv1.resolveModel(payload: payload, registry: registry, appAdultModeEnabled: false)
            t.checkEqual(model.id, LTXModelCatalog.defaultModelID, "official model resolves via API")
        } catch { t.check(false, "official model via API threw \(error)") }

        // Adult model requested while app adult mode OFF → 403-class rejection
        // even when the client claims adultMode true.
        do {
            let payload = try APIv1.parseJobPayload(["prompt": "x", "model": "10eros_v12_q8", "adultMode": true])
            _ = try APIv1.resolveModel(payload: payload, registry: registry, appAdultModeEnabled: false)
            t.check(false, "adult model with app adult OFF should be rejected")
        } catch let error as APIv1.ValidationError {
            if case .policyRejected = error {
                t.check(true, "client cannot override app adult mode")
            } else {
                t.check(false, "unexpected validation error \(error)")
            }
        } catch { t.check(false, "unexpected error \(error)") }

        // Even with app adult mode ON, unverified lab model still rejected.
        do {
            let payload = try APIv1.parseJobPayload(["prompt": "x", "model": "10eros_v12_q8", "adultMode": true])
            _ = try APIv1.resolveModel(payload: payload, registry: registry, appAdultModeEnabled: true)
            t.check(false, "unverified model should be rejected")
        } catch let error as APIv1.ValidationError {
            if case .policyRejected(let reason) = error {
                t.check(reason.contains("verification") || reason.contains("verified") || reason.contains("Lab"),
                        "unverified model rejected for generation via API")
            } else {
                t.check(false, "unexpected validation error \(error)")
            }
        } catch { t.check(false, "unexpected error \(error)") }

        // Arbitrary repo injection: unregistered model id rejected.
        do {
            let payload = try APIv1.parseJobPayload(["prompt": "x", "model": "EvilOrg/evil-model"])
            _ = try APIv1.resolveModel(payload: payload, registry: registry, appAdultModeEnabled: true)
            t.check(false, "unregistered model should be rejected")
        } catch { t.check(true, "arbitrary repo injection rejected") }
    }

    t.suite("Request building") {
        let suiteName = "LTXTests.api2.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = ModelRegistry(userDefaults: defaults)
        let model = registry.descriptor(id: LTXModelCatalog.defaultModelID)!

        do {
            let payload = try APIv1.parseJobPayload([
                "prompt": "a fox", "duration": 4.0, "variations": 5, "seed": 100, "audio": false,
            ])
            let requests = APIv1.makeRequests(payload: payload, model: model, sourceImagePath: nil, textEncoderID: "gemma3_12b_4bit")
            t.checkEqual(requests.count, 5, "5 variation requests")
            t.checkEqual(Set(requests.compactMap { $0.parameters.seed }).count, 5, "seeds distinct (base+i)")
            t.checkEqual(requests.first?.parameters.seed, 100, "base seed respected")
            t.check(requests.allSatisfy { $0.disableAudio }, "audio=false honored")
            t.checkEqual(requests.first?.parameters.numFrames, PromptCompiler.frameCount(forSeconds: 4), "duration → frames")
            t.checkEqual(requests.first?.qualityMode, "auto", "quality mode carried")
            t.checkEqual(requests.first?.preset, GenerationPreset.standard.rawValue, "API quality maps through shared preset")
            t.checkEqual(requests.first?.targetDurationSeconds, 4.0, "API target duration carried to final resolver")
            t.checkEqual(requests.first?.generationSource, "apiV1", "API source recorded")

            let history = HistoricalSuccessStore(storeURL: tmpDir.appendingPathComponent("api-quality.json"))
            let hardware = HardwareProfile(modelIdentifier: "TestMac1,1", chipDescription: "Test", physicalMemoryGB: 48)
            let engine = AutoQualityEngine(history: history, hardware: hardware)
            let snapshot = MemorySnapshot(
                physicalBytes: 48 * 1_073_741_824,
                approximateAvailableBytes: 30 * 1_073_741_824,
                swapUsedBytes: 0,
                swapTotalBytes: 0,
                thermalState: "nominal",
                capturedAt: Date()
            )
            let resolved = try GenerationSettingsResolver.resolve(request: requests[0], engine: engine, snapshot: snapshot)
            t.checkEqual(resolved.profile?.id, "S0", "API Standard uses same concrete resolver")
            t.checkEqual(resolved.request.parameters.numFrames, PromptCompiler.frameCount(forSeconds: 4, fps: 24),
                         "API duration survives profile application")
        } catch { t.check(false, "request building threw \(error)") }
    }

    t.suite("HTTP framing") {
        let complete = Data("POST /v1/jobs HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}".utf8)
        t.check(LocalAPIServer.isRequestComplete(complete), "complete request detected")
        let partial = Data("POST /v1/jobs HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}".utf8)
        t.check(!LocalAPIServer.isRequestComplete(partial), "short body detected as incomplete")
        let noBody = Data("GET /v1/models HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        t.check(LocalAPIServer.isRequestComplete(noBody), "GET without body complete")
        let headersOnly = Data("GET /v1/models HTTP/1.1\r\n".utf8)
        t.check(!LocalAPIServer.isRequestComplete(headersOnly), "unterminated headers incomplete")
    }
}
