import XCTest
@testable import Holo

final class APIClientStreamingRecoveryTests: XCTestCase {
    private final class InterruptingURLProtocol: URLProtocol, @unchecked Sendable {
        static var requestCount = 0

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requestCount += 1
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let partial = #"data: {"choices":[{"delta":{"content":"partial"}}]}"# + "\n\n"
            client?.urlProtocol(self, didLoad: Data(partial.utf8))

            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { [weak self] in
                guard let self else { return }
                self.client?.urlProtocol(
                    self,
                    didFailWithError: URLError(.networkConnectionLost)
                )
            }
        }

        override func stopLoading() {}
    }

    func testInterruptedStreamDoesNotReplayAfterYieldingPartialContent() async {
        InterruptingURLProtocol.requestCount = 0
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingURLProtocol.self]
        let client = APIClient(urlSession: URLSession(configuration: configuration))
        let request = APIRequest(
            baseURL: "https://mock.local",
            path: "/stream",
            method: .post,
            headers: [:],
            body: nil
        )

        var chunks: [String] = []
        do {
            for try await chunk in client.sendStreaming(request) {
                chunks.append(chunk)
            }
            XCTFail("半截流之后断网必须抛错，交给周期回放任务从头重试")
        } catch let error as APIError {
            guard case .networkUnavailable = error else {
                return XCTFail("预期 networkUnavailable，实际 \(error)")
            }
        } catch {
            XCTFail("预期 APIError，实际 \(error)")
        }

        XCTAssertEqual(chunks, ["partial"])
        XCTAssertEqual(
            InterruptingURLProtocol.requestCount,
            1,
            "已交付半截内容后不得在同一流里重放，否则会拼出坏 JSON"
        )
    }
}
