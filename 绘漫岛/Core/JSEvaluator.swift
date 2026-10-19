import Foundation
import JavaScriptCore
import CryptoKit
import SwiftSoup

/// JS 执行环境 —— JavaScriptCore 快速通道（纯逻辑 JS）。
/// DOM 类规则由 WebViewRuleEngine（WKWebView + jQuery）兜底，见 AnalyzeRule 分流。
final class JSEvaluator {
    static let shared = JSEvaluator()

    /// 同步表达式求值（URL 规则 {{js}}、头部日期签名等）；返回脚本完成值
    /// 注意：必须用 setObject(forKeyedSubscript:)，setValue:forKey: 对不存在的键会抛 NSUnknownKeyException
    func evaluateExpression(_ code: String, vars: [String: String]) -> String {
        // ⚠️ 不用 `JSContext()!`：极端内存压力下它会返回 nil，
        //    强制解包 = 直接闪退（这类崩溃无法被上层 catch）。
        guard let ctx = JSContext() else { return "" }
        ctx.exceptionHandler = { _, _ in }
        ctx.evaluateScript(Self.jsoupPrologue)
        for (k, v) in vars { ctx.setObject(v, forKeyedSubscript: k as NSString) }
        guard let v = ctx.evaluateScript(code) else { return "" }
        return v.toString() ?? ""
    }
}

/// JS 求值结果：文本 + 原生元素。
/// ⚠️ Jsoup 元素**不能**走 JSON 序列化 —— `JSON.stringify` 对它们只会输出 `[{},{}]`
/// （JsoupEl 没有可枚举的 JS 属性），元素信息全丢，外层就拿不到节点了。
struct JSOutcome {
    var text: String = ""
    var elements: [Element] = []
    /// JS 抛出的异常原文（没抛异常则为 nil）。
    ///
    /// 🔴 为什么必须带出来：`exceptionHandler` 以前只写 DiagLog，
    ///    而规则调试器拿不到 → 用户写错一条 JS 规则时**只看到「规则没命中」**，
    ///    完全不知道是 `x.size is not a function` 还是别的。
    ///    规则调试器的 JS 模式靠它把真实原因显示出来。
    var error: String? = nil
    /// 规则里 `hmd.toast(...)` / `java.log(...)` 打印的内容（按调用顺序）。
    ///
    /// 🔴 这两个方法以前是**空实现**，写 JS 规则时想打印中间值完全没辙。
    ///    现在被捕获下来，规则调试器的 JS 模式会把它们列出来 —— 相当于 `console.log`。
    var logs: [String] = []
}

extension JSEvaluator {
    /// 给 JS 数组补上 Jsoup `Elements` 的 API。
    ///
    /// ⚠️ 真实图源规则大量使用 `doc.select(...).toArray()`（实测 67 次）、`.get(i)`（46 次）、
    /// `.size()`（8 次）、`.first()/.last()/.eachText()/.outerHtml()` —— 这些是 Jsoup 的
    /// Elements 方法，普通 JS 数组没有，一调用就抛 TypeError，整个规则返回空。
    /// 「包子漫画」等 31 个源的章节列表就是这么挂成 0 条的。
    ///
    /// 这里选择**扩展现有数组**而不是把 select() 换成 Elements 对象：规则里同时还在用
    /// `.map()/.slice()/.concat()/.forEach()` 等原生数组方法，换成对象会把那些弄坏。
    static let jsoupPrologue = """
    (function(){
      var g = this;
      var P = Array.prototype;
      if (!P.__hmdPatched) {
        Object.defineProperty(P, '__hmdPatched', {value: true, enumerable: false});
        var def = function(n, f){
          if (typeof P[n] === 'function') return;
          Object.defineProperty(P, n, {value: f, enumerable: false, writable: true, configurable: true});
        };
        var txt = function(e){ return (e && typeof e.text === 'function') ? e.text() : ''; };
        var out = function(e){ return (e && typeof e.outerHtml === 'function') ? e.outerHtml() : ''; };
        def('size',      function(){ return this.length; });
        def('isEmpty',   function(){ return this.length === 0; });
        def('toArray',   function(){ return Array.prototype.slice.call(this); });
        def('get',       function(i){ return this[i]; });
        def('first',     function(){ return this[0]; });
        def('last',      function(){ return this[this.length - 1]; });
        def('eachText',  function(){ return this.map(txt); });
        def('text',      function(){ return this.map(txt).join(' '); });
        def('html',      function(){ var a = this; return a.map(function(e){ return (e && typeof e.html === 'function') ? e.html() : ''; }).join('\\n'); });
        def('outerHtml', function(){ return this.map(out).join('\\n'); });
        def('attr',      function(k){ return (this.length && this[0].attr) ? this[0].attr(k) : ''; });
        def('hasAttr',   function(k){ return (this.length && this[0].hasAttr) ? this[0].hasAttr(k) : false; });
        def('select',    function(css){ var r = []; for (var i = 0; i < this.length; i++){ var x = this[i].select(css); if (x) r = r.concat(x); } return r; });
        var origToString = P.toString;
        Object.defineProperty(P, 'toString', {enumerable: false, writable: true, configurable: true, value: function(){
          if (this.length && this[0] && typeof this[0].outerHtml === 'function') { return this.map(out).join('\\n'); }
          return origToString.call(this);
        }});
      }
      // Rhino 兼容：规则里常见 importPackage(Packages.org.jsoup)，这里把类挂到全局即可
      // 注意必须防御 org 尚未注入的情况（prologue 可能先于 org 执行）
      var J = (typeof org !== 'undefined' && org && org.jsoup) ? org.jsoup.Jsoup : null;
      g.importPackage = function(p){ try {
        var n = String(p).split('.').pop();
        if ((n === 'jsoup' || n === 'Jsoup') && J) { g.Jsoup = J; }
      } catch(e){} };
      g.importClass = g.importPackage;
      // ⚠️ 不要覆盖 Packages —— evaluate() 已注入 java/android/javax 占位（Bitmap 系用），
      //    这里只确保 org.jsoup 就位。
      if (!g.Packages) g.Packages = {};
      if (!g.Packages.org) g.Packages.org = { jsoup: { Jsoup: J } };
      else if (!g.Packages.org.jsoup) g.Packages.org.jsoup = { Jsoup: J };
      // ── Bitmap 同名不同参重载：`createBitmap(w,h,cfg)` vs `createBitmap(src,x,y,w,h)` ──
      // JavaScriptCore 不支持 ObjC 方法重载，这里包装成按参数个数分发。
      if (typeof __hmdBitmapCreate !== 'undefined' && __hmdBitmapCreate && !g.Bitmap) {
        g.Bitmap = function(){};
        g.Bitmap.createBitmap = function(){
          var a = arguments;
          if (a.length >= 5) return __hmdBitmapCreate.crop(a[0], a[1], a[2], a[3], a[4]);
          return __hmdBitmapCreate.blank(a[0], a[1]);
        };
        g.Bitmap.Config = { ARGB_8888: 1, RGB_565: 2, ALPHA_8: 3 };
        g.Bitmap.CompressFormat = { PNG: 'png', JPEG: 'jpeg', WEBP: 'webp' };
      }
      // ── java.security.MessageDigest 替身 ──
      // 🔴 规则里 `MessageDigest.getInstance("MD5")` 很常见（签名参数、防盗链 token），
      //    真机日志实测 `ReferenceError: Can't find variable: MessageDigest`
      //    → 整条规则抛错 → 该源解析失败。这里用 HMD 桥的 md5 实现补上，
      //    并把 `digest()` 的返回做成 **byte[] 语义**（Java 侧就是 byte[]）。
      if (typeof g.MessageDigest === 'undefined' && typeof hmd !== 'undefined' && hmd && hmd.md5) {
        g.MessageDigest = function(){};
        g.MessageDigest.getInstance = function(alg){
          var a = String(alg || 'MD5').toUpperCase();
          return {
            digest: function(bytes){
              // 统一按字节数组喂给 md5（JS 侧给字符串也兼容）
              var hex = hmd.md5(bytes);
              var out = [];
              for (var i = 0; i + 1 < hex.length; i += 2) out.push(parseInt(hex.substr(i, 2), 16));
              return out;
            },
            toString: function(){ return '[MessageDigest ' + a + ']'; }
          };
        };
      }
    })();
    """

    /// 从 JS 返回值里提取 Jsoup 元素（单个元素 / 元素数组都支持）
    static func elementsFrom(_ v: JSValue) -> [Element] {
        if let e = v.toObject() as? JsoupEl { return [e.el] }
        if let arr = v.toObject() as? [Any] {
            let els = arr.compactMap { ($0 as? JsoupEl)?.el }
            if !els.isEmpty { return els }
        }
        if v.isArray {
            let n = Int(v.forProperty("length")?.toInt32() ?? 0)
            var out: [Element] = []
            for i in 0..<n {
                if let e = v.atIndex(i)?.toObject() as? JsoupEl { out.append(e.el) }
            }
            return out
        }
        return []
    }
}

extension JSEvaluator {
    /// - Parameter resultAsObject: 把 `result` 绑成 JS 对象/数组（而不是原始字符串）。
    ///   对齐安卓 `WrapForJS(this.object)`：**只有 `this.object` 本身是 Map/List 时才转对象**。
    ///   安卓的 `this.object` 在两种情形下是 Map/List：
    ///   ① 章节/搜索列表的**节点**来自 JSONPath 查询（`Cnew.m26009if` 里 `setContent(…, node, …)`）；
    ///   ② 上一段规则已经产出了对象。
    ///   其余情形（HTTP 响应体 = 字符串）`WrapForJS` 原样返回字符串 —— 所以
    ///   `RULE_BOOK_CONTENT = "@js:…JSON.parse(result)…"` 这类规则必须拿到**字符串**。
    ///   ⚠️ 曾经无条件把 JSON 文本预解析成对象，导致 `JSON.parse(result)` 变成
    ///   `JSON.parse("[object Object]")` → 正文图片解码全挂。
    /// - Parameter resultAsObject: 把 `result` 绑成 JS 对象/数组（而不是原始字符串）。
    /// - Parameter resultBytes: 把 `result` 绑成**字节数组**（`byte[]` 语义，普通 Number 数组）。
    ///   用于 `RULE_BOOK_CONTENT_DECODER` —— 安卓 `setContent(headers, byte[], url)` 传的就是
    ///   `byte[]`，规则里 `java.decryptESBytes(…, result, …)` / `BitmapFactory.decodeByteArray(result,…)`
    ///   都按字节数组消费。Swift 侧 `Data` 桥到 JS 会变 NSData 对象，规则拿不到 `.length`，
    ///   故显式转成 `[Int]` 再桥（JSFoundation 会把 `[Int]` 映射成 JS 数组）。
    func evaluate(_ code: String, java: AnalyzeRule?, result: String, baseUrl: String,
                  variables: [String: String], headers: [String: String] = [:],
                  resultAsObject: Bool = false, resultBytes: [UInt8]? = nil,
                  allowedDomains: Set<String>? = nil) async -> JSOutcome {
        // ⚠️ 关键：把「创建 JSContext + 跑脚本 + 桥内同步等网络」整段搬到专属串行队列。
        // 桥里 `java.get/fetch` 的同步阻塞因此发生在**专属线程**上，而不是
        // Swift 并发的协作线程池 —— 否则多个图源并发解析时协作线程会被占满，
        // 连网络请求本身都拿不到线程（详见 JSExecQueue 的注释）。
        //
        // JSContext 在闭包内创建、闭包内销毁，不跨线程传递（JSC 上下文不能跨线程共享）。
        return await JSExecQueue.shared.run { [weak java] in
            self.evaluateSync(code, java: java, result: result, baseUrl: baseUrl,
                              variables: variables, headers: headers,
                              resultAsObject: resultAsObject, resultBytes: resultBytes,
                              allowedDomains: allowedDomains)
        }
    }

    /// 真正的 JS 求值（**只允许在 JSExecQueue 的专属线程上运行**）。
    private func evaluateSync(_ code: String, java: AnalyzeRule?, result: String, baseUrl: String,
                              variables: [String: String], headers: [String: String],
                              resultAsObject: Bool, resultBytes: [UInt8]?,
                              allowedDomains: Set<String>?) -> JSOutcome {
        // ⚠️ 不用 `JSContext()!`：极端内存压力下它会返回 nil，
        //    强制解包 = 直接闪退（这类崩溃无法被上层 catch）。
        guard let ctx = JSContext() else { return JSOutcome(error: "JSContext 创建失败（内存不足）") }
        ctx.exceptionHandler = { _, _ in /* 静默：与原版 Rhino 出错返回空一致 */ }
        if let bytes = resultBytes {
            // byte[] → JS 普通数组（Number[]）。Java 的 `result.length` / 下标访问才能用。
            ctx.setObject(bytes.map { Int($0) }, forKeyedSubscript: "result" as NSString)
        } else if resultAsObject,
           let d = result.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]),
           JSONSerialization.isValidJSONObject(obj) {
            // 在 JS 侧 JSON.parse，得到**纯 JS 对象/数组**（对齐 WrapForJS 的 NativeObject），
            // 而不是桥接 NSDictionary —— 后者 `result.url` 点号取值不可靠。
            let s = (try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
            ctx.setObject(s, forKeyedSubscript: "__hmdJson" as NSString)
            ctx.evaluateScript("var result = JSON.parse(__hmdJson); delete __hmdJson;")
        } else {
            // 默认：原始字符串（HTML / JSON 文本 / 纯文本），与安卓 this.object 为 String 时一致
            ctx.setObject(result, forKeyedSubscript: "result" as NSString)
        }
        ctx.setObject(baseUrl, forKeyedSubscript: "baseUrl" as NSString)
        ctx.setObject(headers, forKeyedSubscript: "headers" as NSString)

        let ext = HMDJSBridge()
        ctx.setObject(ext, forKeyedSubscript: "_" as NSString)
        ctx.setObject(ext, forKeyedSubscript: "hmd" as NSString)
        // ObjC 桥不补默认参数：JS 里 `hmd.toBytes("abc")` 只传 1 个，`enc` 会拿到 undefined。
        // 包一层把缺省补成 "UTF-8"，避免桥接层收到 nil。
        //
        // 🔴🔴 **必须用 `.call(g.hmd, ...)` 保留接收者** —— 这里踩过一个很隐蔽的坑：
        //    旧写法先把方法取出来（`var f = g.hmd[n]`），再裸调用 `f(a, b)`。
        //    在 JavaScriptCore 里，ObjC 桥方法（JSExport）**必须带正确的 `this`**，
        //    裸调用会让 `this` 变成 undefined，抛
        //      `TypeError: self type check failed for Objective-C instance method`
        //    —— 报错信息完全没提「this」，极难定位。
        //    后果：`hmd.toBytes` / `hmd.fromBytes` **一直是坏的**
        //    （2026-10-15 排查 manhua3.com 的正文规则时才发现：那条规则
        //      用 `hmd.fromBytes(bytes,'UTF-8')` 解 UTF-8，异常就出在这里）。
        //    其它桥方法没被这个包装器覆盖，所以一直正常 —— 这也解释了
        //    为什么只有这两个方法坏。
        ctx.evaluateScript("""
        (function(){
          var g = this;
          ['toBytes','fromBytes'].forEach(function(n){
            var f = g.hmd[n];
            if (typeof f !== 'function') return;
            g.hmd[n] = function(a, b){
              var enc = (b === undefined || b === null) ? 'UTF-8' : b;
              return f.call(g.hmd, a, enc);
            };
          });
        })();
        """)

        // 🔴 白名单必须真的传进去，否则 `netAllowed` 永远放行（闸门形同虚设）。
        //    JS 源在 manifest 里声明了 `domain`，所以这条通道的白名单是有意义的。
        //    ⚠️ JSON 源的 `@js:` 规则走 `allowedDomains = nil`（不限制）——
        //       那是**有意的**：JSON 规则本来就要跨域取图片 CDN / API，
        //       单域白名单会把正常源打死。这条差异已在文档里写明。
        let bridge: JavaBridge? = java.map { JavaBridge(rule: $0, allowedDomains: allowedDomains) }
        if let bridge { ctx.setObject(bridge, forKeyedSubscript: "java" as NSString) }

        let cookie = CookieJSBridge(baseUrl: baseUrl)
        ctx.setObject(cookie, forKeyedSubscript: "cookie" as NSString)
        ctx.setObject(JsoupOrg(allowedDomains: allowedDomains), forKeyedSubscript: "org" as NSString)
        // ── Android 图形类替身（禁漫/果果等源的图片条带还原用） ──
        // 规则里以 `new JavaImporter(); Magua.importPackage(Packages.java.io, Packages.android.graphics);
        // with(Magua){ BitmapFactory... }` 的形式使用 —— importPackage 的参数内容无所谓，
        // 关键是把这些类名挂到一个对象上，`with` 才能解析到。
        // ── Android 图形类替身（禁漫/果果等源的图片条带还原用）──
        // JS 侧无法直接 `new` Swift 类，故：
        //   ① 这里注入 factory/metaclass 句柄（带 __hmd 前缀，避免和规则变量撞名）；
        //   ② prologue 用它们构建真正的全局 `Bitmap` / `BitmapFactory` / `Canvas` / `ByteArrayOutputStream`；
        //   ③ `JavaImporter` 在**调用时**才去读全局（否则会在 prologue 之前读到 undefined）。
        ctx.setObject(XBitmapStatics(), forKeyedSubscript: "__hmdBitmapCreate" as NSString)
        ctx.setObject(XBitmapFactory(), forKeyedSubscript: "__hmdBitmapFactory" as NSString)
        ctx.setObject(XCanvasFactory(), forKeyedSubscript: "__hmdCanvasFactory" as NSString)
        ctx.evaluateScript("""
        (function(){
          var g = this;
          g.BitmapFactory = g.__hmdBitmapFactory;
          // `new Canvas(bmp)` —— JS 侧用工厂函数模拟构造器（导出 init 不稳）。
          g.Canvas = function(bmp){ return g.__hmdCanvasFactory.make(bmp); };
          g.ByteArrayOutputStream = function(){ return g.__hmdCanvasFactory.newBaos(); };
          // `Packages.java.io` / `Packages.android.graphics` / `Packages.javax.crypto` …
          // 规则只把它们当 importPackage 的实参，取到什么值无所谓 —— 给个自返回的占位。
          var stub = {};
          stub.java = stub; stub.android = stub; stub.javax = stub;
          stub.io = stub; stub.graphics = stub; stub.util = stub;
          stub.lang = stub; stub.security = stub; stub.crypto = stub; stub.spec = stub;
          g.Packages = { java: stub, android: stub, javax: stub,
                         org: { jsoup: { Jsoup: (g.org && g.org.jsoup) ? g.org.jsoup.Jsoup : null } } };
          // 懒读全局：with(Magua) 里用到的类名在调用那一刻才解析
          g.JavaImporter = function(){ return { importPackage: function(){
            return { Bitmap: g.Bitmap, BitmapFactory: g.BitmapFactory,
                     Canvas: g.Canvas, ByteArrayOutputStream: g.ByteArrayOutputStream };
          } }; };
        })();
        """)
        // ⚠️ prologue 必须在 org 注入之后执行（它会引用 org.jsoup.Jsoup），
        //    也必须晚于上面 —— 它负责把 __hmdBitmapCreate 变成 `Bitmap.createBitmap`。
        ctx.evaluateScript(Self.jsoupPrologue)

        // 🔴 必须捕获 JS 异常 —— 以前**完全没有** exceptionHandler：
        //    规则里的 JS 一旦抛错（`x.size is not a function`、`undefined.attr`…），
        //    `evaluateScript` 静默返回 nil → 引擎回退成「把整个 HTML 当结果」→
        //    最终表现为 **「规则(空)」**，而且**日志里查不出任何原因**。
        //    真机实测（2026-10-14）：包子漫画的 `ruleChapterList` 是一段 `@js:`
        //    （`org.jsoup.Jsoup.parse(result)` + `doc.select(...)`），
        //    日志只有 `规则(空)→万用(空) 全落空`，完全不知道 JS 报了什么。
        //    这里把异常写进 DiagLog，下次一眼就能定位。
        var jsError: String? = nil
        ctx.exceptionHandler = { _, ex in
            let msg = ex?.toString() ?? "unknown"
            jsError = msg
            DiagLog.event("js", "error", "JS 抛异常：\(msg.prefix(160))")
        }

        let scriptValue = ctx.evaluateScript(code)
        if jsError != nil { ctx.exceptionHandler = nil }
        var out = JSOutcome()
        // 优先取脚本完成值（如 `out;` 结尾的数组/对象）
        if let sv = scriptValue, !(sv.isUndefined ?? true), !(sv.isNull ?? true) {
            // 元素/元素数组先直取，避免被 JSON 化丢掉
            let els = Self.elementsFrom(sv)
            if !els.isEmpty {
                out.elements = els
            } else if sv.isObject == true {
                ctx.setObject(sv, forKeyedSubscript: "__out" as NSString)
                out.text = ctx.evaluateScript("JSON.stringify(__out)")?.toString() ?? ""
            } else {
                out.text = sv.toString() ?? ""
                if out.text == "undefined" { out.text = "" }
            }
        }
        if out.text.isEmpty && out.elements.isEmpty {
            out.text = ctx.globalObject.objectForKeyedSubscript("result")?.toString() ?? ""
        }
        if let bridge {
            for (k, v) in bridge.pendingPuts { java?.javaPut(k, v) }
        }
        out.error = jsError
        // 规则里打印的内容（hmd.toast / java.log）—— 规则调试器会显示它们
        out.logs = ext.captured + (bridge?.captured ?? [])
        return out
    }
}

/// fetch(url, options) 的响应对象（OkHttp 风格: res.body().string()）
@objc protocol JSResponseExports: JSExport {
    func code() -> Int32
    func body() -> JSResponseBody
    func header(_ name: String) -> String
    func url() -> String
}
final class JSResponse: NSObject, JSResponseExports {
    let data: Data
    let statusCode: Int
    let respUrl: String
    let headers: [String: String]
    init(data: Data, code: Int, url: String, headers: [String: String]) {
        self.data = data; self.statusCode = code; self.respUrl = url; self.headers = headers
    }
    func code() -> Int32 { Int32(statusCode) }
    func body() -> JSResponseBody { JSResponseBody(data: data) }
    func header(_ name: String) -> String { headers[name] ?? headers[name.lowercased()] ?? "" }
    func url() -> String { respUrl }
}
@objc protocol JSResponseBodyExports: JSExport {
    func string() -> String
}
final class JSResponseBody: NSObject, JSResponseBodyExports {
    let data: Data
    init(data: Data) { self.data = data }
    func string() -> String { HttpFetcher.shared.decode(data) }
}

// MARK: - org.jsoup JS 桥（Rhino 规则可直接调用 org.jsoup.Jsoup.parse/connect）

@objc protocol JsoupOrgExports: JSExport {
    var jsoup: JsoupStatic { get }
}
final class JsoupOrg: NSObject, JsoupOrgExports {
    private let allowedDomains: Set<String>?
    /// 惰性缓存：JS 里每次 `org.jsoup.*` 都新建桥会白白增加桥接开销
    private lazy var staticBridge = JsoupStatic(allowedDomains: allowedDomains)
    /// ⚠️ 白名单为 `nil` 时**不限制**（保持 JSON 规则源的既有行为不变）；
    ///    JS 类源会传入 `manifest.domain`，把脚本的网络锁在该域及其子域内。
    init(allowedDomains: Set<String>? = nil) { self.allowedDomains = allowedDomains }
    var jsoup: JsoupStatic { staticBridge }
}

@objc protocol JsoupStaticExports: JSExport {
    func parse(_ html: String) -> JsoupDoc
    func connect(_ url: String) -> JsoupConn
    /// 🔴 **必须暴露 `Jsoup` 这一层** —— Java 里 `org.jsoup` 是**包**、`Jsoup` 是**类**，
    ///    所以规则写的是 `org.jsoup.Jsoup.parse(...)`（三跳）。
    ///    我们以前把 `JsoupStatic`（只有 `parse`/`connect`）直接挂在 `org.jsoup` 上，
    ///    于是 `org.jsoup.Jsoup` 取到 **undefined** → `undefined.parse(...)` →
    ///    **TypeError** → **所有用 `org.jsoup.*` 的 JS 规则全挂**。
    ///
    ///    真机实测（2026-10-14，v43）：
    ///      · 搜索「完美世界」原来几十个源，现在只剩一本；
    ///      · 书架里的《我独自升级》一直「解析失败」；
    ///      · 日志 `TypeError: undefined is not an object
    ///        (evaluating 'org.jsoup.Jsoup.parse')` 与 `…Jsoup.connect…`。
    ///    修法是补一层自引用 —— 这样 `org.jsoup.parse(...)`（两跳）和
    ///    `org.jsoup.Jsoup.parse(...)`（三跳）**两种写法都能用**。
    var Jsoup: JsoupStatic { get }
}
final class JsoupStatic: NSObject, JsoupStaticExports {
    /// 无限制实例（供内部 parse / 既有调用点使用）
    static let shared = JsoupStatic()
    private let allowedDomains: Set<String>?
    init(allowedDomains: Set<String>? = nil) { self.allowedDomains = allowedDomains }

    /// `org.jsoup.Jsoup` → 就是本对象自己（见协议里的说明）
    var Jsoup: JsoupStatic { self }
    func parse(_ html: String) -> JsoupDoc {
        let doc = (try? SwiftSoup.parse(html)) ?? (try? SwiftSoup.parse("<html><body></body></html>"))!
        return JsoupDoc(doc)
    }
    func connect(_ url: String) -> JsoupConn {
        JsoupConn(url: url, allowedDomains: allowedDomains)
    }
}
@objc protocol JsoupConnExports: JSExport {
    func get() -> JsoupDoc
    func header(_ k: String, _ v: String) -> JsoupConn
    func userAgent(_ ua: String) -> JsoupConn
    func referrer(_ r: String) -> JsoupConn
    func timeout(_ ms: Int) -> JsoupConn
}
final class JsoupConn: NSObject, JsoupConnExports {
    let url: String
    var headers: [String: String] = [:]
    private let allowedDomains: Set<String>?
    init(url: String, allowedDomains: Set<String>? = nil) {
        self.url = url
        self.allowedDomains = allowedDomains
    }
    func header(_ k: String, _ v: String) -> JsoupConn { headers[k] = v; return self }
    func userAgent(_ ua: String) -> JsoupConn { headers["User-Agent"] = ua; return self }
    func referrer(_ r: String) -> JsoupConn { headers["Referer"] = r; return self }
    func timeout(_ ms: Int) -> JsoupConn { return self }

    /// 白名单校验：`allowed` 为 nil 放行；否则只允许该域及其子域。
    ///
    /// ⚠️ 拦截时返回**空文档**而不是抛错 —— 对齐原版「JS 出错返回空」的语义，
    ///    让脚本自己走到「无结果」分支，而不是把异常抛进 App。
    ///
    /// 🔴 **无论有没有白名单，`isDeniedAlways` 都先执行。**
    ///    以前 JSON 源的 `@js:` 走 `allowedDomains = nil` → 这里直接 `return true`
    ///    → 白名单对 JSON 源**等于不存在**（安全终审判定：自我安慰）。
    ///    现在改成「域白名单照旧，但恒拒绝清单一律拦」。
    static func isAllowed(_ url: String, _ allowed: Set<String>?) -> Bool {
        if Self.isDeniedAlways(url) { return false }
        guard let allowed else { return true }
        guard let host = URL(string: url)?.host?.lowercased() else { return false }
        for d in allowed {
            let dom = d.lowercased()
            if host == dom || host.hasSuffix("." + dom) { return true }
        }
        return false
    }

    /// 恒生效的拒绝清单（**与 `allowedDomains` 无关**，JSON / JS 源都拦）。
    ///
    /// 🔴 为什么单独一层：JSON 图源的 `@js:` 规则**必须**能跨域取图片 CDN / API，
    ///    给它们套单域白名单会把正常源全部打死，所以那条路只能用「黑名单」模型：
    ///      · 非 http/https scheme（`file://` `data:` `javascript:` 等）
    ///      · URL 里带 userinfo 凭据（`https://user:pass@host` —— 凭据会被送到该 host）
    ///      · 回环 / 私网 / 链路本地 / CGNAT / 组播地址（SSRF 打内网管理面、
    ///        路由器后台、云元数据 `169.254.169.254`）
    ///    只拦**字面量 IP**；域名不在这里同步 DNS 解析（成本高、且规则需求大量合法域名）。
    ///    （由智能体「安全终审」提出）
    static func isDeniedAlways(_ url: String) -> Bool {
        guard let u = URL(string: NetUrl.fixEncoding(url)) else { return true }   // 解析不了 → 拦
        guard let scheme = u.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return true }
        if u.user != nil || u.password != nil { return true }
        guard let host = u.host?.lowercased() else { return true }
        // IPv6 回环 / 唯一本地 / 链路本地
        if host == "::1" || host.hasPrefix("fc") || host.hasPrefix("fd") || host.hasPrefix("fe80") { return true }
        // IPv4 私网/保留段
        let p = host.split(separator: ".").compactMap { Int($0) }
        guard p.count == 4 else { return false }      // 域名：放行
        if p[0] == 127 { return true }                // 回环
        if p[0] == 10 { return true }                 // 10.0.0.0/8
        if p[0] == 192 && p[1] == 168 { return true } // 192.168.0.0/16
        if p[0] == 172 && (16...31).contains(p[1]) { return true }   // 172.16.0.0/12
        if p[0] == 169 && p[1] == 254 { return true } // 链路本地（含云元数据）
        if p[0] == 0 || p[0] == 100 && (64...127).contains(p[1]) { return true }  // 0.0.0.0/8、CGNAT
        if p[0] >= 224 { return true }                // 组播 / 保留
        return false
    }

    func get() -> JsoupDoc {
        guard Self.isAllowed(url, allowedDomains) else {
            return JsoupStatic.shared.parse("<html><body></body></html>")
        }
        // `Jsoup.connect(url).get()` 在 JS 里也是同步语义，同样走 SyncBridge，
        // 阻塞发生在 JSExecQueue 的专属线程上，不占用协作线程池。
        let u = self.url
        let h = self.headers
        let html = SyncBridge.wait(timeout: 25) {
            await HttpFetcher.shared.fetchText(u, headers: h, timeout: 20)
        } ?? ""
        return JsoupStatic.shared.parse(html)
    }
}

@objc protocol JsoupDocExports: JSExport {
    func select(_ css: String) -> [JsoupEl]
    func text() -> String
    func html() -> String
    func attr(_ k: String) -> String
}
final class JsoupDoc: NSObject, JsoupDocExports {
    let doc: Document
    init(_ d: Document) { doc = d }
    func select(_ css: String) -> [JsoupEl] {
        // 走 CssSelect：规则里的 `doc.select("a|b")` 是 Legado 的「或」语法，
        // 直接交给 SwiftSoup 会抛 SelectorParseException（`|` 被当成命名空间）。
        CssSelect.all(doc, css).map { JsoupEl($0) }
    }
    func text() -> String { (try? doc.text()) ?? "" }
    func html() -> String { (try? doc.html()) ?? "" }
    func attr(_ k: String) -> String { (try? doc.attr(k)) ?? "" }
}

@objc protocol JsoupElExports: JSExport {
    func text() -> String
    func ownText() -> String
    func html() -> String
    func outerHtml() -> String
    func attr(_ k: String) -> String
    func hasAttr(_ k: String) -> Bool
    func tagName() -> String
    func id() -> String
    func className() -> String
    func val() -> String
    func select(_ css: String) -> [JsoupEl]
    func get(_ i: Int) -> JsoupEl
    func children() -> [JsoupEl]
    func parent() -> JsoupEl
    func next() -> JsoupEl
    func prev() -> JsoupEl
    func size() -> Int
}
final class JsoupEl: NSObject, JsoupElExports {
    let el: Element
    init(_ e: Element) { el = e }
    func text() -> String { (try? el.text()) ?? "" }
    func ownText() -> String { (try? el.ownText()) ?? "" }
    func html() -> String { (try? el.html()) ?? "" }
    func outerHtml() -> String { (try? el.outerHtml()) ?? "" }
    func attr(_ k: String) -> String { (try? el.attr(k)) ?? "" }
    func hasAttr(_ k: String) -> Bool { el.hasAttr(k) }
    func tagName() -> String { el.tagName() }
    func id() -> String { el.id() }
    func className() -> String { (try? el.className()) ?? "" }
    func val() -> String { (try? el.val()) ?? "" }
    func select(_ css: String) -> [JsoupEl] {
        // 同上：支持 Legado 的 `|` 或语法
        CssSelect.all(el, css).map { JsoupEl($0) }
    }
    /// 取第 i 个子元素（原来错写成 `el.select("*")`，那会把所有后代都当成子元素）
    func get(_ i: Int) -> JsoupEl {
        let kids = (try? el.children())?.array() ?? []
        return kids.indices.contains(i) ? JsoupEl(kids[i]) : JsoupEl(el)
    }
    func children() -> [JsoupEl] { ((try? el.children())?.array() ?? []).map { JsoupEl($0) } }
    func parent() -> JsoupEl { el.parent().map { JsoupEl($0) } ?? JsoupEl(el) }
    func next() -> JsoupEl { (try? el.nextElementSibling()).flatMap { $0 }.map { JsoupEl($0) } ?? JsoupEl(el) }
    func prev() -> JsoupEl { (try? el.previousElementSibling()).flatMap { $0 }.map { JsoupEl($0) } ?? JsoupEl(el) }
    func size() -> Int { 1 }
}

/// `_` / `hmd` 扩展（对应 AnalyzeHMDJS）
@objc protocol HMDJSExports: JSExport {
    /// `hmd.MD5(x)` —— `x` 可能是字符串，也可能是 `hmd.toBytes(...)` 出来的字节数组。
    /// 字节数组必须按**原始字节**做 MD5（先 UTF-8 解码会破坏字节，结果就错了）。
    /// ⚠️ 不能声明成两个 ObjC 重载 —— `md5(_: String)` 与 `md5(_: [Int])` 的 selector
    ///    都是 `md5:`，编译期直接冲突。故这里用 `Any` 收口再分派。
    func md5(_ input: Any) -> String
    func sha(_ s: String) -> String
    func encrypt(_ data: String, _ mode: String, _ key: String) -> String
    func decrypt(_ data: String, _ mode: String, _ key: String) -> String
    func atob(_ s: String) -> String
    func btoa(_ s: String) -> String
    func toast(_ msg: String) -> String
    func help() -> String
    func toBytes(_ s: String, _ enc: String) -> [Int]
    func fromBytes(_ bytes: [Int], _ enc: String) -> String
    func MD5ToBytes(_ s: String) -> [Int]
    func SHAToBytes(_ s: String) -> [Int]
    func atobToBytes(_ s: String) -> [Int]
    /// 🔴 独立 key + IV 的 AES-CBC 解密（base64 密文 → 明文字符串）。
    ///
    /// 为什么现有的 `decrypt(data, mode, key)` 不够用：它是**从同一个字符串**
    /// 里切 `prefix(16)` 当 key、`suffix(16)` 当 IV 的（对齐安卓绘漫岛的写法）。
    /// 而很多站点（如 manhua3.com）的 key 与 IV 是**两个独立的 hex 串**，
    /// 拼成一个字符串再切会得到完全错误的 IV → 解密出乱码。
    ///
    /// - Parameters:
    ///   - key: 密钥，hex（32 位十六进制 = 16 字节）或直接 16 字符 ASCII
    ///   - iv:  初始向量，hex（32 位）或 16 字符 ASCII；传空串表示全 0
    ///   - data: base64 密文（容忍 URL-safe / 无填充）
    func aesDecryptCBC(_ key: String, _ iv: String, _ data: String) -> String
    /// 同上，但返回 **UTF-8 字节数组**（解密结果是二进制时用）
    func aesDecryptCBCBytes(_ key: String, _ iv: String, _ data: String) -> [Int]
}
final class HMDJSBridge: NSObject, HMDJSExports {
    func md5(_ input: Any) -> String {
        // `[Int]` / `[NSNumber]` → 按原始字节做 MD5；其余一律当字符串。
        if let arr = input as? [Int] {
            let d = Data(arr.map { UInt8(truncatingIfNeeded: $0) })
            return Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined()
        }
        if let arr = input as? [NSNumber] {
            let d = Data(arr.map { UInt8(truncatingIfNeeded: $0.intValue) })
            return Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined()
        }
        let s = (input as? String) ?? String(describing: input)
        return Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func sha(_ s: String) -> String {
        Insecure.SHA1.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func encrypt(_ data: String, _ mode: String, _ key: String) -> String {
        let parts = mode.split(separator: "/").map(String.init)
        let isCBC = parts.count > 1 ? parts[1].uppercased() == "CBC" : true
        var padded = Array(data.utf8)
        let pad = 16 - padded.count % 16
        padded.append(contentsOf: [UInt8](repeating: UInt8(pad), count: pad))
        if isCBC {
            let iv = key.count > 16 ? String(key.suffix(16)) : Qk9Keys.aesIV
            let k = String(key.prefix(16))
            guard let enc = AESCBCCrypt.run(Data(padded), key: Array(k.utf8), iv: Array(iv.utf8), encrypt: true) else { return "" }
            return Data(enc).base64EncodedString()
        }
        guard let enc = AESECB.run(Data(padded), key: Array(key.utf8)) else { return "" }
        return Data(enc).base64EncodedString()
    }
    func decrypt(_ data: String, _ mode: String, _ key: String) -> String {
        let parts = mode.split(separator: "/").map(String.init)
        let isCBC = parts.count > 1 ? parts[1].uppercased() == "CBC" : true
        guard let d = SourceDecrypt.base64Flexible(data) else { return "" }
        if isCBC {
            let iv = key.count > 16 ? String(key.suffix(16)) : Qk9Keys.aesIV
            let k = String(key.prefix(16))
            guard let dec = AESCBCCrypt.run(d, key: Array(k.utf8), iv: Array(iv.utf8), encrypt: false) else { return "" }
            return String(data: Data(dec), encoding: .utf8) ?? ""
        }
        guard let dec = AESECB.run(d, key: Array(key.utf8)) else { return "" }
        return String(data: dec, encoding: .utf8) ?? ""
    }
    func atob(_ s: String) -> String {
        guard let d = SourceDecrypt.base64Flexible(s) else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }

    // MARK: - 独立 key/IV 的 AES-CBC（见协议里的说明）

    /// hex 串 → 字节；不是 hex 就按 UTF-8 取字节。
    private func keyBytes(_ s: String) -> [UInt8] {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let isHex = t.count % 2 == 0 && !t.isEmpty
            && t.allSatisfy { $0.isHexDigit }
        if isHex, t.count == 32 || t.count == 48 || t.count == 64 {
            var out: [UInt8] = []
            var i = t.startIndex
            while i < t.endIndex {
                let n = t.index(i, offsetBy: 2, limitedBy: t.endIndex) ?? t.endIndex
                if let b = UInt8(t[i..<n], radix: 16) { out.append(b) }
                i = n
            }
            return out
        }
        return Array(t.utf8)
    }

    func aesDecryptCBCBytes(_ key: String, _ iv: String, _ data: String) -> [Int] {
        guard let d = SourceDecrypt.base64Flexible(data) else { return [] }
        var k = keyBytes(key)
        if k.count > 16 { k = Array(k.prefix(16)) }        // AES-128
        while k.count < 16 { k.append(0) }
        var v = iv.isEmpty ? [UInt8](repeating: 0, count: 16) : keyBytes(iv)
        if v.count > 16 { v = Array(v.prefix(16)) }
        while v.count < 16 { v.append(0) }
        guard let dec = AESCBCCrypt.run(d, key: k, iv: v, encrypt: false) else { return [] }
        return dec.map { Int($0) }
    }

    func aesDecryptCBC(_ key: String, _ iv: String, _ data: String) -> String {
        let bytes = aesDecryptCBCBytes(key, iv, data)
        guard !bytes.isEmpty else { return "" }
        return String(data: Data(bytes.map { UInt8(truncatingIfNeeded: $0) }), encoding: .utf8) ?? ""
    }
    func btoa(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
    /// 规则里的 `hmd.toast(...)` —— 捕获下来供规则调试器显示（真机上没有 UI 弹窗，
    /// 原来的空实现等于「写进去就没了」，调 JS 规则时完全看不到值）。
    private(set) var captured: [String] = []
    func toast(_ msg: String) -> String {
        captured.append(msg)
        DiagLog.event("js", "print", msg.prefix(200).description)
        return msg
    }
    func help() -> String { return "" }
    func toBytes(_ s: String, _ enc: String) -> [Int] {
        let e = enc.lowercased()
        var data: Data
        switch e {
        case "hex":
            var d = Data(); var i = s.startIndex
            while i < s.endIndex { let n = s.index(i, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex; if let b = UInt8(s[i..<n], radix: 16) { d.append(b) }; i = n }
            data = d
        case "base64": data = SourceDecrypt.base64Flexible(s) ?? Data()
        case "gbk": data = s.data(using: .gbk) ?? Data()
        default: data = Data(s.utf8)
        }
        return data.map { Int($0) }
    }
    func fromBytes(_ bytes: [Int], _ enc: String) -> String {
        let data = Data(bytes.map { UInt8(max(0, min(255, $0))) })
        let e = enc.lowercased()
        switch e {
        case "hex": return data.map { String(format: "%02x", $0) }.joined()
        case "base64": return data.base64EncodedString()
        case "gbk": return String(data: data, encoding: .gbk) ?? ""
        default: return String(data: data, encoding: .utf8) ?? ""
        }
    }
    func MD5ToBytes(_ s: String) -> [Int] { Array(Insecure.MD5.hash(data: Data(s.utf8))).map { Int($0) } }
    func SHAToBytes(_ s: String) -> [Int] { Array(Insecure.SHA1.hash(data: Data(s.utf8))).map { Int($0) } }
    func atobToBytes(_ s: String) -> [Int] { (SourceDecrypt.base64Flexible(s) ?? Data()).map { Int($0) } }
}

/// 在**专属串行队列**上执行「含同步阻塞的 JS 求值」，把阻塞与协作线程池彻底隔离。
///
/// ── 为什么必须有它（踩过血坑）──────────────────────────────────────────
/// `java.get(url)` / `java.fetch(...)` 在 JS 里是**同步调用**：`JavaScriptCore`
/// 的 `evaluateScript` 必须在同一线程上从头跑到尾，桥方法返回前不能退出 ——
/// 所以桥内部天生要把 async 的网络结果「同步等」回来。
///
/// 旧实现直接在**调用线程**上 `DispatchSemaphore.wait()`。而 `AnalyzeRule`
/// 的整条求值链（JS 求值 → 桥 → 网络）本身跑在 Swift 并发的**协作线程池**上：
/// 在协作线程上阻塞 = 占住一个协作线程直到网络返回。协作线程数 ≈ CPU 核数，
/// 几个图源同时解析、每源多个 `java.get` 嵌套 → **协作线程池被占满** →
/// 连它自己要等的那个网络请求都拿不到线程 → 死锁 / 奇慢。
/// 用户实测的「章节解析不出来 / 图片几分钟不出来」，相当一部分是这个原因。
///
/// ── 现在的做法 ────────────────────────────────────────────────────────
/// 把「跑 JS + 桥里同步等网络」整段搬到**一条专属串行队列**的线程上执行：
///   · 协作线程发起 `run { … }` 后只留下一个 `await`（挂起，不占用线程）；
///   · 专属队列线程负责跑 JSC 与桥的阻塞等待；
///   · 桥内 `wait()` 阻塞的是**专属线程**，网络请求所需的协作线程全程空闲；
///   · 结果算完后 resume 协作线程。
///
/// ⚠️ `run` 的闭包用 `UncheckedBox` 收口：闭包与返回值都**不跨线程共享**，
///    它们只在这条队列上被使用一次，随后即丢弃 —— 因此是安全的。
///
/// ── 为什么是「有界并发」而不是串行队列 ─────────────────────────────────
/// 规则里 `java.getString(rule, true)` / `java.getStringList(rule)` 会**在 JS 求值
/// 过程中再次触发规则求值**（→ 再次进入本队列）。若这里是串行队列：
///   · 外层 JS 在专属线程上 `SyncBridge.wait` 等内层的网络结果；
///   · 内层的 `run` 想进同一条串行队列 —— 但那个线程正被外层占着 → **死锁**。
/// 改成并发宽度 = 4 的队列后，内层能拿到另一个槽并行推进，天然解开嵌套。
/// （`JSContext` 每次 `evaluate` 都新建、互不共享，本就不要求串行。）
/// ⚠️ 宽度不能太大：真正跑 JS 的线程数受 `SyncBridge` 里协作线程池的供给约束，
///    4 与图片并发上限一致，够用且不制造新的拥塞。
/// ⚠️ 标 `@unchecked Sendable`：内部状态只有 `queue` / `key` / `slots`，
///    前两者构造后不可变，`DispatchSemaphore` 本身线程安全。
///    不标的话，`withCheckedContinuation` 里 `queue.async { ... self ... }`
///    的 `@Sendable` 闭包捕获 `self` 会告警（Swift 6 下报错）。
final class JSExecQueue: @unchecked Sendable {
    static let shared = JSExecQueue()
    private let queue = DispatchQueue(label: "hmd.js-eval", qos: .userInitiated,
                                      attributes: .concurrent)
    private let key = DispatchSpecificKey<UInt8>()
    /// 并发宽度：超过就排队（用信号量限流，避免无限起线程）。
    /// ⚠️ 取 8 而不是 4：一次 JS 求值可能嵌套 2~3 层（`java.getString(rule,true)`），
    ///    外层每层都持着 1 个槽阻塞等内层。槽太少会让内层永远排不到 → 死锁。
    ///    8 足以覆盖「4 个图源并发 × 2 层嵌套」的实际峰值。
    private let slots = DispatchSemaphore(value: 8)

    private init() {
        queue.setSpecific(key: key, value: 1)
    }

    /// 是否正运行在专属线程上（用于重入时改走同步执行）
    private var onQueue: Bool { DispatchQueue.getSpecific(key: key) != nil }

    /// 在专属线程上执行 `body`（其中可含阻塞），对调用者表现为普通 async 方法。
    /// 若调用者已经在专属线程上（重入），则直接同步执行，少一层调度。
    func run<T>(_ body: @escaping () -> T) async -> T {
        if onQueue { return body() }        // 重入：就地执行，省一次调度
        let box = UncheckedBox(body)
        return await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            queue.async {
                self.slots.wait()
                let v = box.value()
                self.slots.signal()
                cont.resume(returning: v)
            }
        }
    }
}

/// 把「非 Sendable 的闭包」安全地交给一条专属串行队列执行一次。
/// 闭包只在该队列线程上被调用，不外泄、不并发访问，故用 `@unchecked Sendable`。
final class UncheckedBox<T>: @unchecked Sendable {
    private let body: () -> T
    init(_ body: @escaping () -> T) { self.body = body }
    func value() -> T { body() }
}

/// 在专属线程上阻塞等待一个 async 结果（**专供 JSExecQueue 内部调用**）。
///
/// 调用者已经是专属线程，所以这里的阻塞不会占用协作线程池。
/// 若从协作线程误用，会退化为占用协作线程 —— 故仅限内部使用。
enum SyncBridge {
    /// 同步等 `f()` 的结果。`timeout` 秒后放弃，返回 nil。
    static func wait<T>(timeout: TimeInterval, _ f: @escaping () async -> T?) -> T? {
        let sem = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task {
            let v = await f()
            box.set(v)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout)
        return box.get()
    }
}

/// 线程安全的一次性结果槽
final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    private var has = false
    func set(_ v: T?) {
        lock.lock(); value = v; has = true; lock.unlock()
    }
    func get() -> T? {
        lock.lock(); defer { lock.unlock() }
        return has ? value : nil
    }
}

/// java 桥 —— 对齐 Legado JsExtensions（按参数个数重载：1参 get=变量，2参 get=网络请求）
@objc protocol JavaExports: JSExport {
    func get(_ key: String) -> String
    func get(_ url: String, headers: [String: String]) -> String
    func put(_ key: String, _ value: String)
    func ajax(_ url: String) -> String
    func post(_ url: String, _ body: String) -> String
    func post(_ url: String, _ body: String, headers: [String: String]) -> String
    func postForm(_ url: String, _ body: String) -> String
    func postJson(_ url: String, _ json: String) -> String
    func fetch(_ url: String, _ options: NSDictionary) -> JSResponse
    func getString(_ url: String) -> String
    func getString(_ rule: String, _ isRule: Bool) -> String
    func getStringList(_ rule: String) -> [String]
    func aJax(_ url: String) -> String
    func base64Encoder(_ s: String) -> String
    func base64Decoder(_ s: String) -> String
    func getBytes(_ url: String) -> [Int]
    func toast(_ msg: String)
    func getWebViewResult(_ url: String) -> String
    func log(_ msg: String)
    /// `java.decryptESBytes(mode, charset, data, key, iv)` —— 字节级 AES 加解密。
    /// 漫蛙/禁漫等 17 个源用它解 `RULE_BOOK_CONTENT_DECODER`（加密图片字节）。
    /// 入参/出参都是 `byte[]`（JS 侧是普通 Number 数组），与安卓 `AnalyzeHMDJS` 一致。
    func decryptESBytes(_ mode: String, _ charset: String, _ data: [Int], _ key: String, _ iv: String) -> [Int]
}
final class JavaBridge: NSObject, JavaExports {
    private weak var rule: AnalyzeRule?
    var pendingPuts: [String: String] = [:]

    /// 域名白名单 —— 与 `JsoupConn` **共用同一套规则**。
    ///
    /// 🔴 以前白名单只挂在 `org.jsoup.connect()` 上，而
    ///    `java.ajax` / `get(url,headers)` / `post*` / `fetch` / `getString` /
    ///    `getBytes` / `getWebViewResult` 与 cookie 桥**全部绕过** ——
    ///    等于白名单形同虚设：导入一个恶意图源，脚本即可**任意出网**，
    ///    甚至带上用户的 Cookie 发请求。（由智能体「守卫」发现，属可利用的严重项）
    private let allowedDomains: Set<String>?

    init(rule: AnalyzeRule, allowedDomains: Set<String>? = nil) {
        self.rule = rule
        self.allowedDomains = allowedDomains
    }

    /// 出网统一闸门（放行/拦截语义与 `JsoupConn.isAllowed` 完全一致：
    /// 白名单为 nil 时放行，否则只允许该域及其子域）。
    private func netAllowed(_ url: String) -> Bool {
        JsoupConn.isAllowed(url, allowedDomains)
    }

    // 变量
    func get(_ key: String) -> String { rule?.javaGet(key) ?? "" }
    func put(_ key: String, _ value: String) { pendingPuts[key] = value }

    // 网络
    func get(_ url: String, headers: [String: String]) -> String {
        guard netAllowed(url) else { return "" }
        return blockString { await HttpFetcher.shared.fetchText(url, headers: headers) }
    }
    func ajax(_ url: String) -> String {
        guard netAllowed(url) else { return "" }
        return blockString { await HttpFetcher.shared.fetchText(url) }
    }
    func post(_ url: String, _ body: String) -> String {
        guard netAllowed(url) else { return "" }
        return blockString { await HttpFetcher.shared.fetchText(url, method: "POST", body: body) }
    }
    func post(_ url: String, _ body: String, headers: [String: String]) -> String {
        guard netAllowed(url) else { return "" }
        return blockString { await HttpFetcher.shared.fetchText(url, method: "POST", body: body, headers: headers) }
    }
    func postForm(_ url: String, _ body: String) -> String {
        guard netAllowed(url) else { return "" }
        return blockString { await HttpFetcher.shared.fetchText(url, method: "POST", body: body,
                    headers: ["Content-Type": "application/x-www-form-urlencoded"]) }
    }
    func postJson(_ url: String, _ json: String) -> String {
        guard netAllowed(url) else { return "" }
        return blockString { await HttpFetcher.shared.fetchText(url, method: "POST", body: json,
                    headers: ["Content-Type": "application/json"]) }
    }
    /// OkHttp 风格 fetch：java.fetch(url, {method, body, headers}) → res.body().string()
    func fetch(_ url: String, _ options: NSDictionary) -> JSResponse {
        blockResponse {
            let method = (options["method"] as? String ?? "GET").uppercased()
            let hh = options["headers"] as? [String: String] ?? [:]
            let body = options["body"] as? String
            guard self.netAllowed(url) else {
                return JSResponse(data: Data(), code: 0, url: url, headers: hh)
            }
            let data = await HttpFetcher.shared.fetchData(url, method: method, body: body, headers: hh)
            return JSResponse(data: data, code: data.isEmpty ? 0 : 200, url: url, headers: hh)
        }
    }
    // getString: 1参=HTTP GET（安卓语义）；getString(rule,true)=规则求值
    func getString(_ url: String) -> String {
        guard netAllowed(url) else { return "" }
        return blockString { await HttpFetcher.shared.fetchText(url, headers: self.rule?.ctx.headers ?? [:]) }
    }
    func getString(_ x: String, _ isRule: Bool) -> String {
        if isRule {
            return blockString { await self.rule?.getString(x) ?? "" }
        }
        guard netAllowed(x) else { return "" }
        return blockString { await HttpFetcher.shared.fetchText(x, headers: self.rule?.ctx.headers ?? [:]) }
    }
    func getStringList(_ r: String) -> [String] {
        blockList { await self.rule?.getStringList(r) ?? [] }
    }
    func aJax(_ url: String) -> String {
        guard netAllowed(url) else { return "" }
        return blockString { await HttpFetcher.shared.fetchText(url) }
    }
    func base64Encoder(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
    func base64Decoder(_ s: String) -> String {
        guard let d = SourceDecrypt.base64Flexible(s) else { return "" }
        return String(data: d, encoding: .utf8) ?? ""
    }
    func getBytes(_ url: String) -> [Int] {
        guard netAllowed(url) else { return [] }
        return blockList2 { await HttpFetcher.shared.fetchData(url).map { Int($0) } }
    }
    /// 字节级 AES 解密（对齐安卓 `AnalyzeHMDJS.decryptESBytes`）。
    /// 出参是普通 Number 数组 —— JS 规则随后会 `BitmapFactory.decodeByteArray(result,…)` 或
    /// 直接 `return` 成新图片字节。
    func decryptESBytes(_ mode: String, _ charset: String, _ data: [Int], _ key: String, _ iv: String) -> [Int] {
        let bytes = data.map { UInt8(truncatingIfNeeded: $0) }
        let kb = Array(key.utf8)
        let ivb = Array(iv.utf8)
        // key 长度非 16/24/32 时按 Java 行为直接失败（返回原数据）
        guard [16, 24, 32].contains(kb.count) else { return data }
        guard let out = AESAny.run(Data(bytes), key: Data(kb), iv: Data(ivb), mode: mode, decrypt: true) else {
            return data
        }
        return out.map { Int($0) }
    }
    /// 规则里的 `java.toast(...)` / `java.log(...)` —— 同 `hmd.toast`，捕获供调试器显示。
    private(set) var captured: [String] = []
    func toast(_ msg: String) {
        captured.append(msg)
        DiagLog.event("js", "print", msg.prefix(200).description)
    }
    func getWebViewResult(_ url: String) -> String {
        // 🔴 这一路直穿 `WebViewRuleEngine`（真实 WKWebView 加载任意 URL），
        //    是 11 个出网方法里**唯一没有闸门**的 —— 前面 `java.*` 全加了，
        //    漏一个等于白做。这里至少过「恒拒绝清单」（非 http(s)/私网/回环）。
        //    （由智能体「安全终审」发现）
        guard !JsoupConn.isDeniedAlways(url) else {
            DiagLog.event("js", "gate", "getWebViewResult 被恒拒绝清单拦下：\(url.prefix(60))")
            return ""
        }
        return blockString { await WebViewRuleEngine.shared.fetchRendered(url: url) }
    }
    func log(_ msg: String) {
        captured.append(msg)
        DiagLog.event("js", "print", msg.prefix(200).description)
    }

    private func blockString(_ f: @escaping () async -> String) -> String {
        SyncBridge.wait(timeout: 45) { await f() } ?? ""
    }
    private func blockList(_ f: @escaping () async -> [String]) -> [String] {
        SyncBridge.wait(timeout: 45) { await f() } ?? []
    }
    private func blockList2(_ f: @escaping () async -> [Int]) -> [Int] {
        SyncBridge.wait(timeout: 45) { await f() } ?? []
    }
    private func blockResponse(_ f: @escaping () async -> JSResponse) -> JSResponse {
        SyncBridge.wait(timeout: 45) { await f() } ?? JSResponse(data: Data(), code: 0, url: "", headers: [:])
    }
}

/// cookie 桥（按源持久化）
@objc protocol CookieExports: JSExport {
    func getItem(_ key: String) -> String
    func setItem(_ key: String, _ value: String)
}
final class CookieJSBridge: NSObject, CookieExports {
    let baseUrl: String
    init(baseUrl: String) { self.baseUrl = baseUrl }
    func getItem(_ key: String) -> String { CookieStore.get(host: URL(string: baseUrl)?.host ?? "", name: key) ?? "" }
    func setItem(_ key: String, _ value: String) { CookieStore.set(host: URL(string: baseUrl)?.host ?? "", name: key, value: value) }
}
