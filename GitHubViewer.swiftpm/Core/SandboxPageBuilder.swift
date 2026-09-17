import Foundation

/// 端末内 (WebView) で他言語を実行するための HTML ページを組み立てる。
///
/// WebAssembly / JavaScript 実装のランタイムを CDN から読み込み、
/// 標準出力とエラーをページ上のターミナル風の領域に流す。
public enum SandboxPageBuilder {
    /// CDN 上のランタイム。バージョンを上げたいときはここだけ直せばよい。
    public enum CDN {
        public static let pyodide = "https://cdn.jsdelivr.net/pyodide/v0.26.4/full/pyodide.js"
        public static let typescript = "https://cdn.jsdelivr.net/npm/typescript@5.6.3/lib/typescript.js"
        public static let fengari = "https://cdn.jsdelivr.net/npm/fengari-web@0.1.4/dist/fengari-web.js"
        public static let rubyScript = "https://cdn.jsdelivr.net/npm/@ruby/3.3-wasm-wasi@2.6.2/dist/browser.umd.js"
        public static let rubyWasm = "https://cdn.jsdelivr.net/npm/@ruby/3.3-wasm-wasi@2.6.2/dist/ruby.wasm"
        public static let sqlJS = "https://cdn.jsdelivr.net/npm/sql.js@1.11.0/dist/sql-wasm.js"
        public static let sqlJSDirectory = "https://cdn.jsdelivr.net/npm/sql.js@1.11.0/dist/"
    }

    /// ソースを実行するページを作る。
    public static func page(engine: LocalEngine, source: String, fileName: String) -> String {
        let runtimeScripts: String
        let boot: String

        switch engine {
        case .javascript:
            runtimeScripts = ""
            boot = """
            const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
            const value = await new AsyncFunction(SOURCE)();
            if (value !== undefined) print(String(value));
            """

        case .typescript:
            runtimeScripts = script(CDN.typescript)
            boot = """
            if (typeof ts === "undefined") throw new Error("TypeScript コンパイラを読み込めませんでした");
            setStatus("コンパイル中…");
            const compiled = ts.transpile(SOURCE, {
              target: ts.ScriptTarget.ES2020,
              module: ts.ModuleKind.None,
            });
            setStatus("実行中…");
            const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
            const value = await new AsyncFunction(compiled)();
            if (value !== undefined) print(String(value));
            """

        case .python:
            runtimeScripts = script(CDN.pyodide)
            boot = """
            setStatus("Python を準備中… (初回は少し時間がかかります)");
            const pyodide = await loadPyodide();
            pyodide.setStdout({ batched: (text) => print(text) });
            pyodide.setStderr({ batched: (text) => printErr(text) });
            setStatus("実行中…");
            await pyodide.runPythonAsync(SOURCE);
            """

        case .ruby:
            runtimeScripts = script(CDN.rubyScript)
            boot = """
            setStatus("Ruby を準備中… (初回は少し時間がかかります)");
            const namespace = window["ruby-wasm-wasi"] || window.rubyWasmWasi;
            if (!namespace) throw new Error("ruby.wasm を読み込めませんでした");
            const response = await fetch("\(CDN.rubyWasm)");
            const wasmModule = await WebAssembly.compileStreaming(response);
            const { vm } = await namespace.DefaultRubyVM(wasmModule);
            setStatus("実行中…");
            vm.eval(SOURCE);
            """

        case .lua:
            runtimeScripts = script(CDN.fengari)
            boot = """
            if (typeof fengari === "undefined") throw new Error("Fengari を読み込めませんでした");
            setStatus("実行中…");
            fengari.load(SOURCE)();
            """

        case .sql:
            runtimeScripts = script(CDN.sqlJS)
            boot = """
            if (typeof initSqlJs === "undefined") throw new Error("sql.js を読み込めませんでした");
            setStatus("SQLite を準備中…");
            const SQL = await initSqlJs({ locateFile: (file) => "\(CDN.sqlJSDirectory)" + file });
            const db = new SQL.Database();
            setStatus("実行中…");
            const results = db.exec(SOURCE);
            if (results.length === 0) {
              print("(結果を返す SELECT はありませんでした)");
            }
            results.forEach(function (result, index) {
              if (index > 0) print("");
              print(result.columns.join(" | "));
              print(result.columns.map(function (column) {
                return "-".repeat(Math.max(3, column.length));
              }).join("-+-"));
              result.values.forEach(function (row) {
                print(row.map(function (value) { return value === null ? "NULL" : String(value); }).join(" | "));
              });
              print("(" + result.values.length + " 行)");
            });
            db.close();
            """
        }

        return """
        <!doctype html>
        <html lang="ja">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(MarkdownRenderer.escape(fileName))</title>
        <style>\(styleSheet)</style>
        </head>
        <body>
        <header>
          <span class="engine">\(MarkdownRenderer.escape(engine.displayName))</span>
          <span class="file">\(MarkdownRenderer.escape(fileName))</span>
          <span class="status" id="status">準備中…</span>
        </header>
        <pre id="out"></pre>
        <script>
        const SOURCE = \(jsLiteral(source));
        const out = document.getElementById("out");
        const statusLabel = document.getElementById("status");

        function append(text, className) {
          const line = document.createElement("span");
          line.className = className;
          line.textContent = String(text) + "\\n";
          out.appendChild(line);
          window.scrollTo(0, document.body.scrollHeight);
        }
        function print(text) { append(text, "stdout"); }
        function printErr(text) { append(text, "stderr"); }
        function setStatus(text) { statusLabel.textContent = text; }

        // ランタイムが console に書き出す出力も画面に取り込む。
        ["log", "info", "debug"].forEach(function (level) {
          const original = console[level].bind(console);
          console[level] = function () {
            append(Array.prototype.join.call(arguments, " "), "stdout");
            original.apply(console, arguments);
          };
        });
        ["warn", "error"].forEach(function (level) {
          const original = console[level].bind(console);
          console[level] = function () {
            append(Array.prototype.join.call(arguments, " "), "stderr");
            original.apply(console, arguments);
          };
        });
        </script>
        \(runtimeScripts)
        <script>
        (async function () {
          const startedAt = Date.now();
          try {
            \(boot)
            setStatus("完了 (" + ((Date.now() - startedAt) / 1000).toFixed(1) + " 秒)");
          } catch (error) {
            printErr(error && error.stack ? error.stack : String(error));
            setStatus("エラー");
          }
        })();
        </script>
        </body>
        </html>
        """
    }

    private static func script(_ url: String) -> String {
        "<script src=\"\(url)\"></script>"
    }

    /// Swift の文字列を JavaScript のリテラルに変換する。
    /// `</script>` でページが壊れないよう `/` もエスケープする。
    public static func jsLiteral(_ text: String) -> String {
        let encoded: String
        if let data = try? JSONSerialization.data(withJSONObject: [text], options: []),
           let json = String(data: data, encoding: .utf8), json.count >= 2 {
            encoded = String(json.dropFirst().dropLast())
        } else {
            encoded = "\"\""
        }
        return encoded.replacingOccurrences(of: "</", with: "<\\/")
    }

    private static let styleSheet = """
    :root { color-scheme: dark; }
    body { margin: 0; background: #0d1117; color: #e6edf3;
           font: 13px/1.6 ui-monospace, SFMono-Regular, Menlo, monospace; }
    header { position: sticky; top: 0; display: flex; gap: 12px; align-items: baseline;
             padding: 10px 14px; background: #161b22; border-bottom: 1px solid #30363d; }
    header .engine { font-weight: 600; }
    header .file { color: #9198a1; }
    header .status { margin-left: auto; color: #9198a1; }
    #out { margin: 0; padding: 14px; white-space: pre-wrap; word-break: break-word; }
    .stdout { color: #e6edf3; }
    .stderr { color: #ff7b72; }
    """
}
