import Foundation
import XCTest
@testable import HighliteMenuBarCore

final class SiteEmbedSnippetTests: XCTestCase {
    func testBuildsSnippetWithRelayEndpointAndToken() throws {
        let snippet = try SiteEmbedSnippet(
            relayBaseURL: URL(string: "http://127.0.0.1:8787")!,
            ingestToken: "ingest-token"
        )

        XCTAssertEqual(snippet.endpoint.absoluteString, "http://127.0.0.1:8787/v1/sessions")
        XCTAssertTrue(
            snippet.html.contains(#"<script defer src="/assets/highlite.iife.js"></script>"#)
        )
        XCTAssertTrue(
            snippet.html.contains(#"endpoint: "http://127.0.0.1:8787/v1/sessions","#)
        )
        XCTAssertTrue(snippet.html.contains(#"token: "ingest-token","#))
        XCTAssertTrue(snippet.html.contains("window.Highlite.createHighlite"))
        XCTAssertTrue(snippet.html.contains("window.addEventListener('load'"))
    }

    func testAcceptsCustomAssetURLAndNormalizesTheEndpoint() throws {
        let snippet = try SiteEmbedSnippet(
            assetPath: " https://cdn.example.com/highlite.iife.js ",
            relayBaseURL: URL(string: "http://127.0.0.1:9000/")!,
            ingestToken: "token"
        )

        XCTAssertEqual(snippet.assetPath, "https://cdn.example.com/highlite.iife.js")
        XCTAssertEqual(snippet.endpoint.absoluteString, "http://127.0.0.1:9000/v1/sessions")
        XCTAssertTrue(
            snippet.html.contains(
                #"<script defer src="https://cdn.example.com/highlite.iife.js"></script>"#
            )
        )

        let prefixedBase = try SiteEmbedSnippet(
            relayBaseURL: URL(string: "http://127.0.0.1:9000/prefix/")!,
            ingestToken: "token"
        )
        XCTAssertEqual(
            prefixedBase.endpoint.absoluteString,
            "http://127.0.0.1:9000/v1/sessions"
        )
    }

    func testEscapesTokenForJavaScriptAndAssetPathForHTML() throws {
        let snippet = try SiteEmbedSnippet(
            assetPath: #"/assets/x" onload="alert(1)"#,
            relayBaseURL: URL(string: "http://127.0.0.1:8787")!,
            ingestToken: #"a"b\c</script>&"#
        )

        XCTAssertTrue(
            snippet.html.contains(
                #"<script defer src="/assets/x&quot; onload=&quot;alert(1)"></script>"#
            )
        )
        XCTAssertTrue(snippet.html.contains(#"token: "a\"b\\c\u003c/script\u003e\u0026","#))
        XCTAssertFalse(snippet.html.contains(#"src="/assets/x" onload="#))
    }

    func testRejectsInvalidConfiguration() {
        let baseURL = URL(string: "http://127.0.0.1:8787")!

        XCTAssertThrowsError(
            try SiteEmbedSnippet(relayBaseURL: baseURL, ingestToken: "")
        ) {
            XCTAssertEqual($0 as? SiteEmbedSnippetError, .invalidIngestToken)
        }
        XCTAssertThrowsError(
            try SiteEmbedSnippet(assetPath: " ", relayBaseURL: baseURL, ingestToken: "token")
        ) {
            XCTAssertEqual($0 as? SiteEmbedSnippetError, .invalidAssetPath)
        }
        XCTAssertThrowsError(
            try SiteEmbedSnippet(
                relayBaseURL: URL(string: "file:///tmp/relay")!,
                ingestToken: "token"
            )
        ) {
            XCTAssertEqual($0 as? SiteEmbedSnippetError, .invalidRelayURL)
        }
        XCTAssertThrowsError(
            try SiteEmbedSnippet(
                relayBaseURL: URL(string: "https://user:pass@example.com")!,
                ingestToken: "token"
            )
        ) {
            XCTAssertEqual($0 as? SiteEmbedSnippetError, .invalidRelayURL)
        }
    }
}
