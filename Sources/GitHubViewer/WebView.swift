import SwiftUI
import WebKit

/// HTML を実行して表示する WKWebView のラッパー。
/// ページ内の `console.log` と実行時エラーはコンソールペインに転送する。
struct WebView: NSViewRepresentable {
    let html: String
    let baseURL: URL?
    /// 同じ HTML でも再読み込みしたいときに変える値 (「実行」ボタン)。
    let reloadToken: Int
    var onLog: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onLog: onLog) }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Coordinator.handlerName)
        controller.addUserScript(WKUserScript(source: Self.consoleBridge,
                                              injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false))

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onLog = onLog
        let signature = "\(reloadToken)\u{0001}\(baseURL?.absoluteString ?? "")\u{0001}\(html.hashValue)"
        guard context.coordinator.lastSignature != signature else { return }
        context.coordinator.lastSignature = signature
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Coordinator.handlerName)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        static let handlerName = "githubViewerLog"

        var onLog: (String) -> Void
        var lastSignature: String?

        init(onLog: @escaping (String) -> Void) {
            self.onLog = onLog
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == Self.handlerName, let text = message.body as? String else { return }
            onLog(text)
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // ページ内のリンククリックは既定のブラウザで開く (ビューアの表示は保つ)。
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onLog("error: \(error.localizedDescription)")
        }
    }

    private static let consoleBridge = """
    (function () {
      function send(level, args) {
        try {
          var text = Array.prototype.slice.call(args).map(function (value) {
            if (typeof value === "object") {
              try { return JSON.stringify(value); } catch (e) { return String(value); }
            }
            return String(value);
          }).join(" ");
          window.webkit.messageHandlers.githubViewerLog.postMessage(level + ": " + text);
        } catch (e) {}
      }
      ["log", "info", "warn", "error", "debug"].forEach(function (level) {
        var original = console[level] ? console[level].bind(console) : function () {};
        console[level] = function () { send(level, arguments); original.apply(console, arguments); };
      });
      window.addEventListener("error", function (event) {
        send("error", [event.message + " (" + (event.filename || "") + ":" + (event.lineno || 0) + ")"]);
      });
      window.addEventListener("unhandledrejection", function (event) {
        send("error", ["unhandled promise rejection: " + event.reason]);
      });
    })();
    """
}
