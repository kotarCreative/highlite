import Foundation
import XCTest
@testable import HighliteMenuBarCore

final class MockURLProtocol: URLProtocol {
    static let lock = NSLock()
    static var handler: ((URLRequest) -> (Int, Data))?
    static var lastRequest: URLRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        MockURLProtocol.lock.lock()
        MockURLProtocol.lastRequest = request
        let handler = MockURLProtocol.handler
        MockURLProtocol.lock.unlock()

        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, data) = handler(request)
        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: status,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": "application/json"]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func reset() {
        lock.lock()
        handler = nil
        lastRequest = nil
        lock.unlock()
    }

    static func response(status: Int, json: String) {
        lock.lock()
        handler = { _ in (status, Data(json.utf8)) }
        lock.unlock()
    }
}

func requestBody(_ request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }
    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }
    var data = Data()
    let bufferSize = 4096
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }
    while stream.hasBytesAvailable {
        let read = stream.read(buffer, maxLength: bufferSize)
        if read <= 0 { break }
        data.append(buffer, count: read)
    }
    return data
}

final class RelayClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() async throws -> RelayClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        let client = RelayClient(session: session)
        try await client.configure(
            baseURL: URL(string: "http://127.0.0.1:8787")!,
            readToken: "read-secret",
            ingestToken: "ingest-secret"
        )
        return client
    }

    func testListSessionsSendsBearerAndDecodes() async throws {
        let client = try await makeClient()
        let fixture = try fixtureData("sessions")
        MockURLProtocol.response(
            status: 200,
            json: String(decoding: fixture, as: UTF8.self)
        )

        let sessions = try await client.listSessions()
        XCTAssertEqual(sessions.count, 2)

        MockURLProtocol.lock.lock()
        let request = MockURLProtocol.lastRequest
        MockURLProtocol.lock.unlock()
        let unwrapped = try XCTUnwrap(request)
        XCTAssertEqual(unwrapped.url?.path, "/v1/sessions")
        XCTAssertEqual(unwrapped.value(forHTTPHeaderField: "Authorization"), "Bearer read-secret")
        XCTAssertNil(unwrapped.value(forHTTPHeaderField: "Origin"))
    }

    func testIngestCaptureUsesIngestTokenAndZipContentType() async throws {
        let client = try await makeClient()
        MockURLProtocol.response(
            status: 201,
            json: #"{"sessionId":"native-1","status":"ready","receivedAtMs":1763642096789,"bytes":123,"pageTitle":"Native capture","pageUrl":"highlite://native-capture/still","durationMs":0,"summary":"summary","statusUrl":"/v1/sessions/native-1","bundleUrl":"/v1/sessions/native-1/bundle.zip"}"#
        )
        guard let imageURL = Bundle.module.url(forResource: "native-capture", withExtension: "png") else {
            return XCTFail("Missing native-capture.png fixture")
        }
        let bundle = try NativeCaptureBundleBuilder.build(
            pngData: try Data(contentsOf: imageURL),
            note: "Check the total before saving.",
            highlight: NativeCaptureRect(x: 0.25, y: 0.25, width: 0.5, height: 0.25)
        )

        let metadata = try await client.ingestCapture(bundle)
        XCTAssertEqual(metadata.sessionId, "native-1")
        XCTAssertEqual(metadata.status, .ready)

        MockURLProtocol.lock.lock()
        let request = MockURLProtocol.lastRequest
        MockURLProtocol.lock.unlock()
        let unwrapped = try XCTUnwrap(request)
        XCTAssertEqual(unwrapped.httpMethod, "POST")
        XCTAssertEqual(unwrapped.url?.path, "/v1/sessions")
        XCTAssertEqual(unwrapped.value(forHTTPHeaderField: "Authorization"), "Bearer ingest-secret")
        XCTAssertEqual(unwrapped.value(forHTTPHeaderField: "Content-Type"), "application/zip")
        XCTAssertNil(unwrapped.value(forHTTPHeaderField: "Origin"))
        XCTAssertEqual(try requestBody(unwrapped), bundle.archive)
    }

    func testHealthDoesNotSendReadToken() async throws {
        let client = try await makeClient()
        MockURLProtocol.response(status: 200, json: #"{"status":"ok","compiler":"highlite","version":"1.0.0"}"#)

        let health = try await client.health()
        XCTAssertTrue(health.isOK)
        XCTAssertEqual(health.version, "1.0.0")

        MockURLProtocol.lock.lock()
        let request = MockURLProtocol.lastRequest
        MockURLProtocol.lock.unlock()
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(request?.url?.path, "/healthz")
    }

    func testProviderSaveOmitsBlankSecretAndEndpoint() async throws {
        let client = try await makeClient()
        MockURLProtocol.response(status: 200, json: #"{"defaultProvider":null,"providers":[]}"#)

        let request = ProviderSaveRequest(
            kind: .openai,
            model: "gpt-5",
            baseUrl: " ",
            apiKey: " ",
            makeDefault: true
        )
        let response = try await client.saveProvider(id: "work", request: request)
        XCTAssertTrue(response.enabled)
        XCTAssertEqual(response.providers.count, 0)

        MockURLProtocol.lock.lock()
        let captured = MockURLProtocol.lastRequest
        MockURLProtocol.lock.unlock()
        let unwrapped = try XCTUnwrap(captured)
        XCTAssertEqual(unwrapped.httpMethod, "POST")
        XCTAssertEqual(unwrapped.url?.path, "/v1/providers/work")
        XCTAssertEqual(unwrapped.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(requestBody(unwrapped))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(object["apiKey"])
        XCTAssertNil(object["baseUrl"])
        XCTAssertEqual(object["makeDefault"] as? Bool, true)
    }

    func testJiraSaveOmitsBlankToken() async throws {
        let client = try await makeClient()
        MockURLProtocol.response(
            status: 200,
            json: #"{"id":"jira-issue","version":"1.1.0","settings":null,"hasApiToken":false}"#
        )

        _ = try await client.updateJiraRecipe(settings: .defaults(), apiToken: "  ")

        MockURLProtocol.lock.lock()
        let captured = MockURLProtocol.lastRequest
        MockURLProtocol.lock.unlock()
        let unwrapped = try XCTUnwrap(captured)
        let body = try XCTUnwrap(requestBody(unwrapped))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(object["apiToken"])
    }

    func testServerErrorIsReportedWithoutTokenOrRawBody() async throws {
        let client = try await makeClient()
        MockURLProtocol.response(
            status: 400,
            json: #"{"error":"Choose a valid Jira project first."}"#
        )

        do {
            _ = try await client.listSessions()
            XCTFail("Expected an error")
        } catch let error as RelayAPIError {
            XCTAssertEqual(error.statusCode, 400)
            XCTAssertEqual(error.localizedDescription, "Choose a valid Jira project first.")
            XCTAssertFalse(error.localizedDescription.contains("read-secret"))
        }
    }

    func testUnauthorizedMessageDoesNotLeakToken() async throws {
        let client = try await makeClient()
        MockURLProtocol.response(status: 401, json: #"{"error":"a valid bearer token is required"}"#)

        do {
            _ = try await client.listSessions()
            XCTFail("Expected an error")
        } catch let error as RelayAPIError {
            XCTAssertEqual(error.statusCode, 401)
            XCTAssertTrue(error.localizedDescription.contains("rejected"))
            XCTAssertFalse(error.localizedDescription.contains("read-secret"))
        }
    }

    func testActivityQueryIsBounded() async throws {
        let client = try await makeClient()
        MockURLProtocol.response(status: 200, json: #"{"items":[]}"#)

        _ = try await client.activity(limit: 1000)
        MockURLProtocol.lock.lock()
        let request = MockURLProtocol.lastRequest
        MockURLProtocol.lock.unlock()
        let query = try XCTUnwrap(request?.url?.query)
        XCTAssertTrue(query.contains("limit=100"))
    }

    func testRedirectDelegateRefusesRedirect() throws {
        let delegate = NoRedirectURLSessionDelegate()
        let source = URL(string: "http://127.0.0.1:8787/healthz")!
        let target = URL(string: "https://example.com/steal")!
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: source,
                statusCode: 302,
                httpVersion: nil,
                headerFields: ["Location": target.absoluteString]
            )
        )
        let task = URLSession.shared.dataTask(with: source)
        var followedRequest: URLRequest? = URLRequest(url: target)
        delegate.urlSession(
            URLSession.shared,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: target)
        ) { request in
            followedRequest = request
        }
        XCTAssertNil(followedRequest)
    }

    func testNonLoopbackEndpointIsRejected() async throws {
        let client = RelayClient()
        do {
            try await client.configure(
                baseURL: URL(string: "https://example.com")!,
                readToken: "token"
            )
            XCTFail("Expected a loopback validation error")
        } catch {
            XCTAssertEqual(error as? RelayAPIError, .invalidEndpoint)
        }
    }

    func testDecodingFailureIsSafe() async throws {
        let client = try await makeClient()
        MockURLProtocol.response(status: 200, json: "<html>not json</html>")
        do {
            _ = try await client.listSessions()
            XCTFail("Expected a decoding error")
        } catch let error as RelayAPIError {
            XCTAssertEqual(error, .decoding)
        }
    }
}
