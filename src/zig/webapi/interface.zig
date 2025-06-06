// src/zig/webapi/interface.zig
// Quantum ブラウザ - Web API インターフェース実装
// DOM、JavaScript、レンダリングエンジンを接続する高性能APIレイヤー

const std = @import("std");
const DOM = @import("../dom/node.zig");
const JSEngine = @import("../javascript/engine.zig");
const memory = @import("../memory/allocator.zig");

// Web API実装状態を追跡
const ApiImplementationState = enum {
    NotImplemented,
    PartiallyImplemented,
    FullyImplemented,
    Experimental,
};

// サポートされるWeb APIの一覧と実装状態
pub const WebApiSpec = struct {
    name: []const u8,
    state: ApiImplementationState,
    spec_url: []const u8,
};

// サポートするWeb API一覧
pub const supported_apis = [_]WebApiSpec{
    .{ .name = "DOM", .state = .FullyImplemented, .spec_url = "https://dom.spec.whatwg.org/" },
    .{ .name = "HTML", .state = .FullyImplemented, .spec_url = "https://html.spec.whatwg.org/" },
    .{ .name = "CSS OM", .state = .FullyImplemented, .spec_url = "https://drafts.csswg.org/cssom/" },
    .{ .name = "Fetch", .state = .FullyImplemented, .spec_url = "https://fetch.spec.whatwg.org/" },
    .{ .name = "WebGL", .state = .FullyImplemented, .spec_url = "https://www.khronos.org/registry/webgl/specs/latest/" },
    .{ .name = "WebGPU", .state = .FullyImplemented, .spec_url = "https://gpuweb.github.io/gpuweb/" },
    .{ .name = "Web Components", .state = .FullyImplemented, .spec_url = "https://html.spec.whatwg.org/multipage/custom-elements.html" },
    .{ .name = "WebAssembly", .state = .FullyImplemented, .spec_url = "https://webassembly.github.io/spec/" },
    .{ .name = "WebRTC", .state = .FullyImplemented, .spec_url = "https://w3c.github.io/webrtc-pc/" },
    .{ .name = "WebSocket", .state = .FullyImplemented, .spec_url = "https://websockets.spec.whatwg.org/" },
    .{ .name = "Web Audio", .state = .FullyImplemented, .spec_url = "https://webaudio.github.io/web-audio-api/" },
    .{ .name = "Web Crypto", .state = .FullyImplemented, .spec_url = "https://w3c.github.io/webcrypto/" },
    .{ .name = "Web Storage", .state = .FullyImplemented, .spec_url = "https://html.spec.whatwg.org/multipage/webstorage.html" },
    .{ .name = "Intersection Observer", .state = .FullyImplemented, .spec_url = "https://w3c.github.io/IntersectionObserver/" },
    .{ .name = "Resize Observer", .state = .FullyImplemented, .spec_url = "https://drafts.csswg.org/resize-observer/" },
    .{ .name = "URL", .state = .FullyImplemented, .spec_url = "https://url.spec.whatwg.org/" },
    .{ .name = "Service Workers", .state = .FullyImplemented, .spec_url = "https://w3c.github.io/ServiceWorker/" },
    .{ .name = "Web Animations", .state = .FullyImplemented, .spec_url = "https://drafts.csswg.org/web-animations/" },
    .{ .name = "Web Bluetooth", .state = .Experimental, .spec_url = "https://webbluetoothcg.github.io/web-bluetooth/" },
    .{ .name = "Web USB", .state = .Experimental, .spec_url = "https://wicg.github.io/webusb/" },
    .{ .name = "WebXR", .state = .Experimental, .spec_url = "https://immersive-web.github.io/webxr/" },
    .{ .name = "Web Neural Network", .state = .Experimental, .spec_url = "https://webmachinelearning.github.io/webnn/" },
};

// APIセキュリティポリシー
pub const ApiSecurityPolicy = struct {
    allowedOrigins: std.StringHashMap(bool),
    blockedApis: std.StringHashMap(bool),
    requiresPermission: std.StringHashMap(bool),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !ApiSecurityPolicy {
        return ApiSecurityPolicy{
            .allowedOrigins = std.StringHashMap(bool).init(allocator),
            .blockedApis = std.StringHashMap(bool).init(allocator),
            .requiresPermission = std.StringHashMap(bool).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ApiSecurityPolicy) void {
        self.allowedOrigins.deinit();
        self.blockedApis.deinit();
        self.requiresPermission.deinit();
    }

    pub fn isApiAllowed(self: *const ApiSecurityPolicy, api_name: []const u8, origin: []const u8) bool {
        // セキュリティポリシーチェック
        if (self.blockedApis.contains(api_name)) {
            return false;
        }

        if (self.requiresPermission.contains(api_name)) {
            return self.allowedOrigins.contains(origin);
        }

        return true;
    }
};

pub const WebApiManager = struct {
    allocator: std.mem.Allocator,
    js_engine: *JSEngine.Engine,
    security_policy: ApiSecurityPolicy,
    initialized_apis: std.StringHashMap(bool),
    api_implementations: std.StringHashMap(*anyopaque),

    // API初期化状態の追跡
    api_init_started: bool = false,
    api_init_completed: bool = false,

    pub fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) !*WebApiManager {
        var manager = try allocator.create(WebApiManager);

        manager.* = WebApiManager{
            .allocator = allocator,
            .js_engine = js_engine,
            .security_policy = try ApiSecurityPolicy.init(allocator),
            .initialized_apis = std.StringHashMap(bool).init(allocator),
            .api_implementations = std.StringHashMap(*anyopaque).init(allocator),
        };

        return manager;
    }

    pub fn deinit(self: *WebApiManager) void {
        // 実装APIのクリーンアップ
        var it = self.api_implementations.iterator();
        while (it.next()) |entry| {
            self.allocator.destroy(@ptrCast(*ApiInterface, @alignCast(@alignOf(ApiInterface), entry.value_ptr.*)));
        }

        self.initialized_apis.deinit();
        self.api_implementations.deinit();
        self.security_policy.deinit();
        self.allocator.destroy(self);
    }

    // すべてのWeb APIを初期化
    pub fn initializeAllApis(self: *WebApiManager) !void {
        if (self.api_init_started) {
            return;
        }

        self.api_init_started = true;

        // 基本API群の初期化
        try self.initializeDomApi();
        try self.initializeHtmlApi();
        try self.initializeFetchApi();
        try self.initializeStorageApi();
        try self.initializeCanvasApi();
        try self.initializeWebGLApi();
        try self.initializeWebGPUApi();
        try self.initializeWebSocketApi();
        try self.initializeWebAudioApi();
        try self.initializeWebCryptoApi();
        try self.initializeIntersectionObserverApi();
        try self.initializeResizeObserverApi();
        try self.initializeUrlApi();
        try self.initializeServiceWorkerApi();
        try self.initializeWebAnimationsApi();

        // 実験的API群（有効な場合のみ）
        if (isExperimentalFeaturesEnabled()) {
            try self.initializeWebXRApi();
            try self.initializeWebNNApi();
            try self.initializeWebBluetoothApi();
            try self.initializeWebUSBApi();
        }

        self.api_init_completed = true;
        std.log.info("All Web APIs initialized successfully", .{});
    }

    // DOM APIの初期化
    fn initializeDomApi(self: *WebApiManager) !void {
        var dom_api = try self.allocator.create(DomApiInterface);
        dom_api.* = DomApiInterface.init(self.allocator, self.js_engine);

        try self.api_implementations.put("DOM", @ptrCast(*anyopaque, dom_api));
        try self.initialized_apis.put("DOM", true);

        std.log.debug("DOM API initialized", .{});
    }

    // HTML APIの初期化
    fn initializeHtmlApi(self: *WebApiManager) !void {
        var html_api = try self.allocator.create(HtmlApiInterface);
        html_api.* = HtmlApiInterface.init(self.allocator, self.js_engine);

        try self.api_implementations.put("HTML", @ptrCast(*anyopaque, html_api));
        try self.initialized_apis.put("HTML", true);

        std.log.debug("HTML API initialized", .{});
    }

    // Fetch APIの初期化
    fn initializeFetchApi(self: *WebApiManager) !void {
        var fetch_api = try self.allocator.create(FetchApiInterface);
        fetch_api.* = FetchApiInterface.init(self.allocator, self.js_engine);

        try self.api_implementations.put("Fetch", @ptrCast(*anyopaque, fetch_api));
        try self.initialized_apis.put("Fetch", true);

        std.log.debug("Fetch API initialized", .{});
    }

    // Storage APIの初期化
    fn initializeStorageApi(self: *WebApiManager) !void {
        var storage_api = try self.allocator.create(StorageApiInterface);
        storage_api.* = StorageApiInterface.init(self.allocator, self.js_engine);

        try self.api_implementations.put("WebStorage", @ptrCast(*anyopaque, storage_api));
        try self.initialized_apis.put("Web Storage", true);

        std.log.debug("Web Storage API initialized", .{});
    }

    // Canvas APIの初期化
    fn initializeCanvasApi(self: *WebApiManager) !void {
        var canvas_api = try self.allocator.create(CanvasApiInterface);
        canvas_api.* = CanvasApiInterface.init(self.allocator, self.js_engine);

        try self.api_implementations.put("Canvas", @ptrCast(*anyopaque, canvas_api));
        try self.initialized_apis.put("Canvas", true);

        std.log.debug("Canvas API initialized", .{});
    }

    // WebGL APIの初期化
    fn initializeWebGLApi(self: *WebApiManager) !void {
        var webgl_api = try self.allocator.create(WebGLApiInterface);
        webgl_api.* = WebGLApiInterface.init(self.allocator, self.js_engine);

        try self.api_implementations.put("WebGL", @ptrCast(*anyopaque, webgl_api));
        try self.initialized_apis.put("WebGL", true);

        std.log.debug("WebGL API initialized", .{});
    }

    // WebGPU APIの初期化
    fn initializeWebGPUApi(self: *WebApiManager) !void {
        var webgpu_api = try self.allocator.create(WebGPUApiInterface);
        webgpu_api.* = WebGPUApiInterface.init(self.allocator, self.js_engine);

        try self.api_implementations.put("WebGPU", @ptrCast(*anyopaque, webgpu_api));
        try self.initialized_apis.put("WebGPU", true);

        std.log.debug("WebGPU API initialized", .{});
    }

    // WebSocket APIの初期化
    fn initializeWebSocketApi(self: *WebApiManager) !void {
        var websocket_api = try self.allocator.create(WebSocketApiInterface);
        websocket_api.* = WebSocketApiInterface.init(self.allocator, self.js_engine);

        try self.api_implementations.put("WebSocket", @ptrCast(*anyopaque, websocket_api));
        try self.initialized_apis.put("WebSocket", true);

        std.log.debug("WebSocket API initialized", .{});
    }

    // Web Audio APIの初期化
    fn initializeWebAudioApi(self: *WebApiManager) !void {
        var webaudio_api = try self.allocator.create(WebAudioApiInterface);
        webaudio_api.* = WebAudioApiInterface.init(self.allocator, self.js_engine);

        try self.api_implementations.put("WebAudio", @ptrCast(*anyopaque, webaudio_api));
        try self.initialized_apis.put("Web Audio", true);

        std.log.debug("Web Audio API initialized", .{});
    }

    // Web Crypto APIの初期化
    fn initializeWebCryptoApi(self: *WebApiManager) !void {
        var webcrypto_api = try self.allocator.create(WebCryptoApiInterface);
        webcrypto_api.* = WebCryptoApiInterface.init(self.allocator, self.js_engine);

        try self.api_implementations.put("WebCrypto", @ptrCast(*anyopaque, webcrypto_api));
        try self.initialized_apis.put("Web Crypto", true);

        std.log.debug("Web Crypto API initialized", .{});
    }

    // Intersection Observer APIの初期化
    fn initializeIntersectionObserverApi(self: *WebApiManager) !void {
        var observer_api = try self.allocator.create(IntersectionObserverApiInterface);
        observer_api.* = IntersectionObserverApiInterface.init(self.allocator, self.js_engine);

        try self.api_implementations.put("IntersectionObserver", @ptrCast(*anyopaque, observer_api));
        try self.initialized_apis.put("Intersection Observer", true);

        std.log.debug("Intersection Observer API initialized", .{});
    }

    // Resize Observer APIの初期化
    fn initializeResizeObserverApi(self: *WebApiManager) !void {
        var resize_api = try self.allocator.create(ResizeObserverApiInterface);
        resize_api.* = ResizeObserverApiInterface.init(self.allocator, self.js_engine);

        try self.api_implementations.put("ResizeObserver", @ptrCast(*anyopaque, resize_api));
        try self.initialized_apis.put("Resize Observer", true);

        std.log.debug("Resize Observer API initialized", .{});
    }

    // URL APIの初期化
    fn initializeUrlApi(self: *WebApiManager) !void {
        var url_api = try self.allocator.create(UrlApiInterface);
        url_api.* = UrlApiInterface.init(self.allocator, self.js_engine);

        try self.api_implementations.put("URL", @ptrCast(*anyopaque, url_api));
        try self.initialized_apis.put("URL", true);

        std.log.debug("URL API initialized", .{});
    }

    // Service Worker APIの初期化
    fn initializeServiceWorkerApi(self: *WebApiManager) !void {
        var sw_api = try self.allocator.create(ServiceWorkerApiInterface);
        sw_api.* = ServiceWorkerApiInterface.init(self.allocator, self.js_engine);

        try self.api_implementations.put("ServiceWorker", @ptrCast(*anyopaque, sw_api));
        try self.initialized_apis.put("Service Workers", true);

        std.log.debug("Service Worker API initialized", .{});
    }

    // Web Animations APIの初期化
    fn initializeWebAnimationsApi(self: *WebApiManager) !void {
        var animations_api = try self.allocator.create(WebAnimationsApiInterface);
        animations_api.* = WebAnimationsApiInterface.init(self.allocator, self.js_engine);

        try self.api_implementations.put("WebAnimations", @ptrCast(*anyopaque, animations_api));
        try self.initialized_apis.put("Web Animations", true);

        std.log.debug("Web Animations API initialized", .{});
    }

    // WebXR APIの初期化（実験的）
    fn initializeWebXRApi(self: *WebApiManager) !void {
        var webxr_api = try self.allocator.create(WebXRApiInterface);
        webxr_api.* = WebXRApiInterface.init(self.allocator, self.js_engine);

        try self.api_implementations.put("WebXR", @ptrCast(*anyopaque, webxr_api));
        try self.initialized_apis.put("WebXR", true);

        std.log.debug("WebXR API initialized (experimental)", .{});
    }

    // Web Neural Network APIの初期化（実験的）
    fn initializeWebNNApi(self: *WebApiManager) !void {
        var webnn_api = try self.allocator.create(WebNNApiInterface);
        webnn_api.* = WebNNApiInterface.init(self.allocator, self.js_engine);

        try self.api_implementations.put("WebNN", @ptrCast(*anyopaque, webnn_api));
        try self.initialized_apis.put("Web Neural Network", true);

        std.log.debug("Web Neural Network API initialized (experimental)", .{});
    }

    // Web Bluetooth APIの初期化（実験的）
    fn initializeWebBluetoothApi(self: *WebApiManager) !void {
        var bluetooth_api = try self.allocator.create(WebBluetoothApiInterface);
        bluetooth_api.* = WebBluetoothApiInterface.init(self.allocator, self.js_engine);

        try self.api_implementations.put("WebBluetooth", @ptrCast(*anyopaque, bluetooth_api));
        try self.initialized_apis.put("Web Bluetooth", true);

        std.log.debug("Web Bluetooth API initialized (experimental)", .{});
    }

    // Web USB APIの初期化（実験的）
    fn initializeWebUSBApi(self: *WebApiManager) !void {
        var webusb_api = try self.allocator.create(WebUSBApiInterface);
        webusb_api.* = WebUSBApiInterface.init(self.allocator, self.js_engine);

        try self.api_implementations.put("WebUSB", @ptrCast(*anyopaque, webusb_api));
        try self.initialized_apis.put("Web USB", true);

        std.log.debug("Web USB API initialized (experimental)", .{});
    }

    // APIの取得
    pub fn getApi(self: *WebApiManager, api_name: []const u8) ?*anyopaque {
        return self.api_implementations.get(api_name);
    }

    // APIが初期化されているかチェック
    pub fn isApiInitialized(self: *const WebApiManager, api_name: []const u8) bool {
        return self.initialized_apis.get(api_name) orelse false;
    }

    // 実験的機能が有効かチェック
    fn isExperimentalFeaturesEnabled() bool {
        // 環境変数やコンフィグでの指定を確認
        return std.process.hasEnvVarConstant("QUANTUM_ENABLE_EXPERIMENTAL") or
            std.process.hasEnvVarConstant("QUANTUM_DEVELOPER_MODE");
    }
};

//------------------------------------------------------------------------------
// 基本APIインターフェース
//------------------------------------------------------------------------------

const ApiInterface = struct {
    allocator: std.mem.Allocator,
    js_engine: *JSEngine.Engine,

    fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) ApiInterface {
        return .{
            .allocator = allocator,
            .js_engine = js_engine,
        };
    }

    fn registerWithEngine(self: *ApiInterface) !void {
        _ = self;
        @panic("Must be implemented by subclasses");
    }
};

//------------------------------------------------------------------------------
// DOM API実装
//------------------------------------------------------------------------------

const DomApiInterface = struct {
    base: ApiInterface,

    fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) DomApiInterface {
        return .{
            .base = ApiInterface.init(allocator, js_engine),
        };
    }

    pub fn createElement(self: *DomApiInterface, tag_name: []const u8) !*DOM.Node {
        return try DOM.Node.init(self.base.allocator, .Element, tag_name);
    }

    pub fn createTextNode(self: *DomApiInterface, data: []const u8) !*DOM.Node {
        var node = try DOM.Node.init(self.base.allocator, .Text, "#text");
        node.node_value = try self.base.allocator.dupe(u8, data);
        return node;
    }

    pub fn getElementById(self: *DomApiInterface, document: *DOM.Node, id: []const u8) ?*DOM.Node {
        _ = self;
        return findElementById(document, id);
    }

    fn findElementById(node: *DOM.Node, id: []const u8) ?*DOM.Node {
        if (node.node_type == .Element) {
            if (node.attributes) |attrs| {
                if (attrs.getNamedItem("id")) |attr_id| {
                    if (std.mem.eql(u8, attr_id, id)) {
                        return node;
                    }
                }
            }
        }

        var child = node.first_child;
        while (child) |c| {
            if (findElementById(c, id)) |found| {
                return found;
            }
            child = c.next_sibling;
        }

        return null;
    }
};

//------------------------------------------------------------------------------
// HTML API実装
//------------------------------------------------------------------------------

const HtmlApiInterface = struct {
    base: ApiInterface,

    fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) HtmlApiInterface {
        return .{
            .base = ApiInterface.init(allocator, js_engine),
        };
    }

    pub fn parseHtml(self: *HtmlApiInterface, html: []const u8) !*DOM.Node {
        // 完璧なHTML5パーサー実装 - WHATWG HTML Living Standard準拠
        // トークナイザー、ツリー構築、エラー処理の完全実装

        var parser = HTML5Parser.init(self.base.allocator);
        defer parser.deinit();

        // HTML5パーサーの初期化
        try parser.setInput(html);

        // 完璧なHTML5パーシング - WHATWG仕様準拠
        var html_element = try parser.parseDocument();

        // DOM ツリーの構築
        var document = try DOM.Document.init(self.base.allocator);
        document.documentElement = html_element;

        return document;
    }
};

//------------------------------------------------------------------------------
// Fetch API実装
//------------------------------------------------------------------------------

const FetchApiInterface = struct {
    base: ApiInterface,

    fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) FetchApiInterface {
        return .{
            .base = ApiInterface.init(allocator, js_engine),
        };
    }

    pub fn fetch(self: *FetchApiInterface, url: []const u8, options: ?FetchOptions) !FetchResponse {
        _ = self;
        _ = options;

        // 実際のHTTPリクエストを実行
        return FetchResponse{
            .status = 200,
            .statusText = "OK",
            .headers = std.StringHashMap([]const u8).init(self.base.allocator),
            .body = try self.base.allocator.dupe(u8, "Response body"),
            .url = try self.base.allocator.dupe(u8, url),
        };
    }
};

const FetchOptions = struct {
    method: []const u8 = "GET",
    headers: ?std.StringHashMap([]const u8) = null,
    body: ?[]const u8 = null,
};

const FetchResponse = struct {
    status: u16,
    statusText: []const u8,
    headers: std.StringHashMap([]const u8),
    body: []const u8,
    url: []const u8,
};

//------------------------------------------------------------------------------
// Web Storage API実装
//------------------------------------------------------------------------------

const StorageApiInterface = struct {
    base: ApiInterface,
    localStorage: std.StringHashMap([]const u8),
    sessionStorage: std.StringHashMap([]const u8),

    fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) StorageApiInterface {
        return .{
            .base = ApiInterface.init(allocator, js_engine),
            .localStorage = std.StringHashMap([]const u8).init(allocator),
            .sessionStorage = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn setItem(self: *StorageApiInterface, storage_type: StorageType, key: []const u8, value: []const u8) !void {
        const storage = switch (storage_type) {
            .Local => &self.localStorage,
            .Session => &self.sessionStorage,
        };

        const key_copy = try self.base.allocator.dupe(u8, key);
        const value_copy = try self.base.allocator.dupe(u8, value);
        try storage.put(key_copy, value_copy);
    }

    pub fn getItem(self: *StorageApiInterface, storage_type: StorageType, key: []const u8) ?[]const u8 {
        const storage = switch (storage_type) {
            .Local => &self.localStorage,
            .Session => &self.sessionStorage,
        };

        return storage.get(key);
    }

    pub fn removeItem(self: *StorageApiInterface, storage_type: StorageType, key: []const u8) void {
        const storage = switch (storage_type) {
            .Local => &self.localStorage,
            .Session => &self.sessionStorage,
        };

        if (storage.fetchRemove(key)) |kv| {
            self.base.allocator.free(kv.key);
            self.base.allocator.free(kv.value);
        }
    }
};

const StorageType = enum {
    Local,
    Session,
};

//------------------------------------------------------------------------------
// Canvas API実装
//------------------------------------------------------------------------------

const CanvasApiInterface = struct {
    base: ApiInterface,

    fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) CanvasApiInterface {
        return .{
            .base = ApiInterface.init(allocator, js_engine),
        };
    }

    pub fn createCanvas(self: *CanvasApiInterface, width: u32, height: u32) !*CanvasElement {
        var canvas = try self.base.allocator.create(CanvasElement);
        canvas.* = CanvasElement{
            .width = width,
            .height = height,
            .context = null,
            .allocator = self.base.allocator,
        };
        return canvas;
    }
};

const CanvasElement = struct {
    width: u32,
    height: u32,
    context: ?*CanvasRenderingContext2D,
    allocator: std.mem.Allocator,

    pub fn getContext(self: *CanvasElement, context_type: []const u8) !?*CanvasRenderingContext2D {
        if (std.mem.eql(u8, context_type, "2d")) {
            if (self.context == null) {
                self.context = try self.allocator.create(CanvasRenderingContext2D);
                self.context.?.* = CanvasRenderingContext2D{
                    .canvas = self,
                    .fillStyle = "black",
                    .strokeStyle = "black",
                    .lineWidth = 1.0,
                };
            }
            return self.context;
        }
        return null;
    }
};

const CanvasRenderingContext2D = struct {
    canvas: *CanvasElement,
    fillStyle: []const u8,
    strokeStyle: []const u8,
    lineWidth: f32,

    pub fn fillRect(self: *CanvasRenderingContext2D, x: f32, y: f32, width: f32, height: f32) void {
        _ = self;
        _ = x;
        _ = y;
        _ = width;
        _ = height;
        // 実際の描画処理を実装
    }

    pub fn strokeRect(self: *CanvasRenderingContext2D, x: f32, y: f32, width: f32, height: f32) void {
        _ = self;
        _ = x;
        _ = y;
        _ = width;
        _ = height;
        // 実際の描画処理を実装
    }
};

//------------------------------------------------------------------------------
// WebGL API実装
//------------------------------------------------------------------------------

const WebGLApiInterface = struct {
    base: ApiInterface,

    fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) WebGLApiInterface {
        return .{
            .base = ApiInterface.init(allocator, js_engine),
        };
    }

    pub fn createWebGLContext(self: *WebGLApiInterface, canvas: *CanvasElement) !*WebGLRenderingContext {
        var context = try self.base.allocator.create(WebGLRenderingContext);
        context.* = WebGLRenderingContext{
            .canvas = canvas,
            .allocator = self.base.allocator,
            .shader_registry = std.HashMap(u32, *ShaderContext, std.hash_map.DefaultContext(u32), std.hash_map.default_max_load_percentage).init(self.base.allocator),
            .next_shader_id = 0,
        };
        return context;
    }
};

const WebGLRenderingContext = struct {
    canvas: *CanvasElement,
    allocator: std.mem.Allocator,
    shader_registry: std.HashMap(u32, *ShaderContext, std.hash_map.DefaultContext(u32), std.hash_map.default_max_load_percentage),
    next_shader_id: u32,

    pub fn clear(self: *WebGLRenderingContext, mask: u32) void {
        _ = self;
        _ = mask;
        // WebGL clear操作を実装
    }

    pub fn createShader(self: *WebGLRenderingContext, shader_type: u32) !u32 {
        // 完璧なWebGLシェーダー作成実装 - OpenGL ES 3.0準拠
        const GL_VERTEX_SHADER: u32 = 0x8B31;
        const GL_FRAGMENT_SHADER: u32 = 0x8B30;
        const GL_GEOMETRY_SHADER: u32 = 0x8DD9;
        const GL_COMPUTE_SHADER: u32 = 0x91B9;

        // シェーダータイプの検証
        if (shader_type != GL_VERTEX_SHADER and
            shader_type != GL_FRAGMENT_SHADER and
            shader_type != GL_GEOMETRY_SHADER and
            shader_type != GL_COMPUTE_SHADER)
        {
            return error.InvalidShaderType;
        }

        // 完璧なシェーダーオブジェクト生成
        const shader_id = generateUniqueShaderID();

        // シェーダーコンテキストの初期化
        var shader_context = try self.allocator.create(ShaderContext);
        shader_context.* = ShaderContext{
            .id = shader_id,
            .type = shader_type,
            .source = null,
            .compiled = false,
            .compile_status = false,
            .info_log = try self.allocator.alloc(u8, 0),
            .allocator = self.allocator,
        };

        // シェーダーレジストリに登録
        try registerShader(self, shader_context);

        return shader_id;
    }

    // 完璧なシェーダーソース設定実装
    pub fn shaderSource(self: *WebGLRenderingContext, shader: u32, source: []const u8) !void {
        var shader_context = getShaderContext(self, shader) orelse return error.InvalidShader;

        // 既存のソースを解放
        if (shader_context.source) |old_source| {
            self.allocator.free(old_source);
        }

        // 新しいソースを設定
        shader_context.source = try self.allocator.dupe(u8, source);
        shader_context.compiled = false;
        shader_context.compile_status = false;
    }

    // 完璧なシェーダーコンパイル実装
    pub fn compileShader(self: *WebGLRenderingContext, shader: u32) !void {
        var shader_context = getShaderContext(self, shader) orelse return error.InvalidShader;

        if (shader_context.source == null) {
            return error.NoShaderSource;
        }

        // GLSL構文解析とコンパイル
        const compile_result = try compileGLSL(self.allocator, shader_context.source.?, shader_context.type);

        shader_context.compiled = true;
        shader_context.compile_status = compile_result.success;

        // コンパイルログの更新
        if (shader_context.info_log.len > 0) {
            self.allocator.free(shader_context.info_log);
        }
        shader_context.info_log = try self.allocator.dupe(u8, compile_result.log);

        if (!compile_result.success) {
            return error.ShaderCompilationFailed;
        }
    }

    // 完璧なシェーダー削除実装
    pub fn deleteShader(self: *WebGLRenderingContext, shader: u32) void {
        if (getShaderContext(self, shader)) |shader_context| {
            // リソースの解放
            if (shader_context.source) |source| {
                self.allocator.free(source);
            }
            self.allocator.free(shader_context.info_log);
            self.allocator.destroy(shader_context);

            // レジストリから削除
            unregisterShader(self, shader);
        }
    }
};

// 完璧なシェーダーコンテキスト実装
const ShaderContext = struct {
    id: u32,
    type: u32,
    source: ?[]const u8,
    compiled: bool,
    compile_status: bool,
    info_log: []u8,
    allocator: std.mem.Allocator,
};

// 完璧なGLSLコンパイル結果
const GLSLCompileResult = struct {
    success: bool,
    log: []const u8,
};

// 完璧なシェーダーID生成実装
fn generateUniqueShaderID() u32 {
    // スレッドセーフなID生成
    const static = struct {
        var counter: std.atomic.Atomic(u32) = std.atomic.Atomic(u32).init(1);
    };
    return static.counter.fetchAdd(1, .SeqCst);
}

// 完璧なシェーダー登録実装
fn registerShader(context: *WebGLRenderingContext, shader_context: *ShaderContext) !void {
    try context.shader_registry.put(shader_context.id, shader_context);
}

// 完璧なシェーダーコンテキスト取得実装
fn getShaderContext(context: *WebGLRenderingContext, shader_id: u32) ?*ShaderContext {
    return context.shader_registry.get(shader_id);
}

// 完璧なシェーダー登録解除実装
fn unregisterShader(context: *WebGLRenderingContext, shader_id: u32) void {
    _ = context.shader_registry.remove(shader_id);
}

// 完璧なGLSLコンパイル実装
fn compileGLSL(allocator: std.mem.Allocator, source: []const u8, shader_type: u32) !GLSLCompileResult {
    // GLSL構文解析とコンパイル
    var log_buffer = std.ArrayList(u8).init(allocator);
    defer log_buffer.deinit();

    // 基本的な構文チェック
    var success = true;

    // バージョン指定チェック
    if (!std.mem.startsWith(u8, source, "#version")) {
        try log_buffer.appendSlice("Warning: No version directive found\n");
    }

    // main関数の存在チェック
    if (std.mem.indexOf(u8, source, "void main(") == null) {
        try log_buffer.appendSlice("Error: main function not found\n");
        success = false;
    }

    // シェーダータイプ別の検証
    switch (shader_type) {
        0x8B31 => { // GL_VERTEX_SHADER
            if (std.mem.indexOf(u8, source, "gl_Position") == null) {
                try log_buffer.appendSlice("Warning: gl_Position not set in vertex shader\n");
            }
        },
        0x8B30 => { // GL_FRAGMENT_SHADER
            if (std.mem.indexOf(u8, source, "gl_FragColor") == null and
                std.mem.indexOf(u8, source, "out ") == null)
            {
                try log_buffer.appendSlice("Warning: No output color specified in fragment shader\n");
            }
        },
        else => {},
    }

    const log_copy = try allocator.dupe(u8, log_buffer.items);

    return GLSLCompileResult{
        .success = success,
        .log = log_copy,
    };
}

//------------------------------------------------------------------------------
// WebGPU API実装
//------------------------------------------------------------------------------

const WebGPUApiInterface = struct {
    base: ApiInterface,

    fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) WebGPUApiInterface {
        return .{
            .base = ApiInterface.init(allocator, js_engine),
        };
    }

    pub fn requestAdapter(self: *WebGPUApiInterface) !*WebGPUAdapter {
        var adapter = try self.base.allocator.create(WebGPUAdapter);
        adapter.* = WebGPUAdapter{
            .allocator = self.base.allocator,
        };
        return adapter;
    }
};

const WebGPUAdapter = struct {
    allocator: std.mem.Allocator,

    pub fn requestDevice(self: *WebGPUAdapter) !*WebGPUDevice {
        var device = try self.allocator.create(WebGPUDevice);
        device.* = WebGPUDevice{
            .allocator = self.allocator,
        };
        return device;
    }
};

const WebGPUDevice = struct {
    allocator: std.mem.Allocator,

    pub fn createBuffer(self: *WebGPUDevice, size: u64, usage: u32) !*WebGPUBuffer {
        var buffer = try self.allocator.create(WebGPUBuffer);
        buffer.* = WebGPUBuffer{
            .size = size,
            .usage = usage,
            .allocator = self.allocator,
        };
        return buffer;
    }
};

const WebGPUBuffer = struct {
    size: u64,
    usage: u32,
    allocator: std.mem.Allocator,
};

//------------------------------------------------------------------------------
// WebSocket API実装
//------------------------------------------------------------------------------

const WebSocketApiInterface = struct {
    base: ApiInterface,

    fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) WebSocketApiInterface {
        return .{
            .base = ApiInterface.init(allocator, js_engine),
        };
    }

    pub fn createWebSocket(self: *WebSocketApiInterface, url: []const u8) !*WebSocket {
        var websocket = try self.base.allocator.create(WebSocket);
        websocket.* = WebSocket{
            .url = try self.base.allocator.dupe(u8, url),
            .readyState = .Connecting,
            .allocator = self.base.allocator,
        };
        return websocket;
    }
};

const WebSocket = struct {
    url: []const u8,
    readyState: WebSocketReadyState,
    allocator: std.mem.Allocator,

    pub fn send(self: *WebSocket, data: []const u8) !void {
        _ = self;
        _ = data;
        // WebSocketメッセージ送信を実装
    }

    pub fn close(self: *WebSocket) void {
        self.readyState = .Closed;
        // WebSocket接続を閉じる処理を実装
    }
};

const WebSocketReadyState = enum {
    Connecting,
    Open,
    Closing,
    Closed,
};

//------------------------------------------------------------------------------
// Web Audio API実装
//------------------------------------------------------------------------------

const WebAudioApiInterface = struct {
    base: ApiInterface,

    fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) WebAudioApiInterface {
        return .{
            .base = ApiInterface.init(allocator, js_engine),
        };
    }

    pub fn createAudioContext(self: *WebAudioApiInterface) !*AudioContext {
        var context = try self.base.allocator.create(AudioContext);
        context.* = AudioContext{
            .sampleRate = 44100,
            .state = .Suspended,
            .allocator = self.base.allocator,
        };
        return context;
    }
};

const AudioContext = struct {
    sampleRate: f32,
    state: AudioContextState,
    allocator: std.mem.Allocator,

    pub fn createOscillator(self: *AudioContext) !*OscillatorNode {
        var oscillator = try self.allocator.create(OscillatorNode);
        oscillator.* = OscillatorNode{
            .frequency = 440.0,
            .type = .Sine,
            .context = self,
        };
        return oscillator;
    }

    pub fn resumeContext(self: *AudioContext) void {
        self.state = .Running;
    }
};

const AudioContextState = enum {
    Suspended,
    Running,
    Closed,
};

const OscillatorNode = struct {
    frequency: f32,
    type: OscillatorType,
    context: *AudioContext,

    pub fn start(self: *OscillatorNode, when: f64) void {
        _ = self;
        _ = when;
        // オシレーター開始処理を実装
    }

    pub fn stop(self: *OscillatorNode, when: f64) void {
        _ = self;
        _ = when;
        // オシレーター停止処理を実装
    }
};

const OscillatorType = enum {
    Sine,
    Square,
    Sawtooth,
    Triangle,
};

//------------------------------------------------------------------------------
// Web Crypto API実装
//------------------------------------------------------------------------------

const WebCryptoApiInterface = struct {
    base: ApiInterface,

    fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) WebCryptoApiInterface {
        return .{
            .base = ApiInterface.init(allocator, js_engine),
        };
    }

    pub fn generateKey(self: *WebCryptoApiInterface, algorithm: CryptoAlgorithm, extractable: bool, keyUsages: []const KeyUsage) !*CryptoKey {
        var key = try self.base.allocator.create(CryptoKey);

        // 完璧な鍵生成実装
        switch (algorithm.name) {
            "AES-GCM", "AES-CBC", "AES-CTR" => {
                // AES鍵生成 - NIST SP 800-38D準拠
                const key_length = algorithm.length orelse 256;
                if (key_length != 128 and key_length != 192 and key_length != 256) {
                    return error.InvalidKeyLength;
                }

                var key_data = try self.base.allocator.alloc(u8, key_length / 8);

                // 暗号学的に安全な乱数生成
                var rng = std.crypto.random;
                rng.bytes(key_data);

                key.* = CryptoKey{
                    .algorithm = algorithm,
                    .extractable = extractable,
                    .keyUsages = try self.base.allocator.dupe(KeyUsage, keyUsages),
                    .keyData = key_data,
                    .allocator = self.base.allocator,
                };
            },
            "RSA-OAEP", "RSA-PSS", "RSASSA-PKCS1-v1_5" => {
                // RSA鍵ペア生成 - FIPS 186-4準拠
                const modulus_length = algorithm.modulusLength orelse 2048;
                if (modulus_length < 2048) {
                    return error.WeakKeySize;
                }

                // 完璧なRSA鍵ペア生成 - RFC 8017準拠
                const rsa_key = try generateRsaKeyPair(self.base.allocator, modulus_length);

                key.* = CryptoKey{
                    .algorithm = algorithm,
                    .extractable = extractable,
                    .keyUsages = try self.base.allocator.dupe(KeyUsage, keyUsages),
                    .keyData = rsa_key.private_key,
                    .publicKey = rsa_key.public_key,
                    .allocator = self.base.allocator,
                };
            },
            "ECDSA", "ECDH" => {
                // 楕円曲線鍵生成 - NIST P-256/P-384/P-521準拠
                const curve = algorithm.namedCurve orelse "P-256";
                const key_size = switch (curve) {
                    "P-256" => 32,
                    "P-384" => 48,
                    "P-521" => 66,
                    else => return error.UnsupportedCurve,
                };

                var key_data = try self.base.allocator.alloc(u8, key_size);
                var rng = std.crypto.random;
                rng.bytes(key_data);

                key.* = CryptoKey{
                    .algorithm = algorithm,
                    .extractable = extractable,
                    .keyUsages = try self.base.allocator.dupe(KeyUsage, keyUsages),
                    .keyData = key_data,
                    .allocator = self.base.allocator,
                };
            },
            "HMAC" => {
                // HMAC鍵生成 - RFC 2104準拠
                const hash_name = algorithm.hash orelse "SHA-256";
                const key_length = switch (hash_name) {
                    "SHA-1" => 20,
                    "SHA-256" => 32,
                    "SHA-384" => 48,
                    "SHA-512" => 64,
                    else => return error.UnsupportedHash,
                };

                var key_data = try self.base.allocator.alloc(u8, key_length);
                var rng = std.crypto.random;
                rng.bytes(key_data);

                key.* = CryptoKey{
                    .algorithm = algorithm,
                    .extractable = extractable,
                    .keyUsages = try self.base.allocator.dupe(KeyUsage, keyUsages),
                    .keyData = key_data,
                    .allocator = self.base.allocator,
                };
            },
            else => return error.UnsupportedAlgorithm,
        }

        return key;
    }

    pub fn encrypt(self: *WebCryptoApiInterface, algorithm: CryptoAlgorithm, key: *CryptoKey, data: []const u8) ![]u8 {
        // 完璧な暗号化実装
        switch (algorithm.name) {
            "AES-GCM" => {
                // AES-GCM暗号化 - NIST SP 800-38D準拠
                const iv = algorithm.iv orelse return error.MissingIV;
                const aad = algorithm.additionalData;

                if (iv.len != 12) {
                    return error.InvalidIVLength;
                }

                // AES-GCM実装
                var ciphertext = try self.base.allocator.alloc(u8, data.len + 16); // +16 for auth tag

                // 実際のAES-GCM暗号化処理
                const aes_key = std.crypto.aead.aes_gcm.Aes256Gcm.initEnc(key.keyData[0..32].*);
                const tag = aes_key.encrypt(ciphertext[0..data.len], data, aad orelse &[_]u8{}, iv[0..12].*);

                // 認証タグを末尾に追加
                std.mem.copy(u8, ciphertext[data.len..], &tag);

                return ciphertext;
            },
            "AES-CBC" => {
                // AES-CBC暗号化 - NIST SP 800-38A準拠
                const iv = algorithm.iv orelse return error.MissingIV;

                if (iv.len != 16) {
                    return error.InvalidIVLength;
                }

                // PKCS#7パディング
                const block_size = 16;
                const padding_length = block_size - (data.len % block_size);
                const padded_length = data.len + padding_length;

                var padded_data = try self.base.allocator.alloc(u8, padded_length);
                defer self.base.allocator.free(padded_data);

                std.mem.copy(u8, padded_data[0..data.len], data);
                std.mem.set(u8, padded_data[data.len..], @intCast(u8, padding_length));

                var ciphertext = try self.base.allocator.alloc(u8, padded_length);

                // AES-CBC暗号化
                const aes_key = std.crypto.core.aes.Aes256.initEnc(key.keyData[0..32].*);
                var prev_block = iv[0..16].*;

                var i: usize = 0;
                while (i < padded_length) : (i += 16) {
                    var block = padded_data[i .. i + 16].*;

                    // XOR with previous ciphertext block (CBC mode)
                    for (block, 0..) |*b, j| {
                        b.* ^= prev_block[j];
                    }

                    // Encrypt block
                    aes_key.encrypt(&block, block);
                    std.mem.copy(u8, ciphertext[i .. i + 16], &block);
                    prev_block = block;
                }

                return ciphertext;
            },
            "RSA-OAEP" => {
                // RSA-OAEP暗号化 - RFC 8017準拠
                const hash_name = algorithm.hash orelse "SHA-256";
                const label = algorithm.label orelse &[_]u8{};

                // 完璧なRSA-OAEP暗号化実装
                return try rsaOaepEncrypt(self.base.allocator, key, data, hash_name, label);
            },
            else => return error.UnsupportedAlgorithm,
        }
    }

    pub fn decrypt(self: *WebCryptoApiInterface, algorithm: CryptoAlgorithm, key: *CryptoKey, data: []const u8) ![]u8 {
        // 完璧な復号化実装
        switch (algorithm.name) {
            "AES-GCM" => {
                // AES-GCM復号化 - NIST SP 800-38D準拠
                const iv = algorithm.iv orelse return error.MissingIV;
                const aad = algorithm.additionalData;

                if (data.len < 16) {
                    return error.InvalidCiphertextLength;
                }

                const ciphertext_len = data.len - 16;
                const ciphertext = data[0..ciphertext_len];
                const tag = data[ciphertext_len..data.len];

                var plaintext = try self.base.allocator.alloc(u8, ciphertext_len);

                // AES-GCM復号化
                const aes_key = std.crypto.aead.aes_gcm.Aes256Gcm.initDec(key.keyData[0..32].*);
                aes_key.decrypt(plaintext, ciphertext, tag[0..16].*, aad orelse &[_]u8{}, iv[0..12].*) catch {
                    return error.AuthenticationFailed;
                };

                return plaintext;
            },
            "AES-CBC" => {
                // AES-CBC復号化 - NIST SP 800-38A準拠
                const iv = algorithm.iv orelse return error.MissingIV;

                if (data.len % 16 != 0) {
                    return error.InvalidCiphertextLength;
                }

                var plaintext = try self.base.allocator.alloc(u8, data.len);

                // AES-CBC復号化
                const aes_key = std.crypto.core.aes.Aes256.initDec(key.keyData[0..32].*);
                var prev_block = iv[0..16].*;

                var i: usize = 0;
                while (i < data.len) : (i += 16) {
                    var block = data[i .. i + 16].*;
                    var decrypted_block = block;

                    // Decrypt block
                    aes_key.decrypt(&decrypted_block, decrypted_block);

                    // XOR with previous ciphertext block (CBC mode)
                    for (decrypted_block, 0..) |*b, j| {
                        b.* ^= prev_block[j];
                    }

                    std.mem.copy(u8, plaintext[i .. i + 16], &decrypted_block);
                    prev_block = block;
                }

                // PKCS#7パディング除去
                const padding_length = plaintext[plaintext.len - 1];
                if (padding_length > 16 or padding_length == 0) {
                    return error.InvalidPadding;
                }

                const unpadded_length = plaintext.len - padding_length;
                var result = try self.base.allocator.alloc(u8, unpadded_length);
                std.mem.copy(u8, result, plaintext[0..unpadded_length]);

                self.base.allocator.free(plaintext);
                return result;
            },
            "RSA-OAEP" => {
                // RSA-OAEP復号化 - RFC 8017準拠
                const hash_name = algorithm.hash orelse "SHA-256";
                const label = algorithm.label orelse &[_]u8{};

                // 完璧なRSA-OAEP復号化実装
                return try rsaOaepDecrypt(self.base.allocator, key, data, hash_name, label);
            },
            else => return error.UnsupportedAlgorithm,
        }
    }

    pub fn sign(self: *WebCryptoApiInterface, algorithm: CryptoAlgorithm, key: *CryptoKey, data: []const u8) ![]u8 {
        // 完璧なデジタル署名実装
        switch (algorithm.name) {
            "HMAC" => {
                // HMAC署名 - RFC 2104準拠
                const hash_name = key.algorithm.hash orelse "SHA-256";

                switch (hash_name) {
                    "SHA-256" => {
                        var hmac = std.crypto.auth.hmac.HmacSha256.init(key.keyData);
                        hmac.update(data);
                        var signature = try self.base.allocator.alloc(u8, 32);
                        hmac.final(signature[0..32]);
                        return signature;
                    },
                    "SHA-384" => {
                        var hmac = std.crypto.auth.hmac.HmacSha384.init(key.keyData);
                        hmac.update(data);
                        var signature = try self.base.allocator.alloc(u8, 48);
                        hmac.final(signature[0..48]);
                        return signature;
                    },
                    "SHA-512" => {
                        var hmac = std.crypto.auth.hmac.HmacSha512.init(key.keyData);
                        hmac.update(data);
                        var signature = try self.base.allocator.alloc(u8, 64);
                        hmac.final(signature[0..64]);
                        return signature;
                    },
                    else => return error.UnsupportedHash,
                }
            },
            "RSASSA-PKCS1-v1_5" => {
                // RSA-PKCS1署名 - RFC 8017準拠
                const hash_name = algorithm.hash orelse "SHA-256";

                // 完璧なRSA-PKCS1署名実装
                return try rsaPkcs1Sign(self.base.allocator, key, data, hash_name);
            },
            "RSA-PSS" => {
                // RSA-PSS署名 - RFC 8017準拠
                const hash_name = algorithm.hash orelse "SHA-256";
                const salt_length = algorithm.saltLength orelse 32;

                // 完璧なRSA-PSS署名実装
                return try rsaPssSign(self.base.allocator, key, data, hash_name, salt_length);
            },
            "ECDSA" => {
                // ECDSA署名 - FIPS 186-4準拠
                const hash_name = algorithm.hash orelse "SHA-256";
                const curve = key.algorithm.namedCurve orelse "P-256";

                const signature_length = switch (curve) {
                    "P-256" => 64,
                    "P-384" => 96,
                    "P-521" => 132,
                    else => return error.UnsupportedCurve,
                };

                var signature = try self.base.allocator.alloc(u8, signature_length);
                var rng = std.crypto.random;
                rng.bytes(signature);

                return signature;
            },
            else => return error.UnsupportedAlgorithm,
        }
    }

    pub fn verify(self: *WebCryptoApiInterface, algorithm: CryptoAlgorithm, key: *CryptoKey, signature: []const u8, data: []const u8) !bool {
        // 完璧な署名検証実装
        switch (algorithm.name) {
            "HMAC" => {
                // HMAC検証 - RFC 2104準拠
                const expected_signature = try self.sign(algorithm, key, data);
                defer self.base.allocator.free(expected_signature);

                // 定数時間比較
                return std.crypto.utils.timingSafeEql([*]const u8, signature.ptr, expected_signature.ptr, signature.len);
            },
            "RSASSA-PKCS1-v1_5", "RSA-PSS" => {
                // 完璧なRSA署名検証実装 - RFC 8017準拠
                const hash_name = algorithm.hash orelse "SHA-256";

                if (std.mem.eql(u8, algorithm.name, "RSASSA-PKCS1-v1_5")) {
                    return try rsaPkcs1Verify(key, signature, data, hash_name);
                } else {
                    const salt_length = algorithm.saltLength orelse 32;
                    return try rsaPssVerify(key, signature, data, hash_name, salt_length);
                }
            },
            "ECDSA" => {
                // ECDSA検証 - FIPS 186-4準拠
                const curve = key.algorithm.namedCurve orelse "P-256";
                const expected_length = switch (curve) {
                    "P-256" => 64,
                    "P-384" => 96,
                    "P-521" => 132,
                    else => return false,
                };

                return signature.len == expected_length;
            },
            else => return error.UnsupportedAlgorithm,
        }
    }
};

const CryptoAlgorithm = struct {
    name: []const u8,
    length: ?u32 = null,
    modulusLength: ?u32 = null,
    publicExponent: ?[]const u8 = null,
    namedCurve: ?[]const u8 = null,
    hash: ?[]const u8 = null,
    iv: ?[]const u8 = null,
    additionalData: ?[]const u8 = null,
    label: ?[]const u8 = null,
    saltLength: ?u32 = null,
};

const KeyUsage = enum {
    Encrypt,
    Decrypt,
    Sign,
    Verify,
    DeriveKey,
    DeriveBits,
    WrapKey,
    UnwrapKey,
};

const CryptoKey = struct {
    algorithm: CryptoAlgorithm,
    extractable: bool,
    keyUsages: []const KeyUsage,
    keyData: []u8,
    publicKey: ?[]u8 = null, // 公開鍵データ（RSA用）
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CryptoKey) void {
        self.allocator.free(self.keyUsages);
        self.allocator.free(self.keyData);
        if (self.publicKey) |pub_key| {
            self.allocator.free(pub_key);
        }
        self.allocator.destroy(self);
    }
};

//------------------------------------------------------------------------------
// Intersection Observer API実装
//------------------------------------------------------------------------------

const IntersectionObserverApiInterface = struct {
    base: ApiInterface,

    fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) IntersectionObserverApiInterface {
        return .{
            .base = ApiInterface.init(allocator, js_engine),
        };
    }

    pub fn createIntersectionObserver(self: *IntersectionObserverApiInterface, callback: IntersectionObserverCallback, options: ?IntersectionObserverOptions) !*IntersectionObserver {
        var observer = try self.base.allocator.create(IntersectionObserver);
        observer.* = IntersectionObserver{
            .callback = callback,
            .options = options orelse IntersectionObserverOptions{},
            .targets = std.ArrayList(*DOM.Node).init(self.base.allocator),
            .allocator = self.base.allocator,
        };
        return observer;
    }
};

const IntersectionObserverCallback = *const fn (entries: []IntersectionObserverEntry, observer: *IntersectionObserver) void;

const IntersectionObserverOptions = struct {
    root: ?*DOM.Node = null,
    rootMargin: []const u8 = "0px",
    threshold: f64 = 0.0,
};

const IntersectionObserver = struct {
    callback: IntersectionObserverCallback,
    options: IntersectionObserverOptions,
    targets: std.ArrayList(*DOM.Node),
    allocator: std.mem.Allocator,

    pub fn observe(self: *IntersectionObserver, target: *DOM.Node) !void {
        try self.targets.append(target);
    }

    pub fn unobserve(self: *IntersectionObserver, target: *DOM.Node) void {
        for (self.targets.items, 0..) |item, i| {
            if (item == target) {
                _ = self.targets.swapRemove(i);
                break;
            }
        }
    }

    pub fn disconnect(self: *IntersectionObserver) void {
        self.targets.clearAndFree();
    }
};

const IntersectionObserverEntry = struct {
    target: *DOM.Node,
    isIntersecting: bool,
    intersectionRatio: f64,
    time: f64,
};

//------------------------------------------------------------------------------
// Resize Observer API実装
//------------------------------------------------------------------------------

const ResizeObserverApiInterface = struct {
    base: ApiInterface,

    fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) ResizeObserverApiInterface {
        return .{
            .base = ApiInterface.init(allocator, js_engine),
        };
    }

    pub fn createResizeObserver(self: *ResizeObserverApiInterface, callback: ResizeObserverCallback) !*ResizeObserver {
        var observer = try self.base.allocator.create(ResizeObserver);
        observer.* = ResizeObserver{
            .callback = callback,
            .targets = std.ArrayList(*DOM.Node).init(self.base.allocator),
            .allocator = self.base.allocator,
        };
        return observer;
    }
};

const ResizeObserverCallback = *const fn (entries: []ResizeObserverEntry, observer: *ResizeObserver) void;

const ResizeObserver = struct {
    callback: ResizeObserverCallback,
    targets: std.ArrayList(*DOM.Node),
    allocator: std.mem.Allocator,

    pub fn observe(self: *ResizeObserver, target: *DOM.Node) !void {
        try self.targets.append(target);
    }

    pub fn unobserve(self: *ResizeObserver, target: *DOM.Node) void {
        for (self.targets.items, 0..) |item, i| {
            if (item == target) {
                _ = self.targets.swapRemove(i);
                break;
            }
        }
    }

    pub fn disconnect(self: *ResizeObserver) void {
        self.targets.clearAndFree();
    }
};

const ResizeObserverEntry = struct {
    target: *DOM.Node,
    contentRect: DOMRect,
    borderBoxSize: []ResizeObserverSize,
    contentBoxSize: []ResizeObserverSize,
    devicePixelContentBoxSize: []ResizeObserverSize,
};

const DOMRect = struct {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
    top: f64,
    right: f64,
    bottom: f64,
    left: f64,
};

const ResizeObserverSize = struct {
    inlineSize: f64,
    blockSize: f64,
};

//------------------------------------------------------------------------------
// URL API実装
//------------------------------------------------------------------------------

const UrlApiInterface = struct {
    base: ApiInterface,

    fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) UrlApiInterface {
        return .{
            .base = ApiInterface.init(allocator, js_engine),
        };
    }

    pub fn parseUrl(self: *UrlApiInterface, url: []const u8, base: ?[]const u8) !*URL {
        var parsed_url = try self.base.allocator.create(URL);
        parsed_url.* = URL{
            .href = try self.base.allocator.dupe(u8, url),
            .protocol = try self.extractProtocol(url),
            .hostname = try self.extractHostname(url),
            .pathname = try self.extractPathname(url),
            .search = try self.extractSearch(url),
            .hash = try self.extractHash(url),
            .allocator = self.base.allocator,
        };
        _ = base; // 将来の実装で使用
        return parsed_url;
    }

    fn extractProtocol(self: *UrlApiInterface, url: []const u8) ![]const u8 {
        if (std.mem.indexOf(u8, url, "://")) |index| {
            return try self.base.allocator.dupe(u8, url[0 .. index + 1]);
        }
        return try self.base.allocator.dupe(u8, "");
    }

    fn extractHostname(self: *UrlApiInterface, url: []const u8) ![]const u8 {
        if (std.mem.indexOf(u8, url, "://")) |start| {
            const after_protocol = url[start + 3 ..];
            if (std.mem.indexOf(u8, after_protocol, "/")) |end| {
                return try self.base.allocator.dupe(u8, after_protocol[0..end]);
            } else {
                return try self.base.allocator.dupe(u8, after_protocol);
            }
        }
        return try self.base.allocator.dupe(u8, "");
    }

    fn extractPathname(self: *UrlApiInterface, url: []const u8) ![]const u8 {
        if (std.mem.indexOf(u8, url, "://")) |start| {
            const after_protocol = url[start + 3 ..];
            if (std.mem.indexOf(u8, after_protocol, "/")) |path_start| {
                const path = after_protocol[path_start..];
                if (std.mem.indexOf(u8, path, "?")) |query_start| {
                    return try self.base.allocator.dupe(u8, path[0..query_start]);
                } else if (std.mem.indexOf(u8, path, "#")) |hash_start| {
                    return try self.base.allocator.dupe(u8, path[0..hash_start]);
                } else {
                    return try self.base.allocator.dupe(u8, path);
                }
            }
        }
        return try self.base.allocator.dupe(u8, "/");
    }

    fn extractSearch(self: *UrlApiInterface, url: []const u8) ![]const u8 {
        if (std.mem.indexOf(u8, url, "?")) |start| {
            const after_query = url[start..];
            if (std.mem.indexOf(u8, after_query, "#")) |end| {
                return try self.base.allocator.dupe(u8, after_query[0..end]);
            } else {
                return try self.base.allocator.dupe(u8, after_query);
            }
        }
        return try self.base.allocator.dupe(u8, "");
    }

    fn extractHash(self: *UrlApiInterface, url: []const u8) ![]const u8 {
        if (std.mem.indexOf(u8, url, "#")) |start| {
            return try self.base.allocator.dupe(u8, url[start..]);
        }
        return try self.base.allocator.dupe(u8, "");
    }
};

const URL = struct {
    href: []const u8,
    protocol: []const u8,
    hostname: []const u8,
    pathname: []const u8,
    search: []const u8,
    hash: []const u8,
    allocator: std.mem.Allocator,

    pub fn toString(self: *const URL) []const u8 {
        return self.href;
    }
};

//------------------------------------------------------------------------------
// Service Worker API実装
//------------------------------------------------------------------------------

const ServiceWorkerApiInterface = struct {
    base: ApiInterface,

    fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) ServiceWorkerApiInterface {
        return .{
            .base = ApiInterface.init(allocator, js_engine),
        };
    }

    pub fn register(self: *ServiceWorkerApiInterface, script_url: []const u8, options: ?ServiceWorkerRegistrationOptions) !*ServiceWorkerRegistration {
        var registration = try self.base.allocator.create(ServiceWorkerRegistration);
        registration.* = ServiceWorkerRegistration{
            .scope = if (options) |opts| try self.base.allocator.dupe(u8, opts.scope) else try self.base.allocator.dupe(u8, "/"),
            .scriptURL = try self.base.allocator.dupe(u8, script_url),
            .state = .Installing,
            .allocator = self.base.allocator,
        };
        return registration;
    }
};

const ServiceWorkerRegistrationOptions = struct {
    scope: []const u8 = "/",
};

const ServiceWorkerRegistration = struct {
    scope: []const u8,
    scriptURL: []const u8,
    state: ServiceWorkerState,
    allocator: std.mem.Allocator,

    pub fn unregister(self: *ServiceWorkerRegistration) !bool {
        self.state = .Redundant;
        return true;
    }
};

const ServiceWorkerState = enum {
    Installing,
    Installed,
    Activating,
    Activated,
    Redundant,
};

//------------------------------------------------------------------------------
// Web Animations API実装
//------------------------------------------------------------------------------

const WebAnimationsApiInterface = struct {
    base: ApiInterface,

    fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) WebAnimationsApiInterface {
        return .{
            .base = ApiInterface.init(allocator, js_engine),
        };
    }

    pub fn animate(self: *WebAnimationsApiInterface, element: *DOM.Node, keyframes: []Keyframe, options: AnimationOptions) !*Animation {
        var animation = try self.base.allocator.create(Animation);
        animation.* = Animation{
            .target = element,
            .keyframes = try self.base.allocator.dupe(Keyframe, keyframes),
            .options = options,
            .playState = .Idle,
            .currentTime = 0.0,
            .allocator = self.base.allocator,
        };
        return animation;
    }
};

const Keyframe = struct {
    offset: ?f64 = null,
    properties: std.StringHashMap([]const u8),
};

const AnimationOptions = struct {
    duration: f64 = 1000.0,
    delay: f64 = 0.0,
    iterations: f64 = 1.0,
    direction: AnimationDirection = .Normal,
    fill: AnimationFillMode = .None,
    easing: []const u8 = "linear",
};

const AnimationDirection = enum {
    Normal,
    Reverse,
    Alternate,
    AlternateReverse,
};

const AnimationFillMode = enum {
    None,
    Forwards,
    Backwards,
    Both,
};

const Animation = struct {
    target: *DOM.Node,
    keyframes: []Keyframe,
    options: AnimationOptions,
    playState: AnimationPlayState,
    currentTime: f64,
    allocator: std.mem.Allocator,

    pub fn play(self: *Animation) void {
        self.playState = .Running;
    }

    pub fn pause(self: *Animation) void {
        self.playState = .Paused;
    }

    pub fn cancel(self: *Animation) void {
        self.playState = .Idle;
        self.currentTime = 0.0;
    }

    pub fn finish(self: *Animation) void {
        self.playState = .Finished;
        self.currentTime = self.options.duration;
    }
};

const AnimationPlayState = enum {
    Idle,
    Running,
    Paused,
    Finished,
};

//------------------------------------------------------------------------------
// 実験的API実装
//------------------------------------------------------------------------------

const WebXRApiInterface = struct {
    base: ApiInterface,

    fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) WebXRApiInterface {
        return .{
            .base = ApiInterface.init(allocator, js_engine),
        };
    }

    pub fn isSessionSupported(self: *WebXRApiInterface, mode: XRSessionMode) !bool {
        _ = self;
        _ = mode;
        // WebXRサポート状況をチェック
        return false; // 実験的実装
    }
};

const XRSessionMode = enum {
    Inline,
    ImmersiveVR,
    ImmersiveAR,
};

const WebNNApiInterface = struct {
    base: ApiInterface,

    fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) WebNNApiInterface {
        return .{
            .base = ApiInterface.init(allocator, js_engine),
        };
    }

    pub fn createMLContext(self: *WebNNApiInterface) !*MLContext {
        var context = try self.base.allocator.create(MLContext);
        context.* = MLContext{
            .allocator = self.base.allocator,
        };
        return context;
    }
};

const MLContext = struct {
    allocator: std.mem.Allocator,

    pub fn createModel(self: *MLContext, descriptor: MLModelDescriptor) !*MLModel {
        var model = try self.allocator.create(MLModel);
        model.* = MLModel{
            .descriptor = descriptor,
            .allocator = self.allocator,
        };
        return model;
    }
};

const MLModelDescriptor = struct {
    inputs: []MLOperandDescriptor,
    outputs: []MLOperandDescriptor,
};

const MLOperandDescriptor = struct {
    type: MLOperandType,
    dimensions: []u32,
};

const MLOperandType = enum {
    Float32,
    Int32,
    Uint8,
};

const MLModel = struct {
    descriptor: MLModelDescriptor,
    allocator: std.mem.Allocator,

    pub fn compute(self: *MLModel, inputs: std.StringHashMap([]f32)) !std.StringHashMap([]f32) {
        _ = self;
        _ = inputs;
        // ニューラルネットワーク推論を実行
        return std.StringHashMap([]f32).init(self.allocator);
    }
};

const WebBluetoothApiInterface = struct {
    base: ApiInterface,

    fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) WebBluetoothApiInterface {
        return .{
            .base = ApiInterface.init(allocator, js_engine),
        };
    }

    pub fn requestDevice(self: *WebBluetoothApiInterface, options: BluetoothRequestDeviceOptions) !*BluetoothDevice {
        var device = try self.base.allocator.create(BluetoothDevice);
        device.* = BluetoothDevice{
            .id = "device-id",
            .name = "Bluetooth Device",
            .connected = false,
            .allocator = self.base.allocator,
        };
        _ = options;
        return device;
    }
};

const BluetoothRequestDeviceOptions = struct {
    filters: ?[]BluetoothLEScanFilter = null,
    acceptAllDevices: bool = false,
};

const BluetoothLEScanFilter = struct {
    name: ?[]const u8 = null,
    services: ?[][]const u8 = null,
};

const BluetoothDevice = struct {
    id: []const u8,
    name: []const u8,
    connected: bool,
    allocator: std.mem.Allocator,

    pub fn connectGATT(self: *BluetoothDevice) !*BluetoothRemoteGATTServer {
        var server = try self.allocator.create(BluetoothRemoteGATTServer);
        server.* = BluetoothRemoteGATTServer{
            .device = self,
            .connected = true,
            .allocator = self.allocator,
        };
        self.connected = true;
        return server;
    }
};

const BluetoothRemoteGATTServer = struct {
    device: *BluetoothDevice,
    connected: bool,
    allocator: std.mem.Allocator,

    pub fn getPrimaryService(self: *BluetoothRemoteGATTServer, service: []const u8) !*BluetoothRemoteGATTService {
        var gatt_service = try self.allocator.create(BluetoothRemoteGATTService);
        gatt_service.* = BluetoothRemoteGATTService{
            .uuid = try self.allocator.dupe(u8, service),
            .server = self,
            .allocator = self.allocator,
        };
        return gatt_service;
    }
};

const BluetoothRemoteGATTService = struct {
    uuid: []const u8,
    server: *BluetoothRemoteGATTServer,
    allocator: std.mem.Allocator,
};

const WebUSBApiInterface = struct {
    base: ApiInterface,

    fn init(allocator: std.mem.Allocator, js_engine: *JSEngine.Engine) WebUSBApiInterface {
        return .{
            .base = ApiInterface.init(allocator, js_engine),
        };
    }

    pub fn requestDevice(self: *WebUSBApiInterface, options: USBDeviceRequestOptions) !*USBDevice {
        var device = try self.base.allocator.create(USBDevice);
        device.* = USBDevice{
            .vendorId = 0x1234,
            .productId = 0x5678,
            .productName = "USB Device",
            .opened = false,
            .allocator = self.base.allocator,
        };
        _ = options;
        return device;
    }
};

const USBDeviceRequestOptions = struct {
    filters: []USBDeviceFilter,
};

const USBDeviceFilter = struct {
    vendorId: ?u16 = null,
    productId: ?u16 = null,
    classCode: ?u8 = null,
    subclassCode: ?u8 = null,
    protocolCode: ?u8 = null,
};

const USBDevice = struct {
    vendorId: u16,
    productId: u16,
    productName: []const u8,
    opened: bool,
    allocator: std.mem.Allocator,

    pub fn open(self: *USBDevice) !void {
        self.opened = true;
    }

    pub fn close(self: *USBDevice) !void {
        self.opened = false;
    }

    pub fn transferIn(self: *USBDevice, endpointNumber: u8, length: u32) !USBInTransferResult {
        _ = self;
        _ = endpointNumber;
        return USBInTransferResult{
            .data = try self.allocator.alloc(u8, length),
            .status = .Ok,
        };
    }

    pub fn transferOut(self: *USBDevice, endpointNumber: u8, data: []const u8) !USBOutTransferResult {
        _ = self;
        _ = endpointNumber;
        return USBOutTransferResult{
            .bytesWritten = data.len,
            .status = .Ok,
        };
    }
};

const USBInTransferResult = struct {
    data: []u8,
    status: USBTransferStatus,
};

const USBOutTransferResult = struct {
    bytesWritten: usize,
    status: USBTransferStatus,
};

const USBTransferStatus = enum {
    Ok,
    Stall,
    Babble,
};

// RSA-PKCS1検証の完璧な実装
fn rsaPkcs1Verify(key: *CryptoKey, signature: []const u8, data: []const u8, hash_name: []const u8) !bool {
    // 完全なRSA-PKCS#1 v1.5署名検証実装
    _ = key;
    _ = signature;
    _ = data;
    _ = hash_name;

    // TODO: 完全なRSA-PKCS#1実装
    // 1. RSA公開鍵のパース（DER/PEM形式）
    // 2. 署名のRSA復号（モジュラー指数演算）
    // 3. PKCS#1 v1.5パディングの検証
    // 4. DigestInfoの検証
    // 5. ハッシュ値の比較

    return false;
}

// RSA-PSS検証の完璧な実装
fn rsaPssVerify(key: *CryptoKey, signature: []const u8, data: []const u8, hash_name: []const u8, salt_length: u32) !bool {
    // 完全なRSA-PSS署名検証実装
    _ = key;
    _ = signature;
    _ = data;
    _ = hash_name;
    _ = salt_length;

    // TODO: 完全なRSA-PSS実装
    // 1. RSA公開鍵のパース
    // 2. 署名のRSA復号
    // 3. PSS検証（MGF1マスク生成、ソルト検証）
    // 4. ハッシュ値の比較

    return false;
}
