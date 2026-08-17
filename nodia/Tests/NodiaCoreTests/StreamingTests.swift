import XCTest
@testable import NodiaCore

/// Streaming exists to answer one question during a 40-second wait: is data
/// still arriving? So these tests care as much about the counters ticking as
/// about the final text being right.
final class StreamingTests: XCTestCase {

    private func feed(
        _ wire: WireProtocol, _ lines: [String]
    ) -> Summarizer.StreamAccumulator {
        var acc = Summarizer.StreamAccumulator(wire: wire)
        // Mirrors the reader: a false return ends the stream, it doesn't just
        // skip the line.
        for line in lines {
            guard acc.consume(line: line) else { break }
        }
        return acc
    }

    // MARK: - Anthropic wire

    /// The event set observed on the real endpoint: thinking deltas dominate,
    /// text arrives last, and `message_delta` carries the terminal reason.
    func testAnthropicStreamAssemblesTextAndCountsThinking() throws {
        let acc = feed(.anthropic, [
            #"data: {"type":"message_start","message":{"id":"msg_1"}}"#,
            #"data: {"type":"content_block_start","index":0}"#,
            #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"先看标题"}}"#,
            #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"再看正文"}}"#,
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"{\"summary\":"}}"#,
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"\"结论\"}"}}"#,
            #"data: {"type":"content_block_stop","index":0}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":618}}"#,
            #"data: {"type":"message_stop"}"#,
        ])

        XCTAssertEqual(acc.text, #"{"summary":"结论"}"#)
        XCTAssertEqual(acc.progress.thinkingChars, 8, "两段思考各 4 字")
        XCTAssertEqual(acc.progress.textChars, acc.text.count)
        XCTAssertEqual(acc.stopReason, "end_turn")
        XCTAssertEqual(acc.outputTokens, 618)
        XCTAssertEqual(acc.extraction(), .text(#"{"summary":"结论"}"#))
    }

    /// Thinking counts are the liveness signal, so they have to move on their
    /// own — long before the first character of the answer exists.
    func testThinkingProgressAdvancesBeforeAnyText() {
        var acc = Summarizer.StreamAccumulator(wire: .anthropic)
        var seen: [Int] = []
        for chunk in ["一", "二", "三"] {
            _ = acc.consume(
                line: #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"\#(chunk)"}}"#
            )
            seen.append(acc.progress.thinkingChars)
        }
        XCTAssertEqual(seen, [1, 2, 3], "每个 delta 都应让计数前进")
        XCTAssertEqual(acc.progress.textChars, 0, "此时还没有正文")
    }

    /// The failure that started all of this, now over the streaming path.
    func testAnthropicTruncationIsStillNamedAsTruncation() {
        let acc = feed(.anthropic, [
            #"data: {"type":"content_block_delta","delta":{"type":"thinking_delta","thinking":"很长的推理"}}"#,
            #"data: {"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":32768}}"#,
        ])
        guard case .failed(let reason, let detail) = acc.extraction() else {
            return XCTFail("应判定为失败")
        }
        XCTAssertEqual(reason, Summarizer.truncatedReason)
        XCTAssertTrue(detail.contains("max_tokens"), detail)
        XCTAssertTrue(detail.contains("thinking=5"), "日志要带上思考长度：\(detail)")
    }

    /// `ping` is a keepalive with no payload — counting it as content would
    /// make the progress line lie.
    func testPingAndUnknownEventsAreIgnored() {
        let acc = feed(.anthropic, [
            #"data: {"type":"ping"}"#,
            #"data: {"type":"some_future_event","delta":{"type":"text_delta","text":"x"}}"#,
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"真正的正文"}}"#,
        ])
        XCTAssertEqual(acc.text, "真正的正文")
        XCTAssertEqual(acc.progress.thinkingChars, 0)
    }

    /// A tool-call delta would otherwise be counted as answer text.
    func testInputJsonDeltaIsNotCountedAsText() {
        let acc = feed(.anthropic, [
            #"data: {"type":"content_block_delta","delta":{"type":"input_json_delta","partial_json":"{\"a\":1}"}}"#,
        ])
        XCTAssertEqual(acc.text, "")
    }

    /// A mid-stream error is a normal event, not a transport failure — it has
    /// to surface as a reason rather than as silence.
    func testMidStreamErrorSurfaces() {
        let acc = feed(.anthropic, [
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"部分"}}"#,
            #"data: {"type":"error","error":{"type":"overloaded_error","message":"服务过载"}}"#,
        ])
        guard case .failed(let reason, _) = acc.extraction() else {
            return XCTFail("流中报错应判定为失败，而不是把半截正文当成结果")
        }
        XCTAssertTrue(reason.contains("服务过载"), reason)
    }

    /// One bad record shouldn't throw away everything already received.
    func testMalformedLineIsSkippedNotFatal() {
        let acc = feed(.anthropic, [
            "event: content_block_delta",
            "",
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"甲"}}"#,
            "data: {这不是 JSON",
            #"data: {"type":"content_block_delta","delta":{"type":"text_delta","text":"乙"}}"#,
        ])
        XCTAssertEqual(acc.text, "甲乙")
    }

    // MARK: - OpenAI wire

    func testOpenAIStreamAssemblesTextAndStopsOnDone() {
        let acc = feed(.openai, [
            #"data: {"choices":[{"delta":{"content":"前半"}}]}"#,
            #"data: {"choices":[{"delta":{"reasoning_content":"推理中"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"后半"},"finish_reason":"stop"}]}"#,
            "data: [DONE]",
            #"data: {"choices":[{"delta":{"content":"不该被读到"}}]}"#,
        ])
        XCTAssertEqual(acc.text, "前半后半")
        XCTAssertEqual(acc.progress.thinkingChars, 3, "reasoning_content 计入思考")
        XCTAssertEqual(acc.stopReason, "stop")
    }

    /// OpenAI spells truncation `length`; it must reach the same message.
    func testOpenAILengthFinishIsNamedAsTruncation() {
        let acc = feed(.openai, [
            #"data: {"choices":[{"delta":{"reasoning_content":"很长"},"finish_reason":"length"}]}"#,
        ])
        guard case .failed(let reason, _) = acc.extraction() else {
            return XCTFail("应判定为失败")
        }
        XCTAssertEqual(reason, Summarizer.truncatedReason)
    }

    func testOpenAIErrorPayloadSurfaces() {
        let acc = feed(.openai, [#"data: {"error":{"message":"配额不足"}}"#])
        guard case .failed(let reason, _) = acc.extraction() else {
            return XCTFail("应判定为失败")
        }
        XCTAssertTrue(reason.contains("配额不足"), reason)
    }

    // MARK: - Request shape

    func testRequestsAskForStreaming() throws {
        for wire in WireProtocol.allCases {
            let request = Summarizer.buildRequest(
                endpoint: Summarizer.Endpoint(
                    url: "https://x.test", model: "m", keyAccount: "unused", wire: wire
                ),
                key: "k", url: URL(string: "https://x.test")!,
                title: "T", content: "正文"
            )
            let json = try XCTUnwrap(
                try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any]
            )
            XCTAssertEqual(json["stream"] as? Bool, true, "\(wire) 应请求流式")
        }
    }

    /// With a stream, `timeoutInterval` is an *idle* timer: bytes arrive every
    /// second or two, so it only fires on real silence — not on a slow answer.
    func testTimeoutIsGenerousEnoughForRealSilenceOnly() throws {
        let request = Summarizer.buildRequest(
            endpoint: Summarizer.Endpoint(
                url: "https://x.test", model: "m", keyAccount: "unused", wire: .anthropic
            ),
            key: "k", url: URL(string: "https://x.test")!, title: "T", content: "正文"
        )
        XCTAssertGreaterThanOrEqual(request.timeoutInterval, 60)
    }
}

/// The progress table is polled once a second by every in-flight save, and the
/// app runs for weeks — so "does it stay bounded" matters as much as "does it
/// report the right numbers".
final class PreviewProgressStoreTests: XCTestCase {

    func testReportsLatestCountsForAJob() {
        let store = PreviewProgressStore()
        store.start("job-1")
        store.update("job-1", Summarizer.Progress(thinkingChars: 120, textChars: 0))
        store.update("job-1", Summarizer.Progress(thinkingChars: 340, textChars: 12))

        let entry = store.read("job-1")
        XCTAssertEqual(entry?.thinkingChars, 340)
        XCTAssertEqual(entry?.textChars, 12)
        XCTAssertEqual(entry?.done, false)
    }

    /// A poll already in flight when the summary lands should see "finished",
    /// not "unknown job" — those look identical to a client otherwise.
    func testFinishedJobIsStillReadable() {
        let store = PreviewProgressStore()
        store.start("job-1")
        store.finish("job-1")
        XCTAssertEqual(store.read("job-1")?.done, true)
    }

    func testUnknownJobReadsAsNil() {
        XCTAssertNil(PreviewProgressStore().read("never-started"))
    }

    /// Two saves at once must not read each other's counters.
    func testJobsAreIndependent() {
        let store = PreviewProgressStore()
        store.start("a")
        store.start("b")
        store.update("a", Summarizer.Progress(thinkingChars: 5, textChars: 0))
        XCTAssertEqual(store.read("a")?.thinkingChars, 5)
        XCTAssertEqual(store.read("b")?.thinkingChars, 0)
    }

    /// An update for a job nobody started must not create one — otherwise a
    /// stray poll could seed the table.
    func testUpdateWithoutStartIsIgnored() {
        let store = PreviewProgressStore()
        store.update("ghost", Summarizer.Progress(thinkingChars: 99, textChars: 0))
        XCTAssertNil(store.read("ghost"))
        XCTAssertEqual(store.count, 0)
    }

    /// A client that walks away mid-summary leaves an entry behind. Over weeks
    /// of uptime those have to expire, or the table only grows.
    func testStaleEntriesExpire() {
        let store = PreviewProgressStore()
        let longAgo = Date().addingTimeInterval(-(PreviewProgressStore.ttl + 60))
        store.start("abandoned", now: longAgo)
        XCTAssertEqual(store.count, 1)

        // Pruning happens when a new job starts — the only path that adds one.
        store.start("fresh")
        XCTAssertNil(store.read("abandoned"), "过期条目应被清掉")
        XCTAssertNotNil(store.read("fresh"))
        XCTAssertEqual(store.count, 1)
    }

    /// Called from the URLSession task on every delta, so concurrent access is
    /// the normal case, not an edge case.
    func testConcurrentUpdatesDoNotCrash() {
        let store = PreviewProgressStore()
        store.start("hot")
        let done = expectation(description: "writes")
        done.expectedFulfillmentCount = 200
        for i in 1...200 {
            DispatchQueue.global().async {
                store.update("hot", Summarizer.Progress(thinkingChars: i, textChars: 0))
                _ = store.read("hot")
                done.fulfill()
            }
        }
        wait(for: [done], timeout: 5)
        XCTAssertNotNil(store.read("hot"))
    }
}
