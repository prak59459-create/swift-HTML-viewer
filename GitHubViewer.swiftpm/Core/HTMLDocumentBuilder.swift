import Foundation

/// WebView に渡す HTML を組み立てる。
public enum HTMLDocumentBuilder {
    /// ページ全体の HTML かどうか (そうでなければ断片として包む)。
    public static func isFullDocument(_ html: String) -> Bool {
        let head = html.prefix(2048).lowercased()
        return head.contains("<html") || head.contains("<!doctype html") || head.contains("<svg")
    }

    /// HTML ファイルをそのまま実行する。断片であれば最低限の枠を付ける。
    public static func executable(html: String, title: String) -> String {
        if isFullDocument(html) { return html }
        return page(title: title, body: html)
    }

    /// Markdown を変換した HTML を GitHub 風のスタイルで包む。
    public static func markdown(_ source: String, title: String) -> String {
        page(title: title, body: "<article class=\"markdown-body\">\n" + MarkdownRenderer.render(source) + "</article>")
    }

    /// ソースコードをそのまま表示するページ。
    public static func code(_ source: String, title: String) -> String {
        page(title: title, body: "<pre class=\"code\"><code>" + MarkdownRenderer.escape(source) + "</code></pre>")
    }

    /// 本文を共通スタイル付きの HTML ドキュメントにする。
    public static func page(title: String, body: String) -> String {
        """
        <!doctype html>
        <html lang="ja">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(MarkdownRenderer.escape(title))</title>
        <style>\(styleSheet)</style>
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    public static func errorPage(_ message: String) -> String {
        page(title: "エラー", body: "<article class=\"markdown-body\"><h1>表示できませんでした</h1><p>"
             + MarkdownRenderer.escape(message) + "</p></article>")
    }

    private static let styleSheet = """
    :root { color-scheme: light dark; --fg: #1f2328; --bg: #ffffff; --muted: #59636e; --border: #d1d9e0; --code-bg: #f6f8fa; --link: #0969da; }
    @media (prefers-color-scheme: dark) {
      :root { --fg: #e6edf3; --bg: #0d1117; --muted: #9198a1; --border: #30363d; --code-bg: #161b22; --link: #4493f8; }
    }
    body { margin: 0; background: var(--bg); color: var(--fg);
           font: 14px/1.6 -apple-system, "Hiragino Sans", "Noto Sans JP", sans-serif; }
    .markdown-body { max-width: 900px; margin: 0 auto; padding: 24px 20px 64px; }
    .markdown-body h1, .markdown-body h2 { border-bottom: 1px solid var(--border); padding-bottom: .3em; }
    .markdown-body h1 { font-size: 2em; margin-top: 0; }
    .markdown-body img { max-width: 100%; }
    .markdown-body a { color: var(--link); text-decoration: none; }
    .markdown-body a:hover { text-decoration: underline; }
    .markdown-body blockquote { margin: 0 0 16px; padding: 0 1em; color: var(--muted); border-left: .25em solid var(--border); }
    .markdown-body table { border-collapse: collapse; display: block; overflow-x: auto; max-width: 100%; }
    .markdown-body th, .markdown-body td { border: 1px solid var(--border); padding: 6px 13px; }
    .markdown-body tr:nth-child(2n) { background: var(--code-bg); }
    .markdown-body hr { border: 0; border-top: 1px solid var(--border); }
    code, pre { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 12.5px; }
    :not(pre) > code { background: var(--code-bg); border-radius: 6px; padding: .2em .4em; }
    pre { background: var(--code-bg); border-radius: 6px; padding: 16px; overflow-x: auto; }
    pre.code { margin: 0; border-radius: 0; min-height: 100vh; }
    """
}
