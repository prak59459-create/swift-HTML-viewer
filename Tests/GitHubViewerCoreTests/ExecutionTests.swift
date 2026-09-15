import XCTest
@testable import GitHubViewerCore

final class LanguageCatalogTests: XCTestCase {
    func testLanguageByExtension() {
        XCTAssertEqual(LanguageCatalog.language(forFileName: "main.c")?.id, "c")
        XCTAssertEqual(LanguageCatalog.language(forFileName: "Main.java")?.id, "java")
        XCTAssertEqual(LanguageCatalog.language(forFileName: "script.PY")?.id, "python")
        XCTAssertNil(LanguageCatalog.language(forFileName: "notes.txt"))
    }

    func testHTMLRunsInBrowser() {
        let plan = LanguageCatalog.plan(kind: .web, fileName: "index.html", allowsRemoteExecution: false)
        XCTAssertEqual(plan, .browser)
    }

    func testPythonRunsLocallyWithoutServer() {
        let plan = LanguageCatalog.plan(kind: .code(language: "python"), fileName: "a.py",
                                        allowsRemoteExecution: false)
        guard case .local(let engine, let language) = plan else { return XCTFail("\(plan)") }
        XCTAssertEqual(engine, .python)
        XCTAssertEqual(language.id, "python")
    }

    func testCUsesTheBuiltInCompiler() {
        // C はアプリ内蔵のコンパイラで動くので、サーバーを許可していなくても実行できる。
        let plan = LanguageCatalog.plan(kind: .code(language: "c"), fileName: "main.c",
                                        allowsRemoteExecution: false)
        guard case .builtin(let compiler, let language) = plan else { return XCTFail("\(plan)") }
        XCTAssertEqual(compiler, .miniC)
        XCTAssertEqual(language.id, "c")
    }

    func testCompiledLanguageNeedsServer() {
        let denied = LanguageCatalog.plan(kind: .code(language: "rust"), fileName: "main.rs",
                                          allowsRemoteExecution: false)
        guard case .unavailable = denied else { return XCTFail("\(denied)") }

        let allowed = LanguageCatalog.plan(kind: .code(language: "rust"), fileName: "main.rs",
                                           allowsRemoteExecution: true)
        guard case .remote(let spec, _) = allowed else { return XCTFail("\(allowed)") }
        XCTAssertEqual(spec.pistonLanguage, "rust")
        XCTAssertEqual(spec.wandboxLanguage, "Rust")
        XCTAssertEqual(spec.fileName, "main.rs")
    }

    func testUnknownExtensionIsNotRunnable() {
        let plan = LanguageCatalog.plan(kind: .code(language: "text"), fileName: "README",
                                        allowsRemoteExecution: true)
        guard case .unavailable = plan else { return XCTFail("\(plan)") }
    }

    func testPreferLocalCanBeDisabled() {
        let language = try! XCTUnwrap(LanguageCatalog.language(id: "python"))
        let plan = LanguageCatalog.plan(for: language, allowsRemoteExecution: true, prefersLocal: false)
        guard case .remote(let spec, _) = plan else { return XCTFail("\(plan)") }
        XCTAssertEqual(spec.pistonLanguage, "python")
    }

    func testSQLRunsLocally() {
        let plan = LanguageCatalog.plan(kind: .code(language: "sql"), fileName: "query.sql",
                                        allowsRemoteExecution: false)
        guard case .local(let engine, _) = plan else { return XCTFail("\(plan)") }
        XCTAssertEqual(engine, .sql)
    }

    func testEveryLanguageIsRunnable() {
        for language in LanguageCatalog.all {
            XCTAssertTrue(language.isRunnable, "\(language.id) に実行方法がない")
            XCTAssertFalse(language.fileExtensions.isEmpty, "\(language.id) に拡張子がない")
        }
    }
}

final class SandboxPageBuilderTests: XCTestCase {
    func testJSLiteralEscaping() {
        XCTAssertEqual(SandboxPageBuilder.jsLiteral("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(SandboxPageBuilder.jsLiteral("1\n2"), "\"1\\n2\"")
        XCTAssertFalse(SandboxPageBuilder.jsLiteral("</script>").contains("</script>"))
    }

    func testPythonPageLoadsPyodideAndEmbedsSource() {
        let page = SandboxPageBuilder.page(engine: .python, source: "print('hi')", fileName: "a.py")
        XCTAssertTrue(page.contains(SandboxPageBuilder.CDN.pyodide), page)
        XCTAssertTrue(page.contains("runPythonAsync"), page)
        XCTAssertTrue(page.contains("print('hi')"), page)
    }

    func testSourceCannotBreakOutOfScriptTag() {
        let page = SandboxPageBuilder.page(engine: .javascript,
                                           source: "</script><script>window.evil = 1</script>",
                                           fileName: "a.js")
        // ソース中の </script> はエスケープされ、スクリプトタグを閉じてしまわない。
        XCTAssertFalse(page.contains("</script><script>window.evil"), page)
        XCTAssertTrue(page.contains("<\\/script>"), page)
    }

    func testEveryEngineProducesAPage() {
        for engine in LocalEngine.allCases {
            let page = SandboxPageBuilder.page(engine: engine, source: "x", fileName: "a.txt")
            XCTAssertTrue(page.hasPrefix("<!doctype html>"), engine.rawValue)
            XCTAssertTrue(page.contains("const SOURCE ="), engine.rawValue)
            XCTAssertTrue(page.contains(engine.displayName), engine.rawValue)
        }
    }
}
