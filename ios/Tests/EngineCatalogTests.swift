import XCTest
@testable import Clutch

/// The engine catalog, as the sidecar publishes it and the native apps read
/// it.
///
/// The catalog is the source of truth for the pickers, so a field the
/// server publishes and the app drops is a choice the owner cannot make.
/// These tests pin the shape and the request the catalog drives.
final class EngineCatalogTests: XCTestCase {
    func testDecodesEveryFieldTheSidecarPublishes() throws {
        let payload = """
        {"engines":[{"id":"deepseek","label":"DeepSeek","available":true,"supportsThreads":true,
          "models":[{"id":"DeepSeek-V4.1-Pro","label":"DeepSeek-V4.1-Pro","value":"DeepSeek-V4.1-Pro",
                     "altValue":"DeepSeek-V4.1-Pro:alt","contextWindow":128000,"images":true}],
          "effortLevels":["low","high"],"effortConfigId":"reasoning_effort","modelConfigId":"model"}]}
        """
        let catalog = try JSONDecoder().decode(EngineCatalog.self, from: Data(payload.utf8))
        let engine = try XCTUnwrap(catalog.engines.first)
        XCTAssertEqual(engine.id, "deepseek")
        XCTAssertEqual(engine.label, "DeepSeek")
        XCTAssertTrue(engine.available)
        XCTAssertTrue(engine.supportsThreads)
        XCTAssertEqual(engine.effortConfigId, "reasoning_effort")
        XCTAssertEqual(engine.modelConfigId, "model")
        XCTAssertNil(engine.note)

        let model = try XCTUnwrap(engine.models.first)
        XCTAssertEqual(model.id, "DeepSeek-V4.1-Pro")
        XCTAssertEqual(model.value, "DeepSeek-V4.1-Pro")
        XCTAssertEqual(model.altValue, "DeepSeek-V4.1-Pro:alt")
        XCTAssertEqual(model.contextWindow, 128000)
        XCTAssertEqual(model.images, true)
    }

    func testAnEngineWithoutANoteDecodesWithoutOne() throws {
        let payload = """
        {"engines":[{"id":"minimax","label":"MiniMax","available":false,"supportsThreads":true,
          "models":[],"effortLevels":[],"effortConfigId":"reasoning_effort","modelConfigId":"model"}]}
        """
        let catalog = try JSONDecoder().decode(EngineCatalog.self, from: Data(payload.utf8))
        let engine = try XCTUnwrap(catalog.engines.first)
        XCTAssertFalse(engine.available)
        XCTAssertNil(engine.note)
        XCTAssertTrue(catalog.availableEngines.isEmpty)
    }

    func testTheMuseAlternateModelValueSurvivesTheNativeChoices() throws {
        let payload = """
        {"engines":[{"id":"muse","label":"Muse Code","available":true,"supportsThreads":true,
          "models":[{"id":"muse-spark-1.3-contributor","label":"Muse Spark 1.3 Contributor",
                     "value":"muse-spark-1.3-contributor",
                     "altValue":"muse-model:[\\"meta\\",\\"tbh\\",\\"muse-spark-1.3-contributor\\"]"}],
          "effortLevels":["minimal","low"],"effortConfigId":"reasoningEffort","modelConfigId":"model"}]}
        """
        let catalog = try JSONDecoder().decode(EngineCatalog.self, from: Data(payload.utf8))
        let engine = try XCTUnwrap(catalog.engines.first)
        let spark = try XCTUnwrap(engine.models.first { $0.id == "muse-spark-1.3-contributor" })
        XCTAssertEqual(spark.altValue, "muse-model:[\"meta\",\"tbh\",\"muse-spark-1.3-contributor\"]")
    }

    func testOnlyTheEnginesTheSidecarKnowsAreOffered() {
        XCTAssertEqual(EngineIds.all, ["deepseek", "minimax", "mcode", "muse", "zcode"])
        XCTAssertTrue(EngineIds.isKnown("deepseek"))
        XCTAssertTrue(EngineIds.isKnown("muse"))
        XCTAssertTrue(EngineIds.isKnown("zcode"))
        XCTAssertFalse(EngineIds.isKnown("gpt"))
        XCTAssertFalse(EngineIds.isKnown(""))
    }

    func testTheChatRequestCarriesTheEngineTheModelAndTheEffort() {
        let host = ClutchHost(name: "Test", origin: URL(string: "https://example.test")!, chatToken: "token")
        let client = ChatSessionClient(
            host: host,
            model: "DeepSeek-V4.1-Flash",
            relayReceiverUid: "uid",
            engine: "deepseek",
            effort: "high"
        )
        let body = client.requestPayload(prompt: "Hello")
        XCTAssertEqual(body["engine"] as? String, "deepseek")
        XCTAssertEqual(body["model"] as? String, "DeepSeek-V4.1-Flash")
        XCTAssertEqual(body["effort"] as? String, "high")
    }

    func testAChatRequestWithoutAnEffortCarriesNoEffort() {
        let host = ClutchHost(name: "Test", origin: URL(string: "https://example.test")!, chatToken: "token")
        let client = ChatSessionClient(
            host: host,
            model: "DeepSeek-V4.1-Pro",
            relayReceiverUid: "uid",
            engine: "deepseek"
        )
        let body = client.requestPayload(prompt: "Hello")
        XCTAssertEqual(body["engine"] as? String, "deepseek")
        XCTAssertNil(body["effort"])
    }
}
