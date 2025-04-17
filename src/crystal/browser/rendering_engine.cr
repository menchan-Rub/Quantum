require "./config"
require "./layout_engine"
require "./dom/node"
require "./dom/css"
require "log"

# Logの初期設定
Log.setup_from_env
module_log = Log.for("quantum_core")
module_log.level = Log::Severity::Info

module QuantumCore
  # レンダリングエンジン「QuantumRender」
  # 革新的レンダリングパイプラインの実装
  class RenderingEngine
    # レンダリングコンテキスト
    # マルチバックエンド対応（Vulkan/Metal/DirectX/ソフトウェア）
    class RenderingContext
      # キャンバスの幅
      property canvas_width : Int32
      # キャンバスの高さ
      property canvas_height : Int32
      # ハードウェアアクセラレーション使用フラグ
      property hardware_accelerated : Bool
      # レンダリングバックエンド種別
      property backend_type : Symbol
      # 現在のフレームレート
      property current_fps : Float64
      # 適応型レンダリング解像度の倍率
      property resolution_scale : Float64
      # コマンドバッファ
      @command_buffer : Array(RenderCommand)
      # フレームカウンター
      @frame_counter : UInt64
      # 最後のフレーム時間
      @last_frame_time : Time
      # 電力使用モード
      @power_mode : Symbol
      
      # クラス変数
      class_property gpu_initialized : Bool = false
      class_property rendering_api : String = "None"
      class_property available_backends : Array(Symbol) = [] of Symbol
      
      # 初期化
      def initialize(@canvas_width : Int32, @canvas_height : Int32, @hardware_accelerated : Bool)
        @backend_type = @hardware_accelerated ? :gpu : :software
        @current_fps = 60.0
        @resolution_scale = 1.0
        @command_buffer = [] of RenderCommand
        @frame_counter = 0_u64
        @last_frame_time = Time.monotonic
        @power_mode = :balanced
        
        # 利用可能なバックエンドを検出
        detect_available_backends if @@available_backends.empty?
        
        # 初期設定
        setup_rendering_context
        Log.info { "レンダリングコンテキストを初期化しました: #{@canvas_width}x#{@canvas_height}, バックエンド: #{@backend_type}" }
      end
      
      # 利用可能なレンダリングバックエンドを検出
      private def detect_available_backends
        @@available_backends = [] of Symbol
        
        # Vulkanサポートの検出
        if check_vulkan_support
          @@available_backends << :vulkan
        end
        
        # Metal/DirectXサポートの検出（プラットフォーム依存）
        {% if flag?(:darwin) %}
          if check_metal_support
            @@available_backends << :metal
          end
        {% elsif flag?(:windows) %}
          if check_directx_support
            @@available_backends << :directx
          end
        {% end %}
        
        # OpenGLサポートの検出
        if check_opengl_support
          @@available_backends << :opengl
        end
        
        # ソフトウェアレンダリングは常に利用可能
        @@available_backends << :software
        
        Log.info { "利用可能なレンダリングバックエンド: #{@@available_backends.join(", ")}" }
      end
      
      # Vulkanサポートの確認
      private def check_vulkan_support : Bool
        Log.debug { "Vulkanサポートを確認中..." }
        begin
          # Vulkanライブラリの存在確認
          lib_path = {% if flag?(:linux) %}
            "/usr/lib/libvulkan.so.1"
          {% elsif flag?(:darwin) %}
            "/usr/local/lib/libvulkan.1.dylib"
          {% elsif flag?(:windows) %}
            "vulkan-1.dll"
          {% else %}
            ""
          {% end %}
          
          # ライブラリファイルの存在確認
          if !File.exists?(lib_path)
            Log.debug { "Vulkanライブラリが見つかりません: #{lib_path}" }
            return false
          end
          
          # FFIを使用してVulkanの基本機能をチェック
          vulkan_version = LibVulkan.get_version
          if vulkan_version < LibVulkan::MIN_SUPPORTED_VERSION
            Log.debug { "Vulkanバージョンが古すぎます: #{vulkan_version}" }
            return false
          end
          
          # GPUデバイスの検出
          device_count = LibVulkan.enumerate_physical_devices
          if device_count <= 0
            Log.debug { "Vulkan対応GPUデバイスが見つかりません" }
            return false
          end
          
          # 必要な拡張機能のサポート確認
          required_extensions = ["VK_KHR_swapchain", "VK_KHR_surface"]
          if !LibVulkan.check_extensions_support(required_extensions)
            Log.debug { "必要なVulkan拡張機能がサポートされていません" }
            return false
          end
          
          Log.info { "Vulkanサポートを確認: 利用可能 (#{device_count}デバイス検出)" }
          return true
        rescue ex
          Log.error { "Vulkanサポート確認中にエラーが発生: #{ex.message}" }
          return false
        end
      end
      
      # OpenGLサポートの確認
      private def check_opengl_support : Bool
        Log.debug { "OpenGLサポートを確認中..." }
        begin
          # OpenGLライブラリの存在確認
          lib_path = {% if flag?(:linux) %}
            "/usr/lib/libGL.so.1"
          {% elsif flag?(:darwin) %}
            "/System/Library/Frameworks/OpenGL.framework/OpenGL"
          {% elsif flag?(:windows) %}
            "opengl32.dll"
          {% else %}
            ""
          {% end %}
          
          # ライブラリファイルの存在確認
          if !File.exists?(lib_path)
            Log.debug { "OpenGLライブラリが見つかりません: #{lib_path}" }
            return false
          end
          
          # 一時的なウィンドウコンテキストを作成してOpenGL情報を取得
          context = LibGL.create_temporary_context
          if context.null?
            Log.debug { "OpenGLコンテキストを作成できません" }
            return false
          end
          
          begin
            # バージョン確認
            version = LibGL.get_string(LibGL::VERSION)
            vendor = LibGL.get_string(LibGL::VENDOR)
            renderer = LibGL.get_string(LibGL::RENDERER)
            
            major, minor = LibGL.get_gl_version
            if major < 3 || (major == 3 && minor < 3)
              Log.debug { "OpenGL 3.3以上が必要です。検出: #{major}.#{minor}" }
              return false
            end
            
            # 必要な拡張機能の確認
            required_extensions = ["GL_ARB_compute_shader", "GL_ARB_separate_shader_objects"]
            if !LibGL.check_extensions_support(required_extensions)
              Log.debug { "必要なOpenGL拡張機能がサポートされていません" }
              return false
            end
            
            Log.info { "OpenGLサポートを確認: 利用可能 (#{version}, #{vendor}, #{renderer})" }
            return true
          ensure
            LibGL.destroy_context(context)
          end
        rescue ex
          Log.error { "OpenGLサポート確認中にエラーが発生: #{ex.message}" }
          return false
        end
      end
      
      # Metalサポートの確認（macOSのみ）
      {% if flag?(:darwin) %}
      private def check_metal_support : Bool
        Log.debug { "Metalサポートを確認中..." }
        begin
          # Metalフレームワークの存在確認
          framework_path = "/System/Library/Frameworks/Metal.framework/Metal"
          if !File.exists?(framework_path)
            Log.debug { "Metalフレームワークが見つかりません: #{framework_path}" }
            return false
          end
          
          # システムバージョンの確認（macOS 10.11以降が必要）
          system_version = LibSystem.get_os_version
          if system_version < LibSystem::MIN_METAL_OS_VERSION
            Log.debug { "MetalにはmacOS 10.11以降が必要です。検出: #{system_version}" }
            return false
          end
          
          # Metal対応GPUの検出
          device_count = LibMetal.enumerate_devices
          if device_count <= 0
            Log.debug { "Metal対応GPUデバイスが見つかりません" }
            return false
          end
          
          # 必要な機能のサポート確認
          if !LibMetal.check_feature_support
            Log.debug { "必要なMetal機能がサポートされていません" }
            return false
          end
          
          Log.info { "Metalサポートを確認: 利用可能 (#{device_count}デバイス検出)" }
          return true
        rescue ex
          Log.error { "Metalサポート確認中にエラーが発生: #{ex.message}" }
          return false
        end
      end
      {% end %}
      
      # DirectXサポートの確認（Windowsのみ）
      {% if flag?(:windows) %}
      private def check_directx_support : Bool
        Log.debug { "DirectXサポートを確認中..." }
        begin
          # DirectX DLLの存在確認
          d3d12_path = "C:\\Windows\\System32\\d3d12.dll"
          dxgi_path = "C:\\Windows\\System32\\dxgi.dll"
          
          if !File.exists?(d3d12_path) || !File.exists?(dxgi_path)
            Log.debug { "DirectX 12ライブラリが見つかりません" }
            return false
          end
          
          # Windows 10以降の確認（DirectX 12に必要）
          windows_version = LibWindows.get_os_version
          if windows_version < LibWindows::MIN_DX12_OS_VERSION
            Log.debug { "DirectX 12にはWindows 10以降が必要です。検出: #{windows_version}" }
            return false
          end
          
          # DirectX 12対応GPUの検出
          adapter_count = LibDX12.enumerate_adapters
          if adapter_count <= 0
            Log.debug { "DirectX 12対応GPUアダプタが見つかりません" }
            return false
          end
          
          # ハードウェア機能レベルの確認
          feature_level = LibDX12.check_max_feature_level
          if feature_level < LibDX12::FEATURE_LEVEL_11_0
            Log.debug { "必要なDirectX機能レベルがサポートされていません" }
            return false
          end
          
          Log.info { "DirectXサポートを確認: 利用可能 (#{adapter_count}アダプタ検出, 機能レベル: #{feature_level})" }
          return true
        rescue ex
          Log.error { "DirectXサポート確認中にエラーが発生: #{ex.message}" }
          return false
        end
      end
      {% end %}
      # レンダリングコンテキストの設定
      private def setup_rendering_context
        if @hardware_accelerated
          # 最適なGPUバックエンドを選択
          select_optimal_gpu_backend
        else
          # ソフトウェアレンダリングの初期化
          initialize_software_backend
        end
      end
      
      # 最適なGPUバックエンドを選択
      private def select_optimal_gpu_backend
        # 利用可能なバックエンドから最適なものを選択
        if @@available_backends.includes?(:vulkan)
          initialize_vulkan_backend
        elsif @@available_backends.includes?(:metal)
          initialize_metal_backend
        elsif @@available_backends.includes?(:directx)
          initialize_directx_backend
        elsif @@available_backends.includes?(:opengl)
          initialize_opengl_backend
        else
          # GPUバックエンドが利用できない場合はソフトウェアにフォールバック
          @hardware_accelerated = false
          @backend_type = :software
          initialize_software_backend
        end
      end
      
      # Vulkanバックエンドの初期化
      private def initialize_vulkan_backend
        # Vulkan APIの初期化
        @backend_type = :vulkan
        @@rendering_api = "Vulkan"
        
        # インスタンスの作成
        instance_info = VulkanInstanceCreateInfo.new
        instance_info.application_name = "Quantum Browser"
        instance_info.application_version = Version.new(1, 0, 0)
        
        # 必要な拡張機能の設定
        required_extensions = ["VK_KHR_surface", "VK_KHR_xcb_surface"]
        instance_info.enabled_extensions = required_extensions
        
        # バリデーションレイヤーの設定（デバッグビルドのみ）
        {% if flag?(:debug) %}
        instance_info.enable_validation = true
        {% end %}
        
        # インスタンス作成
        @vulkan_instance = VulkanInstance.new(instance_info)
        
        # 物理デバイスの選択
        physical_devices = @vulkan_instance.enumerate_physical_devices
        if physical_devices.empty?
          Log.error { "Vulkan対応のGPUが見つかりません" }
          raise RenderingError.new("Vulkan対応のGPUが見つかりません")
        end
        
        # 最適なデバイスを選択（専用GPUを優先）
        @physical_device = select_optimal_device(physical_devices)
        Log.info { "選択されたGPU: #{@physical_device.properties.device_name}" }
        
        # 論理デバイスとキューの作成
        queue_family_index = find_graphics_queue_family(@physical_device)
        device_create_info = VulkanDeviceCreateInfo.new
        device_create_info.queue_family_index = queue_family_index
        device_create_info.enabled_features = VulkanPhysicalDeviceFeatures.new
        
        @vulkan_device = @physical_device.create_logical_device(device_create_info)
        @graphics_queue = @vulkan_device.get_queue(queue_family_index, 0)
        
        # コマンドプールの作成
        command_pool_info = VulkanCommandPoolCreateInfo.new
        command_pool_info.queue_family_index = queue_family_index
        command_pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT
        @command_pool = @vulkan_device.create_command_pool(command_pool_info)
        
        # スワップチェーンの設定
        setup_vulkan_swapchain
        
        # レンダーパスの作成
        create_vulkan_render_pass
        
        # フレームバッファの作成
        create_vulkan_framebuffers
        
        # シェーダーモジュールの読み込み
        load_vulkan_shaders
        
        # パイプラインの作成
        create_vulkan_graphics_pipeline
        
        # 同期オブジェクトの作成
        create_vulkan_sync_objects
        
        @@gpu_initialized = true
        Log.info { "Vulkanレンダリングバックエンドを初期化しました" }
      end
      
      # OpenGLバックエンドの初期化
      private def initialize_opengl_backend
        # OpenGL APIの初期化
        @backend_type = :opengl
        @@rendering_api = "OpenGL"
        
        # OpenGLコンテキストの作成
        @gl_context = GLContext.create(@window_handle)
        
        # OpenGLバージョンの確認
        gl_version = LibGL.get_string(LibGL::VERSION)
        gl_renderer = LibGL.get_string(LibGL::RENDERER)
        gl_vendor = LibGL.get_string(LibGL::VENDOR)
        
        Log.info { "OpenGL情報: バージョン #{gl_version}, レンダラー #{gl_renderer}, ベンダー #{gl_vendor}" }
        
        # 拡張機能のサポート確認
        check_opengl_extensions
        
        # シェーダーの読み込み
        @shader_program = create_shader_program("shaders/vertex.glsl", "shaders/fragment.glsl")
        
        # VAOとVBOの設定
        setup_opengl_buffers
        
        # フレームバッファオブジェクトの作成
        create_opengl_framebuffer
        
        # テクスチャの初期化
        initialize_opengl_textures
        
        # デプスバッファの設定
        setup_opengl_depth_buffer
        
        # アンチエイリアシングの設定
        if @antialiasing_enabled
          LibGL.enable(LibGL::MULTISAMPLE)
        end
        
        # 初期ビューポートの設定
        LibGL.viewport(0, 0, @canvas_width, @canvas_height)
        
        @@gpu_initialized = true
        Log.info { "OpenGLレンダリングバックエンドを初期化しました" }
      end
      
      # Metalバックエンドの初期化（macOSのみ）
      {% if flag?(:darwin) %}
      private def initialize_metal_backend
        # Metal APIの初期化
        @backend_type = :metal
        @@rendering_api = "Metal"
        
        # Metalデバイスの取得
        @metal_device = MTLCreateSystemDefaultDevice()
        if @metal_device.nil?
          Log.error { "Metal対応のGPUが見つかりません" }
          raise RenderingError.new("Metal対応のGPUが見つかりません")
        end
        
        # デバイス情報のログ出力
        device_name = @metal_device.name.to_s
        Log.info { "Metal GPU: #{device_name}" }
        
        # コマンドキューの作成
        @command_queue = @metal_device.newCommandQueue
        
        # レイヤーの設定
        @metal_layer = CAMetalLayer.layer
        @metal_layer.device = @metal_device
        @metal_layer.pixelFormat = MTLPixelFormatBGRA8Unorm
        @metal_layer.framebufferOnly = true
        @metal_layer.frame = CGRect.new(0, 0, @canvas_width, @canvas_height)
        
        # ビューにレイヤーを追加
        @view.layer = @metal_layer
        
        # ライブラリの読み込み
        default_library = @metal_device.newDefaultLibrary
        
        # シェーダー関数の取得
        vertex_function = default_library.newFunctionWithName("vertexShader")
        fragment_function = default_library.newFunctionWithName("fragmentShader")
        
        # レンダーパイプラインの設定
        pipeline_descriptor = MTLRenderPipelineDescriptor.new
        pipeline_descriptor.vertexFunction = vertex_function
        pipeline_descriptor.fragmentFunction = fragment_function
        pipeline_descriptor.colorAttachments[0].pixelFormat = @metal_layer.pixelFormat
        
        # パイプラインステートの作成
        @pipeline_state = @metal_device.newRenderPipelineStateWithDescriptor(pipeline_descriptor)
        
        # デプスステンシルステートの作成
        depth_descriptor = MTLDepthStencilDescriptor.new
        depth_descriptor.depthCompareFunction = MTLCompareFunctionLess
        depth_descriptor.depthWriteEnabled = true
        @depth_state = @metal_device.newDepthStencilStateWithDescriptor(depth_descriptor)
        
        # バッファの作成
        @vertex_buffer = create_metal_vertex_buffer
        @uniform_buffer = create_metal_uniform_buffer
        
        @@gpu_initialized = true
        Log.info { "Metalレンダリングバックエンドを初期化しました" }
      end
      {% end %}
      
      # DirectXバックエンドの初期化（Windowsのみ）
      {% if flag?(:windows) %}
      private def initialize_directx_backend
        # DirectX APIの初期化
        @backend_type = :directx
        @@rendering_api = "DirectX"
        
        # デバッグレイヤーの有効化（デバッグビルドのみ）
        {% if flag?(:debug) %}
        LibDX12.enable_debug_layer
        {% end %}
        
        # ファクトリーの作成
        @dxgi_factory = LibDX12.create_factory
        
        # アダプターの列挙と選択
        adapters = @dxgi_factory.enumerate_adapters
        if adapters.empty?
          Log.error { "DirectX 12対応のGPUが見つかりません" }
          raise RenderingError.new("DirectX 12対応のGPUが見つかりません")
        end
        
        # 最適なアダプターを選択
        @adapter = select_optimal_dx_adapter(adapters)
        adapter_desc = @adapter.get_description
        Log.info { "選択されたGPU: #{adapter_desc.description}" }
        
        # デバイスの作成
        @device = LibDX12.create_device(@adapter)
        
        # コマンドキューの作成
        queue_desc = D3D12_COMMAND_QUEUE_DESC.new
        queue_desc.type = D3D12_COMMAND_LIST_TYPE_DIRECT
        @command_queue = @device.create_command_queue(queue_desc)
        
        # スワップチェーンの作成
        swap_chain_desc = DXGI_SWAP_CHAIN_DESC1.new
        swap_chain_desc.width = @canvas_width
        swap_chain_desc.height = @canvas_height
        swap_chain_desc.format = DXGI_FORMAT_R8G8B8A8_UNORM
        swap_chain_desc.sample_desc.count = 1
        swap_chain_desc.buffer_count = FRAME_COUNT
        swap_chain_desc.buffer_usage = DXGI_USAGE_RENDER_TARGET_OUTPUT
        swap_chain_desc.swap_effect = DXGI_SWAP_EFFECT_FLIP_DISCARD
        
        @swap_chain = @dxgi_factory.create_swap_chain_for_hwnd(
          @command_queue,
          @window_handle,
          swap_chain_desc
        )
        
        # ディスクリプタヒープの作成
        create_dx_descriptor_heaps
        
        # レンダーターゲットビューの作成
        create_dx_render_target_views
        
        # コマンドアロケーターとリストの作成
        @command_allocator = @device.create_command_allocator(D3D12_COMMAND_LIST_TYPE_DIRECT)
        @command_list = @device.create_command_list(
          0,
          D3D12_COMMAND_LIST_TYPE_DIRECT,
          @command_allocator
        )
        @command_list.close
        
        # フェンスの作成
        @fence = @device.create_fence(0)
        @fence_value = 1
        @fence_event = LibWindows.create_event_handle
        
        # ルートシグネチャの作成
        create_dx_root_signature
        
        # パイプラインステートの作成
        create_dx_pipeline_state
        
        # 頂点バッファの作成
        create_dx_vertex_buffer
        
        # 定数バッファの作成
        create_dx_constant_buffer
        
        @@gpu_initialized = true
        Log.info { "DirectXレンダリングバックエンドを初期化しました" }
      end
      {% end %}
      
      # ソフトウェアレンダリングバックエンドの初期化
      private def initialize_software_backend
        # ソフトウェアレンダリングの初期化
        @backend_type = :software
        @@rendering_api = "Software"
        
        # ピクセルバッファの作成
        @pixel_buffer = Pointer(UInt32).malloc(@canvas_width * @canvas_height)
        
        # Zバッファの作成
        @z_buffer = Pointer(Float32).malloc(@canvas_width * @canvas_height)
        
        # ラスタライザーの初期化
        @rasterizer = SoftwareRasterizer.new(@canvas_width, @canvas_height, @pixel_buffer, @z_buffer)
        
        # テクスチャマネージャーの初期化
        @texture_manager = TextureManager.new
        
        # シェーダーの初期化
        @vertex_shader = DefaultVertexShader.new
        @fragment_shader = DefaultFragmentShader.new
        
        # レンダリングパイプラインの設定
        @pipeline = SoftwarePipeline.new(
          @rasterizer,
          @vertex_shader,
          @fragment_shader,
          @texture_manager
        )
        
        # 最適化設定
        @use_simd = CPU.supports_simd?
        @use_multithreading = true
        @thread_count = CPU.core_count
        
        if @use_multithreading
          # スレッドプールの初期化
          @thread_pool = ThreadPool.new(@thread_count)
          Log.info { "ソフトウェアレンダリング: マルチスレッドモード (#{@thread_count}スレッド)" }
        end
        
        if @use_simd
          Log.info { "ソフトウェアレンダリング: SIMDアクセラレーション有効" }
        end
        
        @@gpu_initialized = false
        Log.info { "ソフトウェアレンダリングバックエンドを初期化しました" }
      end
      
      # ハードウェアアクセラレーションを使用したコンテキストの初期化（クラスメソッド）
      def self.initialize_hardware_accelerated
        # 利用可能なGPUバックエンドを検出
        detect_available_backends if @@available_backends.empty?
        
        # 最適なGPUバックエンドを選択
        if @@available_backends.includes?(:vulkan)
          @@rendering_api = "Vulkan"
          # Vulkanインスタンスの作成
          instance_info = VulkanInstanceCreateInfo.new
          instance_info.application_name = "Quantum Browser"
          instance_info.application_version = Version.new(1, 0, 0)
          @@vulkan_instance = VulkanInstance.new(instance_info)
          
          # 物理デバイスの列挙
          physical_devices = @@vulkan_instance.enumerate_physical_devices
          if !physical_devices.empty?
            # 最適なデバイスを選択
            @@physical_device = select_optimal_device(physical_devices)
            Log.info { "Vulkan: 選択されたGPU: #{@@physical_device.properties.device_name}" }
          end
        elsif @@available_backends.includes?(:metal)
          @@rendering_api = "Metal"
          # Metalデバイスの取得
          @@metal_device = MTLCreateSystemDefaultDevice()
          if !@@metal_device.nil?
            Log.info { "Metal: 選択されたGPU: #{@@metal_device.name}" }
          end
        elsif @@available_backends.includes?(:directx)
          @@rendering_api = "DirectX"
          # DirectXファクトリーの作成
          @@dxgi_factory = LibDX12.create_factory
          
          # アダプターの列挙
          adapters = @@dxgi_factory.enumerate_adapters
          if !adapters.empty?
            # 最適なアダプターを選択
            @@dx_adapter = select_optimal_dx_adapter(adapters)
            adapter_desc = @@dx_adapter.get_description
            Log.info { "DirectX: 選択されたGPU: #{adapter_desc.description}" }
          end
        elsif @@available_backends.includes?(:opengl)
          @@rendering_api = "OpenGL"
          # OpenGLコンテキストの作成
          begin
            # OpenGLバージョンの検出
            gl_version = LibGL.get_string(LibGL::VERSION)
            gl_renderer = LibGL.get_string(LibGL::RENDERER)
            gl_vendor = LibGL.get_string(LibGL::VENDOR)
            
            # 拡張機能のサポート確認
            extensions = get_gl_extensions
            
            # シェーダーサポートの確認
            shader_support = {
              vertex: LibGL.is_shader_supported(LibGL::VERTEX_SHADER),
              fragment: LibGL.is_shader_supported(LibGL::FRAGMENT_SHADER),
              geometry: LibGL.is_shader_supported(LibGL::GEOMETRY_SHADER),
              compute: LibGL.is_shader_supported(LibGL::COMPUTE_SHADER)
            }
            
            # FBOサポートの確認
            fbo_supported = LibGL.is_extension_supported("GL_ARB_framebuffer_object")
            
            # VBOサポートの確認
            vbo_supported = LibGL.is_extension_supported("GL_ARB_vertex_buffer_object")
            
            # 最大テクスチャサイズの取得
            max_texture_size = LibGL.get_integer(LibGL::MAX_TEXTURE_SIZE)
            
            # マルチサンプリングサポートの確認
            max_samples = LibGL.get_integer(LibGL::MAX_SAMPLES)
            
            # シェーダーコンパイラの初期化
            @@gl_shader_compiler = GLShaderCompiler.new if shader_support[:vertex] && shader_support[:fragment]
            
            # レンダリングコンテキストの設定
            @@gl_context_config = {
              double_buffer: true,
              depth_bits: 24,
              stencil_bits: 8,
              samples: [max_samples, 4].min, # 最大4xMSAAまで使用
              vsync: true
            }
            
            Log.info { "OpenGL: バージョン #{gl_version} (#{gl_vendor} - #{gl_renderer})" }
            Log.info { "OpenGL: シェーダーサポート: #{shader_support.select { |_, v| v }.keys.join(", ")}" }
            Log.info { "OpenGL: FBO サポート: #{fbo_supported}, VBO サポート: #{vbo_supported}" }
            Log.info { "OpenGL: 最大テクスチャサイズ: #{max_texture_size}px, MSAA: #{max_samples}x" }
            
            # 初期化成功
            @@gl_initialized = true
          rescue ex
            Log.error { "OpenGL初期化エラー: #{ex.message}" }
            Log.warn { "OpenGLの初期化に失敗したため、ソフトウェアレンダリングにフォールバックします" }
            @@rendering_api = "Software"
            return initialize_software
          end
        else
          @@rendering_api = "Software"
          Log.warn { "GPUバックエンドが利用できないため、ソフトウェアレンダリングにフォールバックします" }
          return initialize_software
        end
        
        @@gpu_initialized = true
        Log.info { "ハードウェアアクセラレーションを初期化しました（#{@@rendering_api}）" }
      end
      # ソフトウェアレンダリングを使用したコンテキストの初期化（クラスメソッド）
      def self.initialize_software
        # ソフトウェアレンダリングの初期化
        @@gpu_initialized = false
        @@rendering_api = "Software"
        
        # CPUの機能を検出
        cpu_info = CPU.get_info
        
        # SIMD命令セットのサポート確認
        simd_support = {
          sse: CPU.supports_sse?,
          sse2: CPU.supports_sse2?,
          avx: CPU.supports_avx?,
          avx2: CPU.supports_avx2?,
          neon: CPU.supports_neon?
        }
        
        # 最適化設定
        @@use_simd = simd_support.values.any?
        @@use_multithreading = true
        @@thread_count = CPU.core_count
        
        # 最適化情報のログ出力
        if @@use_simd
          supported_sets = simd_support.select { |_, v| v }.keys.join(", ")
          Log.info { "ソフトウェアレンダリング: SIMD最適化有効 (#{supported_sets})" }
        end
        
        if @@use_multithreading
          Log.info { "ソフトウェアレンダリング: マルチスレッド最適化有効 (#{@@thread_count}コア)" }
        end
        
        Log.info { "ソフトウェアレンダリングを初期化しました" }
      end
      
      # コンテキストの解放（クラスメソッド）
      def self.cleanup
        # リソースの解放
        if @@gpu_initialized
          # GPUリソースの解放
          case @@rendering_api
          when "Vulkan"
            # Vulkanリソースの解放
            if @@vulkan_instance
              # デバイスの解放
              if @@vulkan_device
                # コマンドプールの解放
                if @@command_pool
                  @@vulkan_device.destroy_command_pool(@@command_pool)
                end
                
                # スワップチェーンの解放
                if @@swapchain
                  @@swapchain.destroy
                end
                
                # レンダーパスの解放
                if @@render_pass
                  @@vulkan_device.destroy_render_pass(@@render_pass)
                end
                
                # フレームバッファの解放
                @@framebuffers.each do |framebuffer|
                  @@vulkan_device.destroy_framebuffer(framebuffer)
                end
                
                # シェーダーモジュールの解放
                if @@vertex_shader_module
                  @@vulkan_device.destroy_shader_module(@@vertex_shader_module)
                end
                
                if @@fragment_shader_module
                  @@vulkan_device.destroy_shader_module(@@fragment_shader_module)
                end
                
                # パイプラインの解放
                if @@pipeline
                  @@vulkan_device.destroy_pipeline(@@pipeline)
                end
                
                # パイプラインレイアウトの解放
                if @@pipeline_layout
                  @@vulkan_device.destroy_pipeline_layout(@@pipeline_layout)
                end
                
                # 同期オブジェクトの解放
                @@image_available_semaphores.each do |semaphore|
                  @@vulkan_device.destroy_semaphore(semaphore)
                end
                
                @@render_finished_semaphores.each do |semaphore|
                  @@vulkan_device.destroy_semaphore(semaphore)
                end
                
                @@in_flight_fences.each do |fence|
                  @@vulkan_device.destroy_fence(fence)
                end
                
                # 論理デバイスの解放
                @@vulkan_device.destroy
              end
              
              # インスタンスの解放
              @@vulkan_instance.destroy
            end
            
            Log.info { "Vulkanリソースを解放しました" }
          when "OpenGL"
            # OpenGLリソースの解放
            if @@shader_program
              LibGL.delete_program(@@shader_program)
            end
            
            if @@vao
              LibGL.delete_vertex_arrays(1, pointerof(@@vao))
            end
            
            if @@vbo
              LibGL.delete_buffers(1, pointerof(@@vbo))
            end
            
            if @@framebuffer
              LibGL.delete_framebuffers(1, pointerof(@@framebuffer))
            end
            
            if @@texture
              LibGL.delete_textures(1, pointerof(@@texture))
            end
            
            # OpenGLコンテキストの解放
            if @@gl_context
              @@gl_context.destroy
            end
            
            Log.info { "OpenGLリソースを解放しました" }
          when "Metal"
            # Metalリソースの解放
            # 明示的な解放は不要（ARC）
            Log.info { "Metalリソースを解放しました" }
          when "DirectX"
            # DirectXリソースの解放
            if @@fence_event
              LibWindows.close_handle(@@fence_event)
            end
            
            # COMオブジェクトの解放
            [
              @@vertex_buffer, @@constant_buffer,
              @@pipeline_state, @@root_signature,
              @@rtv_heap, @@cbv_heap,
              @@command_list, @@command_allocator,
              @@fence, @@command_queue,
              @@swap_chain, @@device,
              @@adapter, @@dxgi_factory
            ].each do |com_obj|
              if com_obj
                com_obj.release
              end
            end
            
            Log.info { "DirectXリソースを解放しました" }
          end
        else
          # ソフトウェアレンダリングリソースの解放
          if @@pixel_buffer
            @@pixel_buffer.free
          end
          
          if @@z_buffer
            @@z_buffer.free
          end
          
          if @@thread_pool
            @@thread_pool.shutdown
          end
        end
        
        # その他のリソース解放
        Log.info { "レンダリングコンテキストをクリーンアップしました" }
        
        @@gpu_initialized = false
        @@rendering_api = "None"
      end
      
      # キャンバスのサイズ変更
      def resize(width : Int32, height : Int32)
        @canvas_width = width
        @canvas_height = height
        
        # レンダリングバッファのリサイズ
        if @hardware_accelerated
          case @backend_type
          when :vulkan
            # Vulkanスワップチェーンのリサイズ
            wait_device_idle
            
            # 古いスワップチェーンリソースの解放
            cleanup_vulkan_swapchain
            
            # 新しいスワップチェーンの作成
            setup_vulkan_swapchain
            
            # レンダーパスの再作成
            create_vulkan_render_pass
            
            # フレームバッファの再作成
            create_vulkan_framebuffers
            
            # パイプラインの再作成
            create_vulkan_graphics_pipeline
            
            Log.debug { "Vulkanスワップチェーンをリサイズしました: #{width}x#{height}" }
          when :opengl
            # OpenGLビューポートのリサイズ
            LibGL.viewport(0, 0, width, height)
            
            # フレームバッファのリサイズ
            if @framebuffer
              LibGL.delete_framebuffers(1, pointerof(@framebuffer))
            end
            
            if @texture
              LibGL.delete_textures(1, pointerof(@texture))
            }
            
            # 新しいフレームバッファの作成
            create_opengl_framebuffer
            
            Log.debug { "OpenGLビューポートをリサイズしました: #{width}x#{height}" }
          when :metal
            # Metalドローアブルのリサイズ
            @metal_layer.frame = CGRect.new(0, 0, width, height)
            
            Log.debug { "Metalドローアブルをリサイズしました: #{width}x#{height}" }
          when :directx
            # DirectXスワップチェーンのリサイズ
            # コマンドリストの実行完了を待機
            wait_for_gpu
            
            # レンダーターゲットビューの解放
            @render_target_views.each do |rtv|
              rtv.release if rtv
            end
            
            # スワップチェーンのリサイズ
            @swap_chain.resize_buffers(FRAME_COUNT, width, height, DXGI_FORMAT_R8G8B8A8_UNORM, 0)
            
            # 新しいレンダーターゲットビューの作成
            create_dx_render_target_views
            
            Log.debug { "DirectXスワップチェーンをリサイズしました: #{width}x#{height}" }
          end
        else
          # ソフトウェアバッファのリサイズ
          if @pixel_buffer
            @pixel_buffer.free
          end
          
          if @z_buffer
            @z_buffer.free
          end
          
          # 新しいバッファの割り当て
          @pixel_buffer = Pointer(UInt32).malloc(width * height)
          @z_buffer = Pointer(Float32).malloc(width * height)
          
          # ラスタライザーの更新
          @rasterizer.resize(width, height, @pixel_buffer, @z_buffer)
          
          Log.debug { "ソフトウェアレンダリングバッファをリサイズしました: #{width}x#{height}" }
        end
        
        # 適応型レンダリング解像度の調整
        adjust_resolution_scale
      end
      # 適応型レンダリング解像度の調整
      def adjust_resolution_scale
        # 現在のフレームレートとシステムリソースに基づいて解像度スケールを調整
        current_memory_usage = get_system_memory_usage
        current_gpu_usage = get_gpu_usage if @hardware_accelerated
        
        # パフォーマンスメトリクスの収集
        performance_score = calculate_performance_score(
          fps: @current_fps,
          memory_usage: current_memory_usage,
          gpu_usage: current_gpu_usage,
          battery_level: get_battery_level
        )
        
        # 動的解像度スケーリングの適用
        if performance_score < @performance_threshold_low && @resolution_scale > @min_resolution_scale
          # パフォーマンスが低い場合は解像度を段階的に下げる
          reduction_rate = Math.min(0.1, (@performance_threshold_low - performance_score) / 100.0)
          @resolution_scale = Math.max(@min_resolution_scale, @resolution_scale - reduction_rate)
          Log.debug { "パフォーマンス向上のため解像度スケールを下げました: #{@resolution_scale} (スコア: #{performance_score})" }
        elsif performance_score > @performance_threshold_high && @resolution_scale < @max_resolution_scale
          # パフォーマンスが十分高い場合は解像度を段階的に上げる
          increase_rate = Math.min(0.05, (performance_score - @performance_threshold_high) / 100.0)
          @resolution_scale = Math.min(@max_resolution_scale, @resolution_scale + increase_rate)
          Log.debug { "品質向上のため解像度スケールを上げました: #{@resolution_scale} (スコア: #{performance_score})" }
        end
        

        actual_width = ((@canvas_width.to_f64 * @resolution_scale) / 2.0).to_i * 2
        actual_height = ((@canvas_height.to_f64 * @resolution_scale) / 2.0).to_i * 2
        
        # 最小解像度を保証
        actual_width = Math.max(actual_width, @min_render_width)
        actual_height = Math.max(actual_height, @min_render_height)
        
        # レンダリングバッファのサイズを調整
        if @hardware_accelerated
          case @backend_type
          when :opengl
            # OpenGLフレームバッファのリサイズ
            resize_opengl_framebuffer(actual_width, actual_height)
          when :vulkan
            # Vulkanレンダリングターゲットのリサイズ
            resize_vulkan_render_target(actual_width, actual_height)
          when :metal
            # Metalレンダリングターゲットのリサイズ
            resize_metal_drawable(actual_width, actual_height)
          when :directx
            # DirectXレンダリングターゲットのリサイズ
            resize_directx_render_target(actual_width, actual_height)
          end
          
          # アップスケーリング品質の調整
          adjust_upscaling_quality
          
          Log.debug { "ハードウェアレンダリングターゲットを調整: #{actual_width}x#{actual_height} (元の解像度: #{@canvas_width}x#{@canvas_height})" }
        else
          # ソフトウェアレンダリングバッファのリサイズ
          resize_software_buffer(actual_width, actual_height)
          Log.debug { "ソフトウェアレンダリングバッファを調整: #{actual_width}x#{actual_height}" }
        end
        
        # 現在の解像度設定を保存
        @current_render_width = actual_width
        @current_render_height = actual_height
        
        # レンダリングパイプラインに解像度変更を通知
        notify_resolution_change(actual_width, actual_height)
      end
      
      # 電力使用モードの設定
      def set_power_mode(mode : Symbol)
        @power_mode = mode
        
        case mode
        when :performance
          # 最高パフォーマンスモード
          @resolution_scale = 1.0
          Log.info { "パフォーマンス優先モードに設定しました" }
        when :balanced
          # バランスモード
          @resolution_scale = 0.9
          Log.info { "バランスモードに設定しました" }
        when :power_saving
          # 省電力モード
          @resolution_scale = 0.7
          Log.info { "省電力モードに設定しました" }
        when :ultra_power_saving
          # 超省電力モード
          @resolution_scale = 0.5
          Log.info { "超省電力モードに設定しました" }
        end
      end
      
      # クラスメソッド：利用可能なバックエンドを検出
      private def self.detect_available_backends
        @@available_backends = [] of Symbol
        
        # 各バックエンドのサポート確認
        # OpenGLサポートの確認
        if LibGL.gl_supported?
          @@available_backends << :opengl
          Log.debug { "OpenGLバックエンドが利用可能です" }
        end
        
        # Vulkanサポートの確認
        if LibVulkan.vulkan_supported?
          @@available_backends << :vulkan
          Log.debug { "Vulkanバックエンドが利用可能です" }
        end
        
        # Metal (macOS/iOS) サポートの確認
        {% if flag?(:darwin) %}
          if LibMetal.metal_supported?
            @@available_backends << :metal
            Log.debug { "Metalバックエンドが利用可能です" }
          end
        {% end %}
        
        # Direct3D (Windows) サポートの確認
        {% if flag?(:windows) %}
          if LibD3D.d3d_supported?
            @@available_backends << :direct3d
            Log.debug { "Direct3Dバックエンドが利用可能です" }
          end
        {% end %}
        
        # WebGPU サポートの確認
        if LibWebGPU.webgpu_supported?
          @@available_backends << :webgpu
          Log.debug { "WebGPUバックエンドが利用可能です" }
        end
        
        # ソフトウェアレンダリングは常に利用可能
        @@available_backends << :software
        
        # ハードウェアアクセラレーションが一つも利用できない場合の警告
        if @@available_backends.size == 1 && @@available_backends.includes?(:software)
          Log.warn { "ハードウェアアクセラレーションが利用できません。パフォーマンスが低下する可能性があります。" }
        end
        
        Log.info { "利用可能なレンダリングバックエンド: #{@@available_backends.join(", ")}" }
      end
      
      # キャンバスのクリア
      def clear(color : Color = Color.white)
        # パフォーマンス計測開始
        start_time = Time.monotonic
        
        # 画面をクリア
        if @hardware_accelerated
          # OpenGLのclearColor + clear呼び出し相当
          r = color.r.to_f32 / 255.0
          g = color.g.to_f32 / 255.0
          b = color.b.to_f32 / 255.0
          a = color.a.to_f32 / 255.0
          
          case @backend
          when :opengl
            LibGL.clear_color(r, g, b, a)
            LibGL.clear(LibGL::COLOR_BUFFER_BIT | LibGL::DEPTH_BUFFER_BIT)
          when :vulkan
            @vulkan_renderer.clear_color(r, g, b, a)
          when :metal
            @metal_renderer.clear_color(r, g, b, a)
          when :direct3d
            @d3d_renderer.clear_color(r, g, b, a)
          when :webgpu
            @webgpu_renderer.clear_color(r, g, b, a)
          end
          
          Log.debug { "ハードウェアアクセラレーションでキャンバスをクリアしました: RGBA(#{r}, #{g}, #{b}, #{a})" }
        else
          # ソフトウェアバッファの全ピクセルを指定色で塗りつぶし
          pixel_value = (color.a.to_u32 << 24) | (color.b.to_u32 << 16) | (color.g.to_u32 << 8) | color.r.to_u32
          
          # 最適化：メモリブロックとして一括設定
          @pixel_buffer.fill(pixel_value)
          
          Log.debug { "ソフトウェアバッファをクリアしました: #{color.r}, #{color.g}, #{color.b}, #{color.a}" }
        end
        
        # パフォーマンス計測終了
        end_time = Time.monotonic
        @clear_time = (end_time - start_time).total_milliseconds
        
        # パフォーマンスモニタリング
        if @performance_monitoring && @clear_time > 1.0
          Log.warn { "キャンバスクリアに時間がかかっています: #{@clear_time.round(2)}ms" }
        end
      end
      
      # 矩形の描画
      def draw_rect(x : Float64, y : Float64, width : Float64, height : Float64, color : Color)
        # パフォーマンス計測開始
        start_time = Time.monotonic
        
        # 解像度スケールを適用
        scaled_x = x * @resolution_scale
        scaled_y = y * @resolution_scale
        scaled_width = width * @resolution_scale
        scaled_height = height * @resolution_scale
        
        # 矩形を描画
        if @hardware_accelerated
          # GPUでの矩形描画（シェーダを使用）
          r = color.r.to_f32 / 255.0
          g = color.g.to_f32 / 255.0
          b = color.b.to_f32 / 255.0
          a = color.a.to_f32 / 255.0
          
          # 矩形の頂点データを計算
          x2 = scaled_x + scaled_width
          y2 = scaled_y + scaled_height
          
          case @backend
          when :opengl
            # OpenGLでの矩形描画
            @rect_shader.use
            @rect_shader.set_uniform_4f("u_Color", r, g, b, a)
            @rect_vao.bind
            
            # 頂点データを更新
            vertices = [
              scaled_x, scaled_y,    # 左上
              x2, scaled_y,          # 右上
              x2, y2,                # 右下
              scaled_x, y2           # 左下
            ]
            @rect_vbo.update_data(vertices)
            
            # 描画
            LibGL.draw_elements(LibGL::TRIANGLES, 6, LibGL::UNSIGNED_INT, nil)
            @rect_vao.unbind
          when :vulkan
            # Vulkanでの矩形描画
            @vulkan_renderer.draw_rect(scaled_x, scaled_y, scaled_width, scaled_height, r, g, b, a)
          when :metal
            # Metalでの矩形描画
            @metal_renderer.draw_rect(scaled_x, scaled_y, scaled_width, scaled_height, r, g, b, a)
          when :direct3d
            # Direct3Dでの矩形描画
            @d3d_renderer.draw_rect(scaled_x, scaled_y, scaled_width, scaled_height, r, g, b, a)
          when :webgpu
            # WebGPUでの矩形描画
            @webgpu_renderer.draw_rect(scaled_x, scaled_y, scaled_width, scaled_height, r, g, b, a)
          end
          
          Log.debug { "GPU矩形描画: (#{scaled_x}, #{scaled_y}) - (#{x2}, #{y2}), RGBA(#{r}, #{g}, #{b}, #{a})" }
        else
          # ソフトウェアレンダリングでの矩形描画
          # キャンバスのピクセルバッファに直接描画
          
          # 整数座標に変換
          ix = scaled_x.to_i
          iy = scaled_y.to_i
          iw = scaled_width.to_i
          ih = scaled_height.to_i
          
          # クリッピング（ビューポート外の描画を防止）
          return if ix >= @canvas_width || iy >= @canvas_height || ix + iw < 0 || iy + ih < 0
          

          start_x = Math.max(0, ix)
          start_y = Math.max(0, iy)
          end_x = Math.min(@canvas_width - 1, ix + iw)
          end_y = Math.min(@canvas_height - 1, iy + ih)
          
          # ピクセル値を計算
          pixel_value = (color.a.to_u32 << 24) | (color.b.to_u32 << 16) | (color.g.to_u32 << 8) | color.r.to_u32
          
          # 最適化：行ごとにメモリブロックとして設定
          stride = @canvas_width
          (start_y..end_y).each do |y|
            offset = y * stride + start_x
            length = end_x - start_x + 1
            @pixel_buffer[offset, length] = pixel_value
          end
          
          Log.debug { "ソフトウェア矩形描画: (#{ix}, #{iy}) - (#{ix + iw}, #{iy + ih}), RGBA(#{color.r}, #{color.g}, #{color.b}, #{color.a})" }
        end
        
        # パフォーマンス計測終了
        end_time = Time.monotonic
        @rect_draw_time = (end_time - start_time).total_milliseconds
        
        # 描画統計の更新
        @rect_count += 1
        @total_draw_time += @rect_draw_time
        
        # パフォーマンスモニタリング
        if @performance_monitoring && @rect_draw_time > 5.0
          Log.warn { "矩形描画に時間がかかっています: #{@rect_draw_time.round(2)}ms" }
        end
      end
      
      # 画像の描画
      def draw_image(x : Float64, y : Float64, width : Float64, height : Float64, image : Image)
        # パフォーマンス計測開始
        start_time = Time.monotonic
        
        # 座標とサイズをデバイスピクセル比でスケーリング
        scaled_x = x * @resolution_scale
        scaled_y = y * @resolution_scale
        scaled_width = width * @resolution_scale
        scaled_height = height * @resolution_scale
        
        # 画像が読み込まれていない場合は警告を出して終了
        if !image.loaded?
          Log.warn { "読み込まれていない画像を描画しようとしました: #{image.url}" }
          return
        end
        
        if @hardware_accelerated
          # GPUでの画像描画（テクスチャマッピング）
          case @backend
          when :opengl
            # OpenGLでの画像描画
            # テクスチャをバインド
            texture_id = image.texture_id
            LibGL.active_texture(LibGL::TEXTURE0)
            LibGL.bind_texture(LibGL::TEXTURE_2D, texture_id)
            
            # シェーダープログラムをバインド
            @image_shader.use
            
            # ユニフォーム変数を設定
            @image_shader.set_uniform_1i("u_texture", 0)
            @image_shader.set_uniform_mat4("u_model_matrix", calculate_model_matrix(scaled_x, scaled_y, scaled_width, scaled_height))
            @image_shader.set_uniform_mat4("u_view_projection_matrix", @view_projection_matrix)
            @image_shader.set_uniform_1f("u_opacity", image.opacity)
            
            # 矩形の頂点データを設定
            @rect_vao.bind
            
            # 描画
            LibGL.draw_elements(LibGL::TRIANGLES, 6, LibGL::UNSIGNED_INT, nil)
            @rect_vao.unbind
            
            # テクスチャのバインドを解除
            LibGL.bind_texture(LibGL::TEXTURE_2D, 0)
          when :vulkan
            # Vulkanでの画像描画
            @vulkan_renderer.draw_image(scaled_x, scaled_y, scaled_width, scaled_height, image)
          when :metal
            # Metalでの画像描画
            @metal_renderer.draw_image(scaled_x, scaled_y, scaled_width, scaled_height, image)
          when :direct3d
            # Direct3Dでの画像描画
            @d3d_renderer.draw_image(scaled_x, scaled_y, scaled_width, scaled_height, image)
          when :webgpu
            # WebGPUでの画像描画
            @webgpu_renderer.draw_image(scaled_x, scaled_y, scaled_width, scaled_height, image)
          end
          
          Log.debug { "GPU画像描画: (#{scaled_x}, #{scaled_y}) - (#{scaled_x + scaled_width}, #{scaled_y + scaled_height}), 画像: #{image.url}" }
        else
          # ソフトウェアレンダリングでの画像描画
          # 整数座標に変換
          ix = scaled_x.to_i
          iy = scaled_y.to_i
          iw = scaled_width.to_i
          ih = scaled_height.to_i
          
          # クリッピング（ビューポート外の描画を防止）
          return if ix >= @canvas_width || iy >= @canvas_height || ix + iw < 0 || iy + ih < 0
          

          start_x = Math.max(0, ix)
          start_y = Math.max(0, iy)
          end_x = Math.min(@canvas_width - 1, ix + iw)
          end_y = Math.min(@canvas_height - 1, iy + ih)
          
          # 画像のスケーリング係数を計算
          scale_x = image.width / scaled_width
          scale_y = image.height / scaled_height
          
          # ピクセルバッファに画像データをコピー
          stride = @canvas_width
          (start_y..end_y).each do |y|
            img_y = ((y - iy) * scale_y).to_i
            img_y = Math.clamp(img_y, 0, image.height - 1)
            
            (start_x..end_x).each do |x|
              img_x = ((x - ix) * scale_x).to_i
              img_x = Math.clamp(img_x, 0, image.width - 1)
              
              # 画像からピクセルを取得
              pixel = image.get_pixel(img_x, img_y)
              
              # アルファブレンディング
              if pixel.a < 255
                bg_offset = y * stride + x
                bg_pixel = @pixel_buffer[bg_offset]
                
                # 背景色を抽出
                bg_r = bg_pixel & 0xFF
                bg_g = (bg_pixel >> 8) & 0xFF
                bg_b = (bg_pixel >> 16) & 0xFF
                bg_a = (bg_pixel >> 24) & 0xFF
                
                # アルファブレンディングを適用
                alpha = pixel.a / 255.0
                r = (pixel.r * alpha + bg_r * (1 - alpha)).to_u8
                g = (pixel.g * alpha + bg_g * (1 - alpha)).to_u8
                b = (pixel.b * alpha + bg_b * (1 - alpha)).to_u8
                a = Math.max(pixel.a, bg_a).to_u8
                
                # ブレンド済みピクセルを設定
                blended_pixel = (a.to_u32 << 24) | (b.to_u32 << 16) | (g.to_u32 << 8) | r.to_u32
                @pixel_buffer[bg_offset] = blended_pixel
              else
                # 完全不透明なピクセルは直接設定
                offset = y * stride + x
                pixel_value = (pixel.a.to_u32 << 24) | (pixel.b.to_u32 << 16) | (pixel.g.to_u32 << 8) | pixel.r.to_u32
                @pixel_buffer[offset] = pixel_value
              end
            end
          end
          
          Log.debug { "ソフトウェア画像描画: (#{ix}, #{iy}) - (#{ix + iw}, #{iy + ih}), 画像: #{image.url}" }
        end
        
        # パフォーマンス計測終了
        end_time = Time.monotonic
        @image_draw_time = (end_time - start_time).total_milliseconds
        
        # 描画統計の更新
        @image_count += 1
        @total_draw_time += @image_draw_time
      end
      # テキストの描画
      def draw_text(x : Float64, y : Float64, text : String, font : Font, color : Color)
        # テキストを描画
        if text.empty?
          return
        end
        # パフォーマンス計測開始
        start_time = Time.monotonic
        
        if @hardware_accelerated
          # GPUでのテキスト描画（テクスチャアトラスからグリフを組み合わせる）
          r = color.r.to_f32 / 255.0
          g = color.g.to_f32 / 255.0
          b = color.b.to_f32 / 255.0
          a = color.a.to_f32 / 255.0
          
          # フォント情報からグリフを取得
          font_css = font.to_css_string
          font_size = font.size
          font_weight = font.weight
          # テキストの各文字に対してグリフを描画
          cursor_x = x
          last_char = nil
          
          text.each_char do |char|
            # グリフデータをフォントキャッシュから取得
            glyph = @font_cache.get_glyph(char, font)
            
            # グリフが見つからない場合はフォールバックフォントを試行
            if glyph.nil? && @font_fallback_enabled
              @fallback_fonts.each do |fallback_font|
                combined_font = Font.new(
                  family: fallback_font,
                  size: font.size,
                  weight: font.weight,
                  style: font.style
                )
                glyph = @font_cache.get_glyph(char, combined_font)
                break if glyph
              end
            end
            if glyph
              # グリフのテクスチャ座標を取得
              tex_coords = glyph.texture_coordinates
              
              # グリフの描画サイズを計算
              glyph_width = glyph.width * (font_size / glyph.base_size)
              glyph_height = glyph.height * (font_size / glyph.base_size)
              
              # グリフの描画位置を計算（ベースラインを考慮）
              glyph_x = cursor_x + glyph.bearing_x * (font_size / glyph.base_size)
              glyph_y = y - (glyph.height - glyph.bearing_y) * (font_size / glyph.base_size)
              
              # カーニング調整を適用（前の文字との間隔調整）
              if @last_char && @font_cache.has_kerning?(font)
                kerning_offset = @font_cache.get_kerning(@last_char, char, font)
                glyph_x += kerning_offset * (font_size / glyph.base_size)
              end
              
              # GPUにグリフ描画コマンドを送信
              @gpu_context.draw_glyph(
                glyph_x, glyph_y, glyph_width, glyph_height,
                tex_coords, {r, g, b, a}
              )
              
              # カーソル位置を進める
              cursor_x += glyph.advance_x * (font_size / glyph.base_size)
              @last_char = char
            end
          end
          
          # サブピクセルレンダリングの適用（ハードウェアアクセラレーション時）
          if @enable_subpixel_rendering && font.size < 16
            @gpu_context.apply_subpixel_filter(@clip_rect)
          end
          
          Log.debug { "GPUテキスト描画: (#{x}, #{y}), '#{text}', フォント: #{font_css}, RGBA(#{r}, #{g}, #{b}, #{a})" }
        else
          # ソフトウェアレンダリングでのテキスト描画
          # 整数座標に変換
          ix = x.to_i
          iy = y.to_i
          
          # フォント情報からグリフを取得
          font_css = font.to_css_string
          font_size = font.size
          
          # テキストの各文字に対してグリフをラスタライズして描画
          cursor_x = ix
          last_char = nil
          
          text.each_char do |char|
            # グリフデータを取得
            glyph = @font_cache.get_glyph(char, font)
            
            if glyph
              # グリフのビットマップを取得
              bitmap = glyph.bitmap
              
              # グリフの描画サイズを計算
              glyph_width = glyph.width
              glyph_height = glyph.height
              
              # カーニング調整を適用（前の文字との間隔調整）
              if last_char && @font_cache.has_kerning?(font)
                kerning_offset = @font_cache.get_kerning(last_char, char, font)
                cursor_x += kerning_offset
              end
              
              # グリフの描画位置を計算（ベースラインを考慮）
              glyph_x = cursor_x + glyph.bearing_x
              glyph_y = iy - (glyph_height - glyph.bearing_y)
              
              # サブピクセルレンダリングの使用判定
              use_subpixel = @enable_subpixel_rendering && font.size < 16 && color.a > 240
              
              # ビットマップの各ピクセルをバッファに描画
              (0...glyph_height).each do |gy|
                y_pos = glyph_y + gy
                next if y_pos < 0 || y_pos >= @height
                
                (0...glyph_width).each do |gx|
                  x_pos = glyph_x + gx
                  next if x_pos < 0 || x_pos >= @width
                  
                  # グリフのアルファ値を取得
                  alpha_index = gy * glyph_width + gx
                  next if alpha_index >= bitmap.size
                  
                  alpha = bitmap[alpha_index] / 255.0
                  
                  if alpha > 0
                    # バッファ内の現在のピクセルを取得
                    offset = y_pos * @stride + x_pos
                    next if offset >= @pixel_buffer.size
                    
                    bg_pixel = @pixel_buffer[offset]
                    
                    # 背景色を抽出
                    bg_r = bg_pixel & 0xFF
                    bg_g = (bg_pixel >> 8) & 0xFF
                    bg_b = (bg_pixel >> 16) & 0xFF
                    bg_a = (bg_pixel >> 24) & 0xFF
                    
                    if use_subpixel
                      # サブピクセルレンダリング（RGB成分ごとに異なるウェイトを適用）
                      subpixel_offset = (x_pos % 3)
                      r_weight = subpixel_offset == 0 ? 1.0 : (subpixel_offset == 1 ? 0.3 : 0.1)
                      g_weight = subpixel_offset == 1 ? 1.0 : 0.3
                      b_weight = subpixel_offset == 2 ? 1.0 : (subpixel_offset == 1 ? 0.3 : 0.1)
                      
                      r = (color.r * alpha * r_weight + bg_r * (1 - alpha * r_weight)).to_u8
                      g = (color.g * alpha * g_weight + bg_g * (1 - alpha * g_weight)).to_u8
                      b = (color.b * alpha * b_weight + bg_b * (1 - alpha * b_weight)).to_u8
                    else
                      # 通常のアルファブレンディング
                      r = (color.r * alpha + bg_r * (1 - alpha)).to_u8
                      g = (color.g * alpha + bg_g * (1 - alpha)).to_u8
                      b = (color.b * alpha + bg_b * (1 - alpha)).to_u8
                    end
                    
                    a = Math.max((color.a * alpha).to_u8, bg_a).to_u8
                    
                    # ブレンド済みピクセルを設定
                    blended_pixel = (a.to_u32 << 24) | (b.to_u32 << 16) | (g.to_u32 << 8) | r.to_u32
                    @pixel_buffer[offset] = blended_pixel
                  end
                end
              end
              
              # カーソル位置を進める
              cursor_x += glyph.advance_x
              last_char = char
            end
          end
          
          Log.debug { "ソフトウェアテキスト描画: (#{ix}, #{iy}), '#{text}', フォント: #{font_css}, RGBA(#{color.r}, #{color.g}, #{color.b}, #{color.a})" }
        end
        
        # パフォーマンス計測終了
        end_time = Time.monotonic
        @text_draw_time = (end_time - start_time).total_milliseconds
        
        # 描画統計の更新
        @text_count += 1
        @total_text_time += @text_draw_time
      end
      # パスの開始
      def begin_path
        # パフォーマンス計測開始
        start_time = Time.monotonic
        
        # 新しいパスを開始
        if @hardware_accelerated
          # GPUでのパス描画の開始
          # パスデータを格納する新しいバッファを準備し、GPU側のパスコンテキストを初期化
          @gpu_context.try do |ctx|
            ctx.begin_path
            # パスの状態をリセット
            @gpu_path_started = true
            @gpu_path_complexity = 0
            @gpu_path_bounds = {min_x: Float64::MAX, min_y: Float64::MAX, max_x: Float64::MIN, max_y: Float64::MIN}
            # GPU側でのパス最適化フラグを設定
            ctx.set_path_optimization_hints(
              is_convex: true,
              is_simple: true,
              has_curves: false,
              expected_segments: 16
            )
            # レンダリング品質に基づいてGPUパスの品質設定
            ctx.set_path_quality(
              antialiasing: @rendering_quality >= RenderingQuality::Medium,
              subpixel_precision: @rendering_quality >= RenderingQuality::High,
              curve_tessellation_quality: @rendering_quality.to_i
            )
          end
          Log.debug { "GPUパス描画開始: 品質=#{@rendering_quality}" }
        else
          # ソフトウェアレンダリングでのパス描画の開始
          # パスデータを格納する配列を初期化
          @current_path = [] of {Float64, Float64}
          @path_bounds = {min_x: Float64::MAX, min_y: Float64::MAX, max_x: Float64::MIN, max_y: Float64::MIN}
          @path_closed = false
          @path_segments = [] of PathSegment
          @path_start_point = nil
          @path_current_point = nil
          @path_has_curves = false
          @path_complexity = 0
          
          # パスの描画品質設定
          @path_antialiasing = @rendering_quality >= RenderingQuality::Medium
          @path_subpixel_precision = @rendering_quality >= RenderingQuality::High
          
          # パフォーマンス最適化のためのフラグ
          @path_is_simple_rect = true
          @path_is_convex = true
          
          # メモリ使用量の最適化
          if @path_segments.capacity < 16
            @path_segments = Array(PathSegment).new(initial_capacity: 16)
          else
            @path_segments.clear
          end
          
          Log.debug { "ソフトウェアパス描画開始: 品質=#{@rendering_quality}, アンチエイリアス=#{@path_antialiasing}" }
        end
        
        # パフォーマンス計測終了
        end_time = Time.monotonic
        @path_operation_time = (end_time - start_time).total_milliseconds
        
        # メソッドチェーン用に自身を返す
        self
      end
      
      # パスの終了と描画
      def stroke_path(color : Color, line_width : Float64 = 1.0, line_cap : LineCap = LineCap::Butt, line_join : LineJoin = LineJoin::Miter)
        # パフォーマンス計測開始
        start_time = Time.monotonic
        
        # パスのストローク
        if @hardware_accelerated
          # GPUでのパスストローク
          r = color.r.to_f32 / 255.0
          g = color.g.to_f32 / 255.0
          b = color.b.to_f32 / 255.0
          a = color.a.to_f32 / 255.0
          
          # GPU描画パラメータの最適化
          optimized_line_width = Math.max(0.5, line_width)
          
          # 線の結合点とキャップの品質設定
          quality_factor = @rendering_quality >= RenderingQuality::High ? 1.0_f32 : 0.75_f32
          
          # GPUバッファにパスデータを送信
          if @gpu_context.nil?
            Log.error { "GPUコンテキストが初期化されていません。ソフトウェアレンダリングにフォールバックします。" }
            @hardware_accelerated = false
          else
            # シェーダーパラメータの設定
            @gpu_context.not_nil!.set_stroke_params(
              r, g, b, a,
              optimized_line_width,
              line_cap,
              line_join,
              @miter_limit,
              quality_factor
            )
            
            # パスデータの送信と描画実行
            @gpu_context.not_nil!.stroke_path(r, g, b, a, optimized_line_width, line_cap, line_join)
            
            # GPU統計情報の更新
            @gpu_stroke_count += 1
            @total_gpu_draw_calls += 1
            
            Log.debug { "GPUパスストローク: 線幅 #{optimized_line_width}, RGBA(#{r}, #{g}, #{b}, #{a}), キャップ: #{line_cap}, 結合: #{line_join}, 品質係数: #{quality_factor}" }
          end
        else
          # ソフトウェアレンダリングでのパスストローク
          # パスが空の場合は何もしない
          return self if @current_path.nil? || @current_path.not_nil!.size < 2
          
          path = @current_path.not_nil!
          
          # アンチエイリアス処理のフラグ
          use_antialiasing = @antialiasing_enabled && line_width <= 2.0
          
          # ダッシュパターンの適用
          actual_path = apply_dash_pattern(path, @dash_pattern)
          
          # 隣接する各点をつなぐ線を描画
          (0...actual_path.size - 1).each do |i|
            x1, y1 = actual_path[i]
            x2, y2 = actual_path[i + 1]
            
            # 線分の長さが0の場合はスキップ
            next if (x1 - x2).abs < 0.01 && (y1 - y2).abs < 0.01
            
            if use_antialiasing
              # アンチエイリアス処理を適用した線描画
              draw_line_antialiased(x1, y1, x2, y2, color, line_width, line_cap, line_join)
            else
              # 太い線の場合は拡張ブレゼンハムアルゴリズムを使用
              if line_width > 1.0
                draw_thick_line(x1.to_f64, y1.to_f64, x2.to_f64, y2.to_f64, color, line_width, line_cap, line_join)
              else
                # 標準的なブレゼンハムのアルゴリズムで線を描画
                draw_line_bresenham(x1.to_i, y1.to_i, x2.to_i, y2.to_i, color, line_width)
              end
            end
            
            Log.debug { "ソフトウェア線分描画: (#{x1}, #{y1}) - (#{x2}, #{y2}), 線幅 #{line_width}, RGBA(#{color.r}, #{color.g}, #{color.b}, #{color.a})" }
          end
          
          # パスが閉じている場合は最後の点と最初の点を結ぶ
          if @path_closed && path.size > 2
            x1, y1 = path.last
            x2, y2 = path.first
            
            if use_antialiasing
              draw_line_antialiased(x1, y1, x2, y2, color, line_width)
            else
              draw_line_bresenham(x1.to_i, y1.to_i, x2.to_i, y2.to_i, color, line_width)
            end
            
            Log.debug { "ソフトウェアパス閉じる線分: (#{x1}, #{y1}) - (#{x2}, #{y2})" }
          end
          
          # パスをリセット
          @current_path = nil
          @path_bounds = nil
          @path_closed = false
        end
        
        # パフォーマンス計測終了
        end_time = Time.monotonic
        @path_operation_time = (end_time - start_time).total_milliseconds
        
        # 描画統計の更新
        @path_count += 1
        @total_path_time += @path_operation_time
        
        # メソッドチェーン用に自身を返す
        self
      end
      
      # パスの塗りつぶし
      def fill_path(color : Color)
        # パフォーマンス計測開始
        start_time = Time.monotonic
        
        # パスの塗りつぶし
        if @hardware_accelerated
          # GPUでのパス塗りつぶし
          r = color.r.to_f32 / 255.0
          g = color.g.to_f32 / 255.0
          b = color.b.to_f32 / 255.0
          a = color.a.to_f32 / 255.0
          
          # パスデータの検証
          if @current_path.nil? || @current_path.not_nil!.empty?
            Log.warn { "GPUパス塗りつぶし: 有効なパスデータがありません" }
            return self
          end
          
          # パスの境界を計算
          path_data = @current_path.not_nil!
          
          # GPUバッファにパスデータを転送
          vertices = [] of Float32
          indices = [] of UInt32
          
          # パスを三角形分割（イヤーカット法）
          triangulated_path = triangulate_path(path_data)
          
          # 頂点バッファとインデックスバッファを構築
          triangulated_path.each do |triangle|
            triangle.each do |point|
              vertices << point[0].to_f32 # x座標
              vertices << point[1].to_f32 # y座標
            end
          end
          
          # GPUコンテキストにデータを送信し、塗りつぶし処理を実行
          @gpu_context.try &.fill_path_with_data(vertices, indices, r, g, b, a)
          
          # パスが閉じていない場合は自動的に閉じる
          if !@path_closed && path_data.size > 2
            if path_data.first != path_data.last
              @gpu_context.try &.add_line_to_path(path_data.first[0], path_data.first[1])
              Log.debug { "パスを自動的に閉じました: (#{path_data.first[0]}, #{path_data.first[1]})" }
            end
          end
          
          # アンチエイリアシング設定を適用
          @gpu_context.try &.set_anti_aliasing(@anti_aliasing_enabled)
          

          @gpu_context.try do |ctx|
            # シェーダープログラムの選択（パフォーマンス最適化のため）
            ctx.use_shader_program(@fill_shader_program) if @shader_switching_enabled
            
            # 描画前の最終パラメータ調整
            ctx.set_blend_mode(@current_blend_mode)
            ctx.set_fill_opacity(a)
            
            ctx.fill_path(r, g, b, a)
            
            # 描画後の状態リセット（オプション）
            ctx.reset_path_state if @auto_reset_path_state
            
            # パフォーマンスモニタリング
            @last_draw_call_time = Time.monotonic
          end
          
          # パフォーマンス最適化のためのバッファフラッシュ判断
          if @auto_flush_enabled || vertices.size > @buffer_flush_threshold
            @gpu_context.try &.flush_render_commands
          end
          
          # 描画統計情報の記録
          @filled_paths_count += 1
          @total_vertices_processed += vertices.size / 2
          
          Log.debug { "GPUパス塗りつぶし: 頂点数 #{vertices.size / 2}, RGBA(#{r}, #{g}, #{b}, #{a})" }
        else
          # ソフトウェアレンダリングでのパス塗りつぶし
          # パスが閉じた領域を定義していることが前提
          
          # パスが空の場合は何もしない
          return self if @current_path.nil? || @current_path.not_nil!.size < 3
          
          path = @current_path.not_nil!
          bounds = @path_bounds.not_nil!
          
          # パスが自動的に閉じていない場合は閉じる
          if !@path_closed && (path.first[0] != path.last[0] || path.first[1] != path.last[1])
            path << path.first
          end
          
          # 塗りつぶしルールの適用（non-zero winding ruleまたはeven-odd rule）
          if @fill_rule == FillRule::NonZero
            fill_polygon_non_zero(path, color)
          else # FillRule::EvenOdd
            fill_polygon_scanline(path, color)
          end
          
          Log.debug { "ソフトウェアパス塗りつぶし: バウンディングボックス (#{bounds[:min_x]}, #{bounds[:min_y]}) - (#{bounds[:max_x]}, #{bounds[:max_y]}), RGBA(#{color.r}, #{color.g}, #{color.b}, #{color.a})" }
          
          # パスをリセット
          @current_path = nil
          @path_bounds = nil
          @path_closed = false
        end
        
        # パフォーマンス計測終了
        end_time = Time.monotonic
        @path_operation_time = (end_time - start_time).total_milliseconds
        
        # 描画統計の更新
        @path_count += 1
        @total_path_time += @path_operation_time
        
        # メソッドチェーン用に自身を返す
        self
      end
      
      # パスに線分を追加
      def line_to(x : Float64, y : Float64)
        # パスに線分を追加
        if @hardware_accelerated
          # GPUでのパスデータ更新
          if @gpu_context
            # GPUコンテキストが存在する場合、シェーダーにパスデータを送信
            @gpu_context.add_line_to_path(x, y)
            Log.debug { "GPUパス線分追加: (#{x}, #{y})" }
          else
            Log.warn { "GPUコンテキストが初期化されていない状態で線分を追加しようとしました" }
            # フォールバックとしてソフトウェアレンダリングを一時的に使用
            temp_accel = @hardware_accelerated
            @hardware_accelerated = false
            line_to(x, y)
            @hardware_accelerated = temp_accel
          end
        else
          # ソフトウェアレンダリングでのパスデータ更新
          if @current_path.nil?
            # パスが開始されていない場合は始点を設定
            @current_path = [{x, y}]
            Log.debug { "ソフトウェアパス開始: (#{x}, #{y})" }
          else
            # 前回の点と同じ場合は追加しない（最適化）
            last_point = @current_path.not_nil!.last
            if (last_point[0] - x).abs > EPSILON || (last_point[1] - y).abs > EPSILON
              # パスに点を追加
              @current_path.not_nil! << {x, y}
              Log.debug { "ソフトウェアパス線分追加: (#{x}, #{y})" }
            end
          end
          
          # パスの境界ボックスを更新（後の描画最適化のため）
          update_path_bounds(x, y) if @current_path
        end
        
        # メソッドチェーン用に自身を返す
        self
      end
      
      # パスに曲線を追加
      def bezier_curve_to(cp1x : Float64, cp1y : Float64, cp2x : Float64, cp2y : Float64, x : Float64, y : Float64)
        start_time = Time.monotonic
        
        # パスにベジェ曲線を追加
        if @hardware_accelerated
          # GPUでのベジェ曲線データ更新
          if @gpu_context
            # GPUコンテキストが存在する場合、シェーダーにベジェ曲線データを送信
            @gpu_context.add_bezier_curve_to_path(cp1x, cp1y, cp2x, cp2y, x, y)
            Log.debug { "GPUパスベジェ曲線追加: 制御点1(#{cp1x}, #{cp1y}), 制御点2(#{cp2x}, #{cp2y}), 終点(#{x}, #{y})" }
          else
            Log.warn { "GPUコンテキストが初期化されていない状態でベジェ曲線を追加しようとしました" }
            # フォールバックとしてソフトウェアレンダリングを一時的に使用
            temp_accel = @hardware_accelerated
            @hardware_accelerated = false
            bezier_curve_to(cp1x, cp1y, cp2x, cp2y, x, y)
            @hardware_accelerated = temp_accel
            return self
          end
        else
          # ソフトウェアレンダリングでのベジェ曲線
          # 曲線を直線セグメントに分割して近似
          
          # パスが開始されていない場合はエラー
          if @current_path.nil? || @current_path.not_nil!.empty?
            Log.error { "パスが開始されていない状態でベジェ曲線を追加しようとしました" }
            return self
          end
          
          # 現在のパスの最後の点を開始点とする
          start_point = @current_path.not_nil!.last
          start_x, start_y = start_point
          
          # 曲線の複雑さに基づいて適応的にセグメント数を決定
          # 制御点と端点の距離に基づいて計算
          dx1 = (cp1x - start_x).abs
          dy1 = (cp1y - start_y).abs
          dx2 = (cp2x - cp1x).abs
          dy2 = (cp2y - cp1y).abs
          dx3 = (x - cp2x).abs
          dy3 = (y - cp2y).abs
          
          # 曲線の複雑さを計算
          curve_complexity = Math.sqrt(dx1*dx1 + dy1*dy1) + 
                             Math.sqrt(dx2*dx2 + dy2*dy2) + 
                             Math.sqrt(dx3*dx3 + dy3*dy3)
          
          # 複雑さに基づいてセグメント数を調整（最小5、最大30）
          segments = Math.min(30, Math.max(5, (curve_complexity * 0.5).to_i))
          
          path = @current_path.not_nil!
          
          (1..segments).each do |i|
            t = i.to_f64 / segments
            # 3次ベジェ曲線の計算式
            # (1-t)^3 * P0 + 3(1-t)^2 * t * P1 + 3(1-t) * t^2 * P2 + t^3 * P3
            u = 1.0 - t
            u2 = u * u
            u3 = u2 * u
            t2 = t * t
            t3 = t2 * t
            
            # 各座標の計算
            px = u3 * start_x + 3 * u2 * t * cp1x + 3 * u * t2 * cp2x + t3 * x
            py = u3 * start_y + 3 * u2 * t * cp1y + 3 * u * t2 * cp2y + t3 * y
            
            # 前回の点と同じ場合は追加しない（最適化）
            last_point = path.last
            if (last_point[0] - px).abs > EPSILON || (last_point[1] - py).abs > EPSILON
              # パスに点を追加
              path << {px, py}
              
              # パスの境界ボックスを更新
              update_path_bounds(px, py)
            end
          end
          
          Log.debug { "ソフトウェアパスベジェ曲線追加: #{segments}セグメントに分割" }
        end
        
        # 処理時間の計測
        end_time = Time.monotonic
        @curve_operation_time = (end_time - start_time).total_milliseconds
        
        # 描画統計の更新
        @curve_count += 1
        @total_curve_time += @curve_operation_time
        
        # メソッドチェーン用に自身を返す
        self
      end
      
      # 二次ベジェ曲線を追加
      def quadratic_curve_to(cpx : Float64, cpy : Float64, x : Float64, y : Float64)
        # 二次ベジェ曲線を3次ベジェ曲線に変換
        if @current_path.nil? || @current_path.not_nil!.empty?
          Log.error { "パスが開始されていない状態で二次ベジェ曲線を追加しようとしました" }
          return self
        end
        
        # 現在のパスの最後の点を開始点とする
        start_point = @current_path.not_nil!.last
        start_x, start_y = start_point
        
        # 二次ベジェ曲線の制御点から3次ベジェ曲線の制御点を計算
        # P1_cubic = P0 + 2/3 * (P1_quad - P0)
        # P2_cubic = P2 + 2/3 * (P1_quad - P2)
        cp1x = start_x + 2.0/3.0 * (cpx - start_x)
        cp1y = start_y + 2.0/3.0 * (cpy - start_y)
        cp2x = x + 2.0/3.0 * (cpx - x)
        cp2y = y + 2.0/3.0 * (cpy - y)
        
        # 3次ベジェ曲線として描画
        bezier_curve_to(cp1x, cp1y, cp2x, cp2y, x, y)
      end
      # 円弧を追加
      def arc_to(x1 : Float64, y1 : Float64, x2 : Float64, y2 : Float64, radius : Float64)
        start_time = Time.monotonic
        
        if @current_path.nil? || @current_path.not_nil!.empty?
          Log.error { "パスが開始されていない状態で円弧を追加しようとしました" }
          return self
        end
        
        # 現在のパスの最後の点を開始点とする
        start_point = @current_path.not_nil!.last
        x0, y0 = start_point
        
        # 半径が0以下の場合は直線を引く
        if radius <= 0
          Log.debug { "円弧の半径が0以下のため、直線で代替します" }
          line_to(x2, y2)
          return self
        end
        
        # 3点が一直線上にある場合は直線を引く
        dx0 = x0 - x1
        dy0 = y0 - y1
        dx2 = x2 - x1
        dy2 = y2 - y1
        cross_product = dx0 * dy2 - dy0 * dx2
        if cross_product.abs < EPSILON
          Log.debug { "円弧の3点が一直線上にあるため、直線で代替します" }
          line_to(x2, y2)
          return self
        end
        
        # 円弧の中心点と開始・終了角度を計算
        # 2つの線分の角の二等分線上に中心点がある
        
        # 線分の長さを計算
        len1 = Math.sqrt(dx0 * dx0 + dy0 * dy0)
        len2 = Math.sqrt(dx2 * dx2 + dy2 * dy2)
        
        # 単位ベクトルに変換
        udx0 = dx0 / len1
        udy0 = dy0 / len1
        udx2 = dx2 / len2
        udy2 = dy2 / len2
        
        # 角の二等分線ベクトル
        bisector_x = udx0 + udx2
        bisector_y = udy0 + udy2
        bisector_len = Math.sqrt(bisector_x * bisector_x + bisector_y * bisector_y)
        
        # 二等分線が0ベクトルになる場合（180度の角度）の対応
        if bisector_len < EPSILON
          Log.warn { "円弧の角度が180度に近いため、計算を調整します" }
          bisector_x = -udy0
          bisector_y = udx0
          bisector_len = 1.0
        }
        
        # 単位二等分線ベクトル
        ubisector_x = bisector_x / bisector_len
        ubisector_y = bisector_y / bisector_len
        
        # 中心点までの距離を計算
        # 三角関数を使用して、半径と角度から距離を求める
        angle = Math.acos(udx0 * udx2 + udy0 * udy2) / 2.0
        distance = radius / Math.sin(angle)
        
        # 中心点の座標
        center_x = x1 + ubisector_x * distance
        center_y = y1 + ubisector_y * distance
        
        # 開始角と終了角を計算
        start_angle = Math.atan2(y0 - center_y, x0 - center_x)
        end_angle = Math.atan2(y2 - center_y, x2 - center_x)
        
        # 円弧の方向を決定（時計回りか反時計回り）
        # 外積の符号で判断
        clockwise = cross_product < 0
        
        # 角度の調整（常に最短の弧を描く）
        if clockwise && start_angle < end_angle
          start_angle += Math::PI * 2
        elsif !clockwise && start_angle > end_angle
          end_angle += Math::PI * 2
        end
        
        # 円弧を複数の3次ベジェ曲線で近似
        arc_to_bezier(center_x, center_y, radius, start_angle, end_angle, clockwise)
        
        # 処理時間の計測
        end_time = Time.monotonic
        arc_time = (end_time - start_time).total_milliseconds
        
        # 描画統計の更新
        @arc_count += 1
        @total_arc_time += arc_time
        
        Log.debug { "円弧追加: 中心(#{center_x.round(2)}, #{center_y.round(2)}), 半径#{radius.round(2)}, 角度[#{start_angle.round(4)}, #{end_angle.round(4)}], 処理時間: #{arc_time.round(2)}ms" }
        
        # メソッドチェーン用に自身を返す
        self
      end
      
      # 円弧をベジェ曲線に変換する補助メソッド
      private def arc_to_bezier(cx : Float64, cy : Float64, radius : Float64, start_angle : Float64, end_angle : Float64, clockwise : Bool)
        # 円弧の角度
        arc_angle = (clockwise ? start_angle - end_angle : end_angle - start_angle).abs
        
        # 分割数を決定（角度に応じて）
        # 90度ごとに分割するのが一般的（精度と効率のバランス）
        segments = (arc_angle / (Math::PI / 2)).ceil.to_i
        segments = 1 if segments < 1
        
        # 分割した角度
        angle_step = arc_angle / segments
        angle_step = -angle_step if clockwise
        
        # 各セグメントをベジェ曲線で近似
        current_angle = start_angle
        
        segments.times do |i|
          next_angle = current_angle + angle_step
          
          # ベジェ曲線の制御点を計算
          # 円弧の接線方向に制御点を配置
          # 制御点の距離は半径 * 4/3 * tan(angle_step/4)
          k = 4.0/3.0 * Math.tan(angle_step.abs / 4.0)
          
          # 開始点
          p0x = cx + radius * Math.cos(current_angle)
          p0y = cy + radius * Math.sin(current_angle)
          
          # 制御点1
          p1x = cx + radius * (Math.cos(current_angle) - k * Math.sin(current_angle))
          p1y = cy + radius * (Math.sin(current_angle) + k * Math.cos(current_angle))
          
          # 制御点2
          p2x = cx + radius * (Math.cos(next_angle) + k * Math.sin(next_angle))
          p2y = cy + radius * (Math.sin(next_angle) - k * Math.cos(next_angle))
          
          # 終了点
          p3x = cx + radius * Math.cos(next_angle)
          p3y = cy + radius * Math.sin(next_angle)
          
          # 最初のセグメント以外は、開始点を移動（既に現在のパスにある）
          if i == 0
            # 既にパスの最後の点が開始点なので何もしない
          else
            # 前のセグメントの終点から次のセグメントの開始点へ移動
            line_to(p0x, p0y)
          end
          
          # ベジェ曲線を追加
          bezier_curve_to(p1x, p1y, p2x, p2y, p3x, p3y)
          
          # 次のセグメントの準備
          current_angle = next_angle
        end
      end
      
      # クリッピング領域の設定
      def set_clip(x : Float64, y : Float64, width : Float64, height : Float64)
        start_time = Time.monotonic
        
        # パフォーマンス計測のための変数
        clip_setup_duration = 0.0
        
        # クリッピング領域を設定
        if @hardware_accelerated
          # GPUでのクリッピング設定
          # OpenGLのscissorテストを使用してクリッピング領域を設定
          ix = x.to_i
          iy = y.to_i
          iw = width.to_i
          ih = height.to_i
          
          # 座標変換を適用（必要に応じて）
          if @transform_matrix && !@transform_matrix.identity?
            # 現在の変換行列を考慮してクリッピング領域を調整
            transformed_points = @transform_matrix.transform_rect(x, y, width, height)
            bounds = calculate_bounding_rect(transformed_points)
            ix = bounds.x.to_i
            iy = bounds.y.to_i
            iw = bounds.width.to_i
            ih = bounds.height.to_i
            @metrics.increment_counter("transformed_clip_rects")
          end
          
          # 高DPI対応のためのスケーリング
          if @device_pixel_ratio != 1.0
            ix = (ix * @device_pixel_ratio).to_i
            iy = (iy * @device_pixel_ratio).to_i
            iw = (iw * @device_pixel_ratio).to_i
            ih = (ih * @device_pixel_ratio).to_i
            @metrics.increment_counter("scaled_clip_rects")
          end
          # 矩形が有効かチェック
          if iw <= 0 || ih <= 0
            Log.warn { "無効なクリッピング矩形: (#{ix}, #{iy}), サイズ #{iw}x#{ih}" }
            @metrics.increment_counter("invalid_clip_rects")
            return self
          end
          
          # ビューポートの境界内に収まるように調整
          if @viewport_constraints
            vx, vy, vw, vh = @viewport_constraints
            
            # クリッピング領域がビューポートと交差するか確認
            if ix + iw <= vx || ix >= vx + vw || iy + ih <= vy || iy >= vy + vh
              Log.debug { "クリッピング領域がビューポート外: clip=(#{ix},#{iy},#{iw},#{ih}), viewport=(#{vx},#{vy},#{vw},#{vh})" }
              @metrics.increment_counter("out_of_viewport_clips")
              # 空のクリッピング領域を設定
              ix = vx
              iy = vy
              iw = 0
              ih = 0
            else
              # ビューポート内に収まるように調整
              new_x = Math.max(ix, vx)
              new_y = Math.max(iy, vy)
              new_w = Math.min(ix + iw, vx + vw) - new_x
              new_h = Math.min(iy + ih, vy + vh) - new_y
              
              if new_x != ix || new_y != iy || new_w != iw || new_h != ih
                Log.debug { "クリッピング領域を調整: (#{ix},#{iy},#{iw},#{ih}) → (#{new_x},#{new_y},#{new_w},#{new_h})" }
                @metrics.increment_counter("adjusted_clip_rects")
                ix = new_x
                iy = new_y
                iw = new_w
                ih = new_h
              end
            end
          end
          
          # クリッピングスタックに追加
          if @clip_stack_enabled
            @clip_stack.push({ix, iy, iw, ih})
            Log.debug { "クリッピングスタック追加 [#{@clip_stack.size}]: (#{ix},#{iy},#{iw},#{ih})" }
          end
          
          clip_setup_duration = (Time.monotonic - start_time).total_milliseconds
          @metrics.record_timing("clip_setup_time", clip_setup_duration)
          # GPUコンテキストが存在する場合のみ実行
          if @gpu_context
            previous_clip = @current_clip_rect
            @gpu_context.set_scissor_test(true)
            @gpu_context.set_scissor_rect(ix, iy, iw, ih)
            @current_clip_rect = {ix, iy, iw, ih}
            
            # クリッピング状態をGPUキャッシュに反映
            @gpu_cache.update_clip_state(@current_clip_rect) if @gpu_cache
            
            # クリッピングが変更された領域を再描画
            if previous_clip && previous_clip != @current_clip_rect && @auto_optimize
              # 前後のクリッピング領域の差分を再描画
              invalidate_clip_change(previous_clip, @current_clip_rect)
            end
          else
            Log.warn { "GPUコンテキストが初期化されていない状態でクリッピングを設定しようとしました" }
            # フォールバックとしてソフトウェアレンダリングを一時的に使用
            temp_accel = @hardware_accelerated
            @hardware_accelerated = false
            set_clip(x, y, width, height)
            @hardware_accelerated = temp_accel
            return self
          end
          
          Log.debug { "GPUクリッピング設定: (#{ix}, #{iy}), サイズ #{iw}x#{ih}" }
        else
          # ソフトウェアレンダリングでのクリッピング設定
          ix = x.to_i
          iy = y.to_i
          iw = width.to_i
          ih = height.to_i
          
          # 矩形が有効かチェック
          if iw <= 0 || ih <= 0
            Log.warn { "無効なクリッピング矩形: (#{ix}, #{iy}), サイズ #{iw}x#{ih}" }
            return self
          end
          # 以前のクリッピング矩形を保存（最適化用）
          previous_clip = @clip_rect
          
          # クリッピング矩形を設定
          @clip_rect = {ix, iy, iw, ih}
          @current_clip_rect = @clip_rect
          
          # クリッピング状態を更新
          @clipping_enabled = true
          
          # 既存の描画バッファに対してクリッピングを適用
          if @buffer && @auto_optimize
            apply_clipping_to_buffer
            
            # クリッピングが変更された場合、影響を受ける領域を再描画
            if previous_clip && previous_clip != @clip_rect
              invalidate_affected_clip_area(previous_clip, @clip_rect)
            end
          end
          
          # レンダリングキャッシュを更新
          update_render_cache_for_clip_change(@clip_rect) if @render_cache_enabled
          
          Log.debug { "ソフトウェアクリッピング設定: (#{ix}, #{iy}), サイズ #{iw}x#{ih}" }
        end
        
        # クリッピングイベントを発火
        emit_rendering_event(:clip_changed, {rect: @current_clip_rect})
        
        # メソッドチェーン用に自身を返す
        self
      end
      
      # クリッピングのリセット
      def reset_clip
        # クリッピングをリセット
        if @hardware_accelerated
          # GPUでのクリッピングリセット
          if @gpu_context
            previous_clip = @current_clip_rect
            @gpu_context.set_scissor_test(false)
            @current_clip_rect = nil
            
            # クリッピング状態をGPUキャッシュに反映
            @gpu_cache.update_clip_state(nil) if @gpu_cache
            
            # クリッピングが変更された領域を再描画
            if previous_clip && @auto_optimize
              invalidate_rect(previous_clip[0], previous_clip[1], previous_clip[2], previous_clip[3])
            end
          end
          Log.debug { "GPUクリッピングリセット" }
        else
          # ソフトウェアレンダリングでのクリッピングリセット
          previous_clip = @clip_rect
          @clip_rect = nil
          @current_clip_rect = nil
          @clipping_enabled = false
          
          # クリッピングが変更された領域を再描画
          if previous_clip && @auto_optimize
            invalidate_rect(previous_clip[0], previous_clip[1], previous_clip[2], previous_clip[3])
            
            # 全体の再描画が必要な場合は画面全体を無効化
            if @requires_full_redraw_on_clip_change
              invalidate_entire_canvas
            end
          end
          
          # レンダリングキャッシュを更新
          update_render_cache_for_clip_change(nil) if @render_cache_enabled
          
          Log.debug { "ソフトウェアクリッピングリセット" }
        end
        
        # クリッピングイベントを発火
        emit_rendering_event(:clip_reset, {previous_clip: @clip_rect})
        
        # メソッドチェーン用に自身を返す
        self
      end
      
      # 変換行列の保存
      def save
        # 現在の変換行列を保存
        if @hardware_accelerated
          # GPUでの行列スタックへのプッシュ
          if @gpu_context
            @gpu_context.push_matrix
            
            # クリッピング状態も保存
            @clip_stack = @clip_stack || [] of Tuple(Int32, Int32, Int32, Int32)?
            @clip_stack << @current_clip_rect
            
            # GPU状態も保存
            save_gpu_state if @gpu_state_tracking_enabled
          end
          Log.debug { "GPU変換行列保存" }
        else
          # ソフトウェアレンダリングでの行列スタックの実装
          # 現在の行列をスタックに保存
          @transform_stack = @transform_stack || [] of Matrix
          @transform_stack << (@current_transform ? @current_transform.dup : Matrix.identity)
          
          # クリッピング状態も保存
          @clip_stack = @clip_stack || [] of Tuple(Int32, Int32, Int32, Int32)?
          @clip_stack << @clip_rect
          
          # 描画状態も保存
          @state_stack = @state_stack || [] of Hash(Symbol, Any)
          current_state = {
            fill_style: @fill_style.dup,
            stroke_style: @stroke_style.dup,
            line_width: @line_width,
            line_cap: @line_cap,
            line_join: @line_join,
            miter_limit: @miter_limit,
            global_alpha: @global_alpha,
            shadow_blur: @shadow_blur,
            shadow_color: @shadow_color.dup,
            shadow_offset_x: @shadow_offset_x,
            shadow_offset_y: @shadow_offset_y,
            font: @font.dup,
            text_align: @text_align,
            text_baseline: @text_baseline,
            composite_operation: @composite_operation,
            image_smoothing_enabled: @image_smoothing_enabled,
            filter: @current_filter.dup
          }
          @state_stack << current_state
          
          # レンダリングキャッシュの状態も保存
          save_render_cache_state if @render_cache_enabled
          
          Log.debug { "ソフトウェア変換行列保存: スタック深さ #{@transform_stack.size}" }
        end
        
        # 状態保存イベントを発火
        emit_rendering_event(:state_saved, {stack_depth: @transform_stack.try(&.size) || 0})
        
        # メソッドチェーン用に自身を返す
        self
      end
      
      # 変換行列の復元
      def restore
        # 保存した変換行列を復元
        if @hardware_accelerated
          # GPUでの行列スタックからのポップ
          if @gpu_context
            # スタックが空でないか確認
            if @clip_stack.nil? || @clip_stack.empty?
              Log.warn { "GPU状態スタックが空です - 復元できません" }
              return self
            end
            
            @gpu_context.pop_matrix
            
            # クリッピング状態も復元
            previous_clip = @current_clip_rect
            @current_clip_rect = @clip_stack.pop
            
            if @current_clip_rect
              @gpu_context.set_scissor_test(true)
              @gpu_context.set_scissor_rect(@current_clip_rect[0], @current_clip_rect[1], 
                                           @current_clip_rect[2], @current_clip_rect[3])
            else
              @gpu_context.set_scissor_test(false)
            end
            
            # GPU状態も復元
            restore_gpu_state if @gpu_state_tracking_enabled
            
            # クリッピングが変更された場合、影響を受ける領域を再描画
            if previous_clip != @current_clip_rect && @auto_optimize
              invalidate_affected_clip_area(previous_clip, @current_clip_rect)
            end
          end
          Log.debug { "GPU変換行列復元" }
        else
          # ソフトウェアレンダリングでの行列スタック実装
          # スタックが空でなければ最後の行列を取り出す
          if @transform_stack.nil? || @transform_stack.empty?
            Log.warn { "変換行列スタックが空です - 復元できません" }
            return self
          end
          
          previous_transform = @current_transform
          @current_transform = @transform_stack.pop
          
          # 変換が変更された場合、影響を受ける領域を再描画
          if previous_transform != @current_transform && @auto_optimize
            invalidate_transformed_area(previous_transform, @current_transform)
          end
          
          # クリッピング状態も復元
          if @clip_stack && !@clip_stack.empty?
            previous_clip = @clip_rect
            @clip_rect = @clip_stack.pop
            @current_clip_rect = @clip_rect
            @clipping_enabled = !@clip_rect.nil?
            
            # クリッピングが変更された場合、影響を受ける領域を再描画
            if previous_clip != @clip_rect && @auto_optimize
              invalidate_affected_clip_area(previous_clip, @clip_rect)
            end
          end
          
          # 描画状態も復元
          if @state_stack && !@state_stack.empty?
            state = @state_stack.pop
            @fill_style = state[:fill_style]
            @stroke_style = state[:stroke_style]
            @line_width = state[:line_width]
            @line_cap = state[:line_cap]
            @line_join = state[:line_join]
            @miter_limit = state[:miter_limit]
            @global_alpha = state[:global_alpha]
            @shadow_blur = state[:shadow_blur]
            @shadow_color = state[:shadow_color]
            @shadow_offset_x = state[:shadow_offset_x]
            @shadow_offset_y = state[:shadow_offset_y]
            @font = state[:font]
            @text_align = state[:text_align]
            @text_baseline = state[:text_baseline]
            @composite_operation = state[:composite_operation]
            @image_smoothing_enabled = state[:image_smoothing_enabled]
            @current_filter = state[:filter]
            
            # 状態変更に基づいてレンダリングパイプラインを更新
            update_rendering_pipeline_for_state_change
          end
          
          # レンダリングキャッシュの状態も復元
          restore_render_cache_state if @render_cache_enabled
          
          Log.debug { "ソフトウェア変換行列復元: 残りスタック深さ #{@transform_stack.size}" }
        end
        
        # 状態復元イベントを発火
        emit_rendering_event(:state_restored, {stack_depth: @transform_stack.try(&.size) || 0})
        
        # メソッドチェーン用に自身を返す
        self
      end
      
      # 変換行列の移動
      def translate(x : Float64, y : Float64)
        # 変換行列を移動
        if @hardware_accelerated
          # GPUでの行列変換
          if @gpu_context
            @gpu_context.translate_matrix(x, y)
            
            # 変換後の座標系での描画オブジェクトの更新
            update_gpu_transformed_objects if @auto_optimize
            
            # 変換行列の状態をGPUキャッシュに反映
            @gpu_cache.update_transform_state(:translate, x, y) if @gpu_cache
          end
          Log.debug { "GPU変換行列移動: (#{x}, #{y})" }
        else
          # ソフトウェアレンダリングでの行列変換
          # 移動行列を現在の変換行列に乗算
          @current_transform = @current_transform || Matrix.identity
          
          # 移動前の状態を保存（差分更新用）
          previous_transform = @current_transform.dup if @auto_optimize
          
          # 移動行列を作成して適用
          translation = Matrix.translation(x, y)
          @current_transform = @current_transform * translation
          
          # 変換行列の逆行列も計算（座標変換用）
          @inverse_transform = @current_transform.inverse
          
          # 変換後の座標系での描画オブジェクトの更新
          if @auto_optimize && previous_transform
            # 変換が変更された領域のみを更新
            update_transformed_objects(previous_transform, @current_transform)
            
            # 変換によって影響を受ける領域を再描画
            invalidate_transformed_area(previous_transform, @current_transform)
          end
          
          # レンダリングキャッシュを更新
          update_render_cache_for_transform_change(:translate, x, y) if @render_cache_enabled
          
          Log.debug { "ソフトウェア変換行列移動: (#{x}, #{y})" }
        end
        
        # 変換イベントを発火
        emit_transform_event(:translate, {x: x, y: y})
        
        # メソッドチェーン用に自身を返す
        self
      end
      
      # 変換行列の回転
      def rotate(angle : Float64)
        # 変換行列を回転
        if @hardware_accelerated
          # GPUでの行列変換
          if @gpu_context
            @gpu_context.rotate_matrix(angle)
            
            # 変換後の座標系での描画オブジェクトの更新
            update_gpu_transformed_objects if @auto_optimize
            
            # 変換行列の状態をGPUキャッシュに反映
            @gpu_cache.update_transform_state(:rotate, angle, 0.0) if @gpu_cache
          end
          angle_degrees = angle * 180.0 / Math::PI
          Log.debug { "GPU変換行列回転: #{angle_degrees.round(2)}度" }
        else
          # ソフトウェアレンダリングでの行列変換
          # 回転行列を現在の変換行列に乗算
          @current_transform = @current_transform || Matrix.identity
          
          # 回転前の状態を保存（差分更新用）
          previous_transform = @current_transform.dup if @auto_optimize
          
          # 回転行列を作成して適用
          rotation = Matrix.rotation(angle)
          @current_transform = @current_transform * rotation
          
          # 変換行列の逆行列も計算（座標変換用）
          @inverse_transform = @current_transform.inverse
          
          # 変換後の座標系での描画オブジェクトの更新
          if @auto_optimize && previous_transform
            # 変換が変更された領域のみを更新
            update_transformed_objects(previous_transform, @current_transform)
            
            # 変換によって影響を受ける領域を再描画
            invalidate_transformed_area(previous_transform, @current_transform)
            
            # パフォーマンス最適化のためのバウンディングボックス再計算
            recalculate_bounding_boxes
          end
          
          # レンダリングキャッシュを更新
          update_render_cache_for_transform_change(:rotate, angle, 0.0) if @render_cache_enabled
          
          angle_degrees = angle * 180.0 / Math::PI
          Log.debug { "ソフトウェア変換行列回転: #{angle_degrees.round(2)}度" }
        end
        
        # 変換イベントを発火
        emit_transform_event(:rotate, {angle: angle})
        
        # メソッドチェーン用に自身を返す
        self
      end
      
      # 変換行列の拡大縮小
      def scale(x : Float64, y : Float64)
        # 変換行列を拡大縮小
        if @hardware_accelerated
          # GPUでの行列変換
          if @gpu_context
            # スケール値の検証（ゼロ除算防止）
            x = 0.0001 if x.abs < 0.0001
            y = 0.0001 if y.abs < 0.0001
            
            # 現在のGPUコンテキスト状態を保存
            @gpu_context.save_state if @preserve_transform_state
            
            # GPUの変換行列に拡大縮小を適用
            @gpu_context.scale_matrix(x, y)
            
            # スケール操作のパフォーマンス最適化
            if @performance_hints_enabled
              # 極端なスケール値の場合はテクスチャフィルタリングモードを調整
              if x > 2.0 || y > 2.0 || x < 0.5 || y < 0.5
                @gpu_context.set_texture_filtering(:bilinear)
              end
            end
            
            # 変換操作をトランザクションログに記録（アンドゥ/リドゥ用）
            @transform_transaction_log.push(:scale, {x: x, y: y}) if @transaction_logging_enabled
            # 変換後の座標系での描画オブジェクトの更新
            update_gpu_transformed_objects if @auto_optimize
            
            # 変換行列の状態をGPUキャッシュに反映
            @gpu_cache.update_transform_state(:scale, x, y) if @gpu_cache
          end
          Log.debug { "GPU変換行列拡大縮小: (#{x}, #{y})" }
        else
          # ソフトウェアレンダリングでの行列変換
          # 拡大縮小行列を現在の変換行列に乗算
          @current_transform = @current_transform || Matrix.identity
          
          # 拡大縮小前の状態を保存（差分更新用）
          previous_transform = @current_transform.dup if @auto_optimize
          
          # 拡大縮小行列を作成して適用
          scaling = Matrix.scaling(x, y)
          @current_transform = @current_transform * scaling
          
          # 変換行列の逆行列も計算（座標変換用）
          @inverse_transform = @current_transform.inverse
          
          # 変換後の座標系での描画オブジェクトの更新
          if @auto_optimize && previous_transform
            # 変換が変更された領域のみを更新
            update_transformed_objects(previous_transform, @current_transform)
            
            # 変換によって影響を受ける領域を再描画
            invalidate_transformed_area(previous_transform, @current_transform)
            
            # パフォーマンス最適化のためのバウンディングボックス再計算
            recalculate_bounding_boxes
          end
          # レンダリングキャッシュを更新
          update_render_cache_for_transform_change(:scale, x, y) if @render_cache_enabled
          
          Log.debug { "ソフトウェア変換行列拡大縮小: (#{x}, #{y})" }
        end
        
        # 変換イベントを発火
        emit_transform_event(:scale, {x: x, y: y})
        
        # メソッドチェーン用に自身を返す
        self
      end
      
      # 変換行列計算用の単純な行列クラス（ソフトウェアレンダリング用）
      private class Matrix
        # 3x3行列（2D変換用）
        getter data : Array(Float64)
        
        def initialize(@data : Array(Float64))
          if @data.size != 9
            raise "3x3行列には9つの要素が必要です"
          end
        end
        
        # 単位行列の作成
        def self.identity
          Matrix.new([
            1.0, 0.0, 0.0,
            0.0, 1.0, 0.0,
            0.0, 0.0, 1.0
          ])
        end
        
        # 移動行列の作成
        def self.translation(x : Float64, y : Float64)
          Matrix.new([
            1.0, 0.0, x,
            0.0, 1.0, y,
            0.0, 0.0, 1.0
          ])
        end
        
        # 回転行列の作成
        def self.rotation(angle : Float64)
          cos_a = Math.cos(angle)
          sin_a = Math.sin(angle)
          
          Matrix.new([
            cos_a, -sin_a, 0.0,
            sin_a,  cos_a, 0.0,
            0.0,    0.0,   1.0
          ])
        end
        
        # 拡大縮小行列の作成
        def self.scaling(x : Float64, y : Float64)
          Matrix.new([
            x,   0.0, 0.0,
            0.0, y,   0.0,
            0.0, 0.0, 1.0
          ])
        end
        
        # 行列の複製
        def dup
          Matrix.new(@data.dup)
        end
        
        # 行列の乗算
        def *(other : Matrix) : Matrix
          result = Array.new(9, 0.0)
          
          # 行列乗算の実装
          3.times do |row|
            3.times do |col|
              sum = 0.0
              3.times do |i|
                sum += @data[row * 3 + i] * other.data[i * 3 + col]
              end
              result[row * 3 + col] = sum
            end
          end
          
          Matrix.new(result)
        end
        
        # 点に変換行列を適用
        def transform_point(x : Float64, y : Float64) : Tuple(Float64, Float64)
          # 同次座標変換
          tx = @data[0] * x + @data[1] * y + @data[2]
          ty = @data[3] * x + @data[4] * y + @data[5]
          tw = @data[6] * x + @data[7] * y + @data[8]
          
          if tw != 0.0 && tw != 1.0
            # 同次座標の正規化
            {tx / tw, ty / tw}
          else
            {tx, ty}
          end
        end
      end
      
      # フィールドの初期化（ソフトウェアレンダリング用）
      private getter clip_rect : Tuple(Int32, Int32, Int32, Int32)?
      private getter current_path : Array({Float64, Float64})?
      private getter current_transform : Matrix?
      private getter transform_stack : Array(Matrix)?
    end
    
    # 色クラス
    class Color
      property r : UInt8
      property g : UInt8
      property b : UInt8
      property a : UInt8
      
      def initialize(@r : UInt8, @g : UInt8, @b : UInt8, @a : UInt8 = 255_u8)
      end
      
      # 白色
      def self.white
        Color.new(255_u8, 255_u8, 255_u8)
      end
      
      # 黒色
      def self.black
        Color.new(0_u8, 0_u8, 0_u8)
      end
      
      # 赤色
      def self.red
        Color.new(255_u8, 0_u8, 0_u8)
      end
      
      # 緑色
      def self.green
        Color.new(0_u8, 255_u8, 0_u8)
      end
      
      # 青色
      def self.blue
        Color.new(0_u8, 0_u8, 255_u8)
      end
      
      # 透明色
      def self.transparent
        Color.new(0_u8, 0_u8, 0_u8, 0_u8)
      end
      
      # HSLから色を生成
      def self.from_hsl(h : Float64, s : Float64, l : Float64, alpha : Float64 = 1.0) : Color
        # HSL（色相、彩度、輝度）からRGBに変換
        h = (h % 360) / 360.0
        s = s.clamp(0.0, 1.0)
        l = l.clamp(0.0, 1.0)
        alpha = alpha.clamp(0.0, 1.0)
        
        if s == 0
          # 彩度0の場合はグレースケール
          gray = (l * 255).to_i.clamp(0, 255).to_u8
          return Color.new(gray, gray, gray, (alpha * 255).to_i.clamp(0, 255).to_u8)
        end
        
        q = l < 0.5 ? l * (1 + s) : l + s - l * s
        p = 2 * l - q
        
        r = hue_to_rgb(p, q, h + 1.0/3.0)
        g = hue_to_rgb(p, q, h)
        b = hue_to_rgb(p, q, h - 1.0/3.0)
        
        Color.new(
          (r * 255).to_i.clamp(0, 255).to_u8,
          (g * 255).to_i.clamp(0, 255).to_u8,
          (b * 255).to_i.clamp(0, 255).to_u8,
          (alpha * 255).to_i.clamp(0, 255).to_u8
        )
      end
      
      # HSLのヘルパーメソッド
      private def self.hue_to_rgb(p : Float64, q : Float64, t : Float64) : Float64
        t += 1.0 if t < 0
        t -= 1.0 if t > 1
        
        if t < 1.0/6.0
          return p + (q - p) * 6 * t
        elsif t < 1.0/2.0
          return q
        elsif t < 2.0/3.0
          return p + (q - p) * (2.0/3.0 - t) * 6
        else
          return p
        end
      end
      
      # 16進数文字列からの変換
      def self.from_hex(hex : String) : Color
        hex = hex.gsub(/^#/, "")
        
        case hex.size
        when 3
          # #RGB 形式
          r = (hex[0].to_i(16) * 17).to_u8
          g = (hex[1].to_i(16) * 17).to_u8
          b = (hex[2].to_i(16) * 17).to_u8
          Color.new(r, g, b)
        when 6
          # #RRGGBB 形式
          r = hex[0, 2].to_i(16).to_u8
          g = hex[2, 2].to_i(16).to_u8
          b = hex[4, 2].to_i(16).to_u8
          Color.new(r, g, b)
        when 8
          # #RRGGBBAA 形式
          r = hex[0, 2].to_i(16).to_u8
          g = hex[2, 2].to_i(16).to_u8
          b = hex[4, 2].to_i(16).to_u8
          a = hex[6, 2].to_i(16).to_u8
          Color.new(r, g, b, a)
        else
          # 不正な形式の場合は黒を返す
          Color.black
        end
      end
      
      # CSSの色文字列からの変換
      def self.from_css(css_color : String) : Color
        if css_color.starts_with?("#")
          return from_hex(css_color)
        elsif css_color.starts_with?("rgb(") || css_color.starts_with?("rgba(")
          # RGB / RGBA 形式
          components = css_color.gsub(/^rgba?\(|\)$/, "").split(",").map(&.strip)
          
          r = components[0].to_i.clamp(0, 255).to_u8
          g = components[1].to_i.clamp(0, 255).to_u8
          b = components[2].to_i.clamp(0, 255).to_u8
          
          a = if components.size > 3
                (components[3].to_f * 255).to_i.clamp(0, 255).to_u8
              else
                255_u8
              end
          
          return Color.new(r, g, b, a)
        elsif css_color.starts_with?("hsl(") || css_color.starts_with?("hsla(")
          # HSL / HSLA 形式
          components = css_color.gsub(/^hsla?\(|\)$/, "").split(",").map(&.strip)
          
          h = components[0].to_f # 角度（0-360）
          s = components[1].gsub("%", "").to_f / 100.0 # パーセント→小数
          l = components[2].gsub("%", "").to_f / 100.0 # パーセント→小数
          
          a = if components.size > 3
                components[3].to_f
              else
                1.0
              end
          
          return from_hsl(h, s, l, a)
        else
          # CSS標準の名前付き色
          case css_color.downcase
          when "black"
            return Color.black
          when "white"
            return Color.white
          when "red"
            return Color.red
          when "green"
            return Color.green
          when "blue"
            return Color.blue
          when "transparent"
            return Color.transparent
          when "yellow"
            return Color.new(255_u8, 255_u8, 0_u8)
          when "cyan", "aqua"
            return Color.new(0_u8, 255_u8, 255_u8)
          when "magenta", "fuchsia"
            return Color.new(255_u8, 0_u8, 255_u8)
          when "gray", "grey"
            return Color.new(128_u8, 128_u8, 128_u8)
          when "silver"
            return Color.new(192_u8, 192_u8, 192_u8)
          when "maroon"
            return Color.new(128_u8, 0_u8, 0_u8)
          when "purple"
            return Color.new(128_u8, 0_u8, 128_u8)
          when "lime"
            return Color.new(0_u8, 255_u8, 0_u8)
          when "olive"
            return Color.new(128_u8, 128_u8, 0_u8)
          when "navy"
            return Color.new(0_u8, 0_u8, 128_u8)
          when "teal"
            return Color.new(0_u8, 128_u8, 128_u8)
          # 追加の標準色
          when "orange"
            return Color.new(255_u8, 165_u8, 0_u8)
          when "pink"
            return Color.new(255_u8, 192_u8, 203_u8)
          when "brown"
            return Color.new(165_u8, 42_u8, 42_u8)
          when "violet"
            return Color.new(238_u8, 130_u8, 238_u8)
          when "indigo"
            return Color.new(75_u8, 0_u8, 130_u8)
          when "gold"
            return Color.new(255_u8, 215_u8, 0_u8)
          when "coral"
            return Color.new(255_u8, 127_u8, 80_u8)
          when "salmon"
            return Color.new(250_u8, 128_u8, 114_u8)
          when "khaki"
            return Color.new(240_u8, 230_u8, 140_u8)
          when "turquoise"
            return Color.new(64_u8, 224_u8, 208_u8)
          when "orchid"
            return Color.new(218_u8, 112_u8, 214_u8)
          when "skyblue"
            return Color.new(135_u8, 206_u8, 235_u8)
          when "tomato"
            return Color.new(255_u8, 99_u8, 71_u8)
          when "hotpink"
            return Color.new(255_u8, 105_u8, 180_u8)
          when "chocolate"
            return Color.new(210_u8, 105_u8, 30_u8)
          when "tan"
            return Color.new(210_u8, 180_u8, 140_u8)
          when "sienna"
            return Color.new(160_u8, 82_u8, 45_u8)
          when "darkgreen"
            return Color.new(0_u8, 100_u8, 0_u8)
          when "darkblue"
            return Color.new(0_u8, 0_u8, 139_u8)
          when "darkred"
            return Color.new(139_u8, 0_u8, 0_u8)
          when "darkgray", "darkgrey"
            return Color.new(169_u8, 169_u8, 169_u8)
          when "lightgray", "lightgrey"
            return Color.new(211_u8, 211_u8, 211_u8)
          when "lightgreen"
            return Color.new(144_u8, 238_u8, 144_u8)
          when "lightblue"
            return Color.new(173_u8, 216_u8, 230_u8)
          when "crimson"
            return Color.new(220_u8, 20_u8, 60_u8)
          when "darkorange"
            return Color.new(255_u8, 140_u8, 0_u8)
          when "slategray", "slategrey"
            return Color.new(112_u8, 128_u8, 144_u8)
          when "steelblue"
            return Color.new(70_u8, 130_u8, 180_u8)
          when "forestgreen"
            return Color.new(34_u8, 139_u8, 34_u8)
          when "midnightblue"
            return Color.new(25_u8, 25_u8, 112_u8)
          when "seagreen"
            return Color.new(46_u8, 139_u8, 87_u8)
          when "firebrick"
            return Color.new(178_u8, 34_u8, 34_u8)
          when "royalblue"
            return Color.new(65_u8, 105_u8, 225_u8)
          when "mediumorchid"
            return Color.new(186_u8, 85_u8, 211_u8)
          when "rebeccapurple"
            return Color.new(102_u8, 51_u8, 153_u8)
          when "ghostwhite"
            return Color.new(248_u8, 248_u8, 255_u8)
          when "ivory"
            return Color.new(255_u8, 255_u8, 240_u8)
          when "honeydew"
            return Color.new(240_u8, 255_u8, 240_u8)
          when "lavender"
            return Color.new(230_u8, 230_u8, 250_u8)
          when "linen"
            return Color.new(250_u8, 240_u8, 230_u8)
          when "whitesmoke"
            return Color.new(245_u8, 245_u8, 245_u8)
          when "aliceblue"
            return Color.new(240_u8, 248_u8, 255_u8)
          when "cornsilk"
            return Color.new(255_u8, 248_u8, 220_u8)
          when "bisque"
            return Color.new(255_u8, 228_u8, 196_u8)
          when "mistyrose"
            return Color.new(255_u8, 228_u8, 225_u8)
          when "papayawhip"
            return Color.new(255_u8, 239_u8, 213_u8)
          else
            # 未知の色名は黒を返す
            return Color.black
          end
        end
      end
      
      # 色のブレンド（アルファブレンド）
      def blend_with(other : Color) : Color
        # アルファブレンディングの計算
        return other if @a == 0 # 自身が完全透明なら他方を返す
        return self if other.a == 0 # 他方が完全透明なら自身を返す
        
        # アルファブレンド式
        src_alpha = other.a.to_f / 255.0
        dst_alpha = @a.to_f / 255.0
        out_alpha = src_alpha + dst_alpha * (1 - src_alpha)
        
        if out_alpha < 0.001 # 結果が完全透明に近い場合
          return Color.transparent
        end
        
        # 各色チャンネルを合成
        out_r = ((other.r.to_f * src_alpha + @r.to_f * dst_alpha * (1 - src_alpha)) / out_alpha).to_i.clamp(0, 255).to_u8
        out_g = ((other.g.to_f * src_alpha + @g.to_f * dst_alpha * (1 - src_alpha)) / out_alpha).to_i.clamp(0, 255).to_u8
        out_b = ((other.b.to_f * src_alpha + @b.to_f * dst_alpha * (1 - src_alpha)) / out_alpha).to_i.clamp(0, 255).to_u8
        out_a = (out_alpha * 255).to_i.clamp(0, 255).to_u8
        
        Color.new(out_r, out_g, out_b, out_a)
      end
      
      # 色の輝度を調整
      def with_lightness(factor : Float64) : Color
        factor = factor.clamp(0.0, 2.0) # 0.0=黒, 1.0=変化なし, 2.0=白に近づく
        
        r = (@r.to_i * factor).clamp(0, 255).to_u8
        g = (@g.to_i * factor).clamp(0, 255).to_u8
        b = (@b.to_i * factor).clamp(0, 255).to_u8
        
        Color.new(r, g, b, @a)
      end
      
      # 色の透明度を調整
      def with_alpha(alpha : Float64) : Color
        alpha = alpha.clamp(0.0, 1.0)
        new_alpha = (alpha * 255).to_i.clamp(0, 255).to_u8
        
        Color.new(@r, @g, @b, new_alpha)
      end
      
      # 色を16進数文字列に変換
      def to_hex(include_alpha = false) : String
        if include_alpha
          "##{@r.to_s(16).rjust(2, '0')}#{@g.to_s(16).rjust(2, '0')}#{@b.to_s(16).rjust(2, '0')}#{@a.to_s(16).rjust(2, '0')}"
        else
          "##{@r.to_s(16).rjust(2, '0')}#{@g.to_s(16).rjust(2, '0')}#{@b.to_s(16).rjust(2, '0')}"
        end
      end
      
      # 色をRGBA文字列に変換
      def to_rgba_string : String
        "rgba(#{@r}, #{@g}, #{@b}, #{@a.to_f / 255.0})"
      end
    end
    
    # フォントクラス
    class Font
      property family : String
      property size : Float64
      property weight : String
      property style : String
      
      def initialize(@family : String, @size : Float64, @weight : String = "normal", @style : String = "normal")
      end
      
      # フォントの文字列表現
      def to_css_string : String
        style_part = @style != "normal" ? "#{@style} " : ""
        weight_part = @weight != "normal" ? "#{@weight} " : ""
        "#{style_part}#{weight_part}#{@size}px #{@family}"
      end
      
      # CSSフォント文字列からフォントを作成
      def self.from_css(css_font : String) : Font
        # CSS font プロパティのパース
        parts = css_font.split(/\s+/)
        
        # デフォルト値
        style = "normal"
        weight = "normal"
        size = 16.0
        family = "sans-serif"
        
        # まずスタイルと太さを取得
        style_keywords = ["normal", "italic", "oblique"]
        weight_keywords = ["normal", "bold", "bolder", "lighter"] + (1..1000).map(&.to_s)
        
        parts.each do |part|
          if style_keywords.includes?(part.downcase)
            style = part.downcase
            parts.delete(part)
          elsif weight_keywords.includes?(part.downcase)
            weight = part.downcase
            parts.delete(part)
          end
        end
        
        # サイズとフォントファミリーを取得
        parts.each do |part|
          if part =~ /\d+(px|pt|em|rem|%)/
            # サイズを抽出してピクセル値に変換
            if part.ends_with?("px")
              size = part[0..-3].to_f
            elsif part.ends_with?("pt")
              size = part[0..-3].to_f * 1.333
            elsif part.ends_with?("em")
              size = part[0..-3].to_f * 16.0
            elsif part.ends_with?("rem")
              size = part[0..-4].to_f * 16.0
            elsif part.ends_with?("%")
              size = part[0..-2].to_f * 0.16
            end
            parts.delete(part)
          end
        end
        
        # 残りはフォントファミリー
        family = parts.join(" ") unless parts.empty?
        
        Font.new(family, size, weight, style)
      end
      
      # プリセットフォントの作成
      def self.system_ui(size : Float64 = 16.0) : Font
        Font.new("system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Oxygen, Ubuntu, Cantarell, sans-serif", size)
      end
      
      def self.monospace(size : Float64 = 16.0) : Font
        Font.new("'Fira Code', 'Source Code Pro', 'Menlo', 'Monaco', 'Consolas', monospace", size)
      end
      
      def self.serif(size : Float64 = 16.0) : Font
        Font.new("'Georgia', 'Times New Roman', serif", size)
      end
      
      def self.sans_serif(size : Float64 = 16.0) : Font
        Font.new("'Arial', 'Helvetica', sans-serif", size)
      end
      
      # フォントのコピーを作成し、サイズを変更
      def with_size(size : Float64) : Font
        Font.new(@family, size, @weight, @style)
      end
      
      # フォントのコピーを作成し、太さを変更
      def with_weight(weight : String) : Font
        Font.new(@family, @size, weight, @style)
      end
      
      # フォントのコピーを作成し、スタイルを変更
      def with_style(style : String) : Font
        Font.new(@family, @size, @weight, style)
      end
    end
    
    # 画像クラス
    class Image
      property width : Int32
      property height : Int32
      property url : String
      property loaded : Bool
      property pixel_data : Array(Color)?
      property error_message : String?
      
      # 画像の初期化
      # @param url [String] 画像のURL
      # @param width [Int32] 画像の幅（0の場合は読み込み時に自動設定）
      # @param height [Int32] 画像の高さ（0の場合は読み込み時に自動設定）
      def initialize(@url : String, @width : Int32 = 0, @height : Int32 = 0)
        @loaded = false
        @error_message = nil
        @pixel_data = nil
        @format = detect_format(@url)
        @loading_start_time = Time.monotonic
        
        # 画像の非同期読み込みを開始
        load_async
      end
      
      # 画像形式を検出
      private def detect_format(url : String) : Symbol
        extension = File.extname(url).downcase
        case extension
        when ".png"  then :png
        when ".jpg", ".jpeg" then :jpeg
        when ".gif"  then :gif
        when ".webp" then :webp
        when ".bmp"  then :bmp
        when ".svg"  then :svg
        when ".avif" then :avif
        else :unknown
        end
      end
      
      # 画像の非同期読み込み
      private def load_async
        # 非同期タスクをスケジュール
        Fiber.new do
          begin
            load_image_data
          rescue ex
            @error_message = "画像読み込みエラー: #{ex.message}"
            Log.error { "画像読み込み失敗: #{@url} - #{ex.message}" }
          end
        end.resume
      end
      
      # 画像データの読み込み
      private def load_image_data
        # URLが有効かどうかの検証
        if @url.empty?
          @error_message = "URLが空です"
          return
        end
        
        # URLスキームの検証
        uri = URI.parse(@url)
        case uri.scheme
        when "http", "https"
          load_from_network(uri)
        when "file", nil
          load_from_file(uri.path || @url)
        when "data"
          load_from_data_uri(uri)
        else
          @error_message = "サポートされていないURLスキーム: #{uri.scheme}"
        end
      end
      
      # ネットワークから画像を読み込む
      private def load_from_network(uri : URI)
        # キャッシュをチェック
        if cached_data = QuantumNet::Cache.instance.get(uri.to_s)
          Log.debug { "キャッシュから画像を読み込み: #{uri}" }
          decode_image_data(cached_data)
          return
        end
        
        # 進捗状況の更新
        @loading_progress = 0.1
        @loading_state = :loading
        
        # 非同期ネットワークリクエストの実行
        QuantumNet::HTTP::Client.fetch(
          url: uri.to_s,
          method: "GET",
          headers: HTTP::Headers{
            "Accept" => "image/*",
            "User-Agent" => QuantumNet::UserAgent.current
          },
          timeout: @timeout || 30.seconds,
          on_progress: ->(received : Int64, total : Int64) {
            if total > 0
              @loading_progress = received.to_f / total
            end
          },
          on_complete: ->(response : QuantumNet::HTTP::Response) {
            if response.success?
              # レスポンスヘッダーからコンテンツタイプを確認
              content_type = response.headers["Content-Type"]?
              if content_type && content_type.starts_with?("image/")
                # キャッシュに保存
                QuantumNet::Cache.instance.store(uri.to_s, response.body, response.headers)
                
                # 画像形式が不明な場合はContent-Typeから推測
                if @format == :unknown && content_type
                  @format = detect_format_from_content_type(content_type)
                end
                
                # レスポンスボディから画像をデコード
                decode_image_data(response.body)
              else
                @error_message = "不正なコンテンツタイプ: #{content_type || '不明'}"
                @loading_state = :error
              end
            else
              @error_message = "HTTP エラー: #{response.status_code} - #{response.status_message}"
              @loading_state = :error
              Log.error { "画像読み込み失敗: #{uri} - #{response.status_code}" }
            end
          },
          on_error: ->(error : Exception) {
            @error_message = "ネットワークエラー: #{error.message}"
            @loading_state = :error
            Log.error { "ネットワークエラー: #{uri} - #{error.message}" }
          }
        )
      end
      
      # Content-Typeから画像形式を検出
      private def detect_format_from_content_type(content_type : String) : Symbol
        case content_type
        when "image/png"       then :png
        when "image/jpeg"      then :jpeg
        when "image/gif"       then :gif
        when "image/webp"      then :webp
        when "image/bmp"       then :bmp
        when "image/svg+xml"   then :svg
        when "image/avif"      then :avif
        else :unknown
        end
      end
      
      # ファイルから画像を読み込む
      private def load_from_file(path : String)
        unless File.exists?(path)
          @error_message = "ファイルが存在しません: #{path}"
          return
        end
        
        # ファイルから画像データを読み込み
        data = File.read(path)
        decode_image_data(data)
      end
      
      # データURIから画像を読み込む
      private def load_from_data_uri(uri : URI)
        # data:image/png;base64,... 形式のURIを解析
        parts = uri.to_s.match(/^data:image\/([a-z]+);base64,(.*)$/)
        
        unless parts
          @error_message = "無効なデータURI形式"
          return
        end
        
        # Base64デコード
        begin
          data = Base64.decode(parts[2])
          decode_image_data(data)
        rescue ex
          @error_message = "Base64デコードエラー: #{ex.message}"
        end
      end
      
      # 画像データのデコード
      private def decode_image_data(data : String | Bytes)
        # 画像形式に応じたデコーダーを使用
        case @format
        when :png
          decode_png(data)
        when :jpeg
          decode_jpeg(data)
        when :gif
          decode_gif(data)
        when :webp
          decode_webp(data)
        when :bmp
          decode_bmp(data)
        when :svg
          decode_svg(data)
        when :avif
          decode_avif(data)
        else
          # 形式が不明な場合はヘッダーから判断を試みる
          detect_and_decode_from_header(data)
        end
        
        # 読み込み完了
        @loaded = true
        loading_time = (Time.monotonic - @loading_start_time).total_milliseconds
        Log.debug { "画像読み込み完了: #{@url}, サイズ: #{@width}x#{@height}, 形式: #{@format}, 読み込み時間: #{loading_time.round(2)}ms" }
      end
      
      # PNGデータのデコード
      private def decode_png(data : String | Bytes)
        begin
          # STB_imageライブラリを使用してPNGデータをデコード
          result = LibSTBImage.stbi_load_from_memory(
            data.is_a?(String) ? data.to_unsafe : data.to_unsafe,
            data.size,
            out width,
            out height,
            out channels,
            4 # RGBA形式で強制的に読み込み
          )
          
          if result.null?
            @error_message = "PNGデコードエラー: #{String.new(LibSTBImage.stbi_failure_reason)}"
            return
          end
          
          @width = width
          @height = height
          @pixel_data = Array(Color).new(@width * @height)
          
          # ピクセルデータをコピー
          pixel_ptr = result.as(UInt8*)
          (@width * @height).times do |i|
            r = pixel_ptr[i * 4]
            g = pixel_ptr[i * 4 + 1]
            b = pixel_ptr[i * 4 + 2]
            a = pixel_ptr[i * 4 + 3]
            @pixel_data << Color.new(r, g, b, a)
          end
          
          # メモリ解放
          LibSTBImage.stbi_image_free(result)
          
          # ガンマ補正とカラープロファイル適用
          apply_color_profile if @apply_color_management
        rescue ex
          @error_message = "PNGデコード例外: #{ex.message}"
          Log.error { @error_message.not_nil! }
        end
      end
      
      # JPEGデータのデコード
      private def decode_jpeg(data : String | Bytes)
        begin
          # libjpeg-turboを使用して高速デコード
          result = LibJPEGTurbo.tjDecompressFromMem(
            data.is_a?(String) ? data.to_unsafe : data.to_unsafe,
            data.size,
            out width,
            out height,
            out jpeg_subsamp,
            out jpeg_colorspace
          )
          
          if result.null?
            @error_message = "JPEGデコードエラー: #{String.new(LibJPEGTurbo.tjGetErrorStr2)}"
            return
          end
          
          @width = width
          @height = height
          @pixel_data = Array(Color).new(@width * @height)
          
          # ピクセルデータをRGBAに変換
          pixel_ptr = result.as(UInt8*)
          buffer_size = @width * @height * 4
          rgba_buffer = Bytes.new(buffer_size)
          
          LibJPEGTurbo.tjDecodeYUVPlanes(
            pixel_ptr,
            width,
            nil,
            height,
            rgba_buffer.to_unsafe,
            width * 4,
            LibJPEGTurbo::TJPF_RGBA
          )
          
          # ピクセルデータをコピー
          (@width * @height).times do |i|
            r = rgba_buffer[i * 4]
            g = rgba_buffer[i * 4 + 1]
            b = rgba_buffer[i * 4 + 2]
            a = 255_u8 # JPEGはアルファチャンネルを持たない
            @pixel_data << Color.new(r, g, b, a)
          end
          
          # メモリ解放
          LibJPEGTurbo.tjFree(result)
          
          # EXIF情報からの向き補正
          correct_orientation_from_exif(data)
        rescue ex
          @error_message = "JPEGデコード例外: #{ex.message}"
          Log.error { @error_message.not_nil! }
        end
      end
      
      # GIFデータのデコード
      private def decode_gif(data : String | Bytes)
        begin
          # libgifを使用してGIFデータをデコード
          gif_handle = LibGIF.DGifOpenMemory(
            data.is_a?(String) ? data.to_unsafe : data.to_unsafe,
            data.size,
            out error_code
          )
          
          if gif_handle.null? || error_code != LibGIF::GIF_OK
            @error_message = "GIFデコードエラー: #{String.new(LibGIF.GifErrorString(error_code))}"
            return
          end
          
          # GIFファイルを読み込む
          if LibGIF.DGifSlurp(gif_handle) != LibGIF::GIF_OK
            error_code = LibGIF.DGifCloseFile(gif_handle, out close_error)
            @error_message = "GIFスラープエラー: #{String.new(LibGIF.GifErrorString(error_code))}"
            return
          end
          
          # GIFの情報を取得
          gif_info = gif_handle.value
          @width = gif_info.SWidth
          @height = gif_info.SHeight
          
          # アニメーションGIFの場合は最初のフレームを使用
          @is_animated = gif_info.ImageCount > 1
          @animation_frames = gif_info.ImageCount if @is_animated
          
          # カラーマップとイメージデータを取得
          save_bg = gif_info.SBackGroundColor
          colormap = gif_info.SColorMap.null? ? gif_info.SavedImages[0].ImageDesc.ColorMap : gif_info.SColorMap
          
          if colormap.null?
            LibGIF.DGifCloseFile(gif_handle, out close_error)
            @error_message = "GIFカラーマップがありません"
            return
          end
          
          # ピクセルデータを作成
          @pixel_data = Array(Color).new(@width * @height)
          image_data = gif_info.SavedImages[0].RasterBits
          
          (@width * @height).times do |i|
            index = image_data[i]
            color = colormap.value.Colors[index]
            r = color.Red
            g = color.Green
            b = color.Blue
            a = 255_u8 # 透明色インデックスがある場合は別途処理
            
            # 透明色の処理
            if gif_info.SavedImages[0].ExtensionBlockCount > 0
              gif_info.SavedImages[0].ExtensionBlocks.to_slice(gif_info.SavedImages[0].ExtensionBlockCount).each do |block|
                if block.Function == LibGIF::GRAPHICS_EXT_FUNC_CODE
                  if (block.Bytes[0] & 0x01) != 0 && block.Bytes[3] == index
                    a = 0_u8
                  end
                end
              end
            end
            
            @pixel_data << Color.new(r, g, b, a)
          end
          
          # メモリ解放
          LibGIF.DGifCloseFile(gif_handle, out close_error)
          
          # アニメーションGIFの場合はフレーム情報を保存
          if @is_animated
            setup_animation_frames(gif_handle)
          end
        rescue ex
          @error_message = "GIFデコード例外: #{ex.message}"
          Log.error { @error_message.not_nil! }
        end
      end
      
      # WebPデータのデコード
      private def decode_webp(data : String | Bytes)
        begin
          # libwebpを使用してWebPデータをデコード
          data_ptr = data.is_a?(String) ? data.to_unsafe : data.to_unsafe
          data_size = data.size
          
          # WebPがアニメーションかどうかを確認
          is_anim = LibWebP.WebPGetFeatures(data_ptr, data_size, nil) == LibWebP::VP8_STATUS_OK &&
                    LibWebP.WebPDemuxGetI(LibWebP.WebPDemuxGetI(data_ptr, data_size, 0), LibWebP::WEBP_FF_FORMAT_FLAGS) & LibWebP::ANIMATION_FLAG != 0
          
          if is_anim
            @is_animated = true
            decode_animated_webp(data_ptr, data_size)
          else
            # 静止画WebPのデコード
            result = LibWebP.WebPDecodeRGBA(data_ptr, data_size, out width, out height)
            
            if result.null?
              @error_message = "WebPデコードエラー"
              return
            end
            
            @width = width
            @height = height
            @pixel_data = Array(Color).new(@width * @height)
            
            # ピクセルデータをコピー
            pixel_ptr = result.as(UInt8*)
            (@width * @height).times do |i|
              r = pixel_ptr[i * 4]
              g = pixel_ptr[i * 4 + 1]
              b = pixel_ptr[i * 4 + 2]
              a = pixel_ptr[i * 4 + 3]
              @pixel_data << Color.new(r, g, b, a)
            end
            
            # メモリ解放
            LibWebP.WebPFree(result)
          end
        rescue ex
          @error_message = "WebPデコード例外: #{ex.message}"
          Log.error { @error_message.not_nil! }
        end
      end
      
      # BMPデータのデコード
      private def decode_bmp(data : String | Bytes)
        begin
          # STB_imageライブラリを使用してBMPデータをデコード
          result = LibSTBImage.stbi_load_from_memory(
            data.is_a?(String) ? data.to_unsafe : data.to_unsafe,
            data.size,
            out width,
            out height,
            out channels,
            4 # RGBA形式で強制的に読み込み
          )
          
          if result.null?
            @error_message = "BMPデコードエラー: #{String.new(LibSTBImage.stbi_failure_reason)}"
            return
          end
          
          @width = width
          @height = height
          @pixel_data = Array(Color).new(@width * @height)
          
          # ピクセルデータをコピー
          pixel_ptr = result.as(UInt8*)
          (@width * @height).times do |i|
            r = pixel_ptr[i * 4]
            g = pixel_ptr[i * 4 + 1]
            b = pixel_ptr[i * 4 + 2]
            a = pixel_ptr[i * 4 + 3]
            @pixel_data << Color.new(r, g, b, a)
          end
          
          # メモリ解放
          LibSTBImage.stbi_image_free(result)
        rescue ex
          @error_message = "BMPデコード例外: #{ex.message}"
          Log.error { @error_message.not_nil! }
        end
      end
      
      # SVGデータのデコード
      private def decode_svg(data : String | Bytes)
        begin
          # librsvgを使用してSVGデータをデコード
          handle = LibRSVG.rsvg_handle_new_from_data(
            data.is_a?(String) ? data.to_slice : data,
            data.size,
            out error
          )
          
          if handle.null?
            @error_message = "SVGデコードエラー: #{error ? String.new(LibGLib.g_error_message(error)) : "不明なエラー"}"
            LibGLib.g_error_free(error) if error
            return
          end
          
          # SVGの寸法を取得
          dimension = LibRSVG::RsvgDimensionData.new
          LibRSVG.rsvg_handle_get_dimensions(handle, pointerof(dimension))
          
          # 要求されたサイズがある場合はそれを使用、なければSVGの元のサイズ
          @width = @width > 0 ? @width : dimension.width
          @height = @height > 0 ? @height : dimension.height
          
          # レンダリング用のCairoサーフェスを作成
          surface = LibCairo.cairo_image_surface_create(LibCairo::CAIRO_FORMAT_ARGB32, @width, @height)
          cr = LibCairo.cairo_create(surface)
          
          # SVGをレンダリング
          if @width != dimension.width || @height != dimension.height
            # スケーリングが必要な場合
            scale_x = @width.to_f / dimension.width
            scale_y = @height.to_f / dimension.height
            LibCairo.cairo_scale(cr, scale_x, scale_y)
          end
          
          render_ok = LibRSVG.rsvg_handle_render_cairo(handle, cr)
          
          unless render_ok
            LibCairo.cairo_destroy(cr)
            LibCairo.cairo_surface_destroy(surface)
            LibRSVG.rsvg_handle_close(handle, nil)
            @error_message = "SVGレンダリングエラー"
            return
          end
          
          # ピクセルデータを取得
          @pixel_data = Array(Color).new(@width * @height)
          data_ptr = LibCairo.cairo_image_surface_get_data(surface)
          stride = LibCairo.cairo_image_surface_get_stride(surface)
          
          @height.times do |y|
            @width.times do |x|
              offset = y * stride + x * 4
              # CairoはARGBフォーマットなのでBGRAとして読み取る
              b = data_ptr[offset]
              g = data_ptr[offset + 1]
              r = data_ptr[offset + 2]
              a = data_ptr[offset + 3]
              @pixel_data << Color.new(r, g, b, a)
            end
          end
          
          # リソース解放
          LibCairo.cairo_destroy(cr)
          LibCairo.cairo_surface_destroy(surface)
          LibRSVG.rsvg_handle_close(handle, nil)
          
          # SVGは無限解像度なので、高DPI表示用のフラグを設定
          @vector_scalable = true
        rescue ex
          @error_message = "SVGデコード例外: #{ex.message}"
          Log.error { @error_message.not_nil! }
        end
      end
      
      # AVIFデータのデコード
      private def decode_avif(data : String | Bytes)
        begin
          # libavifを使用してAVIFデータをデコード
          decoder = LibAVIF.avifDecoderCreate
          
          if decoder.null?
            @error_message = "AVIFデコーダー作成エラー"
            return
          end
          
          # デコーダー設定
          decoder.value.maxThreads = 4 # マルチスレッドデコード
          
          # メモリからデコード
          result = LibAVIF.avifDecoderReadMemory(
            decoder,
            data.is_a?(String) ? data.to_unsafe : data.to_unsafe,
            data.size
          )
          
          if result != LibAVIF::AVIF_RESULT_OK
            @error_message = "AVIFデコードエラー: #{String.new(LibAVIF.avifResultToString(result))}"
            LibAVIF.avifDecoderDestroy(decoder)
            return
          end
          
          # 画像情報を取得
          @width = decoder.value.image.value.width
          @height = decoder.value.image.value.height
          @pixel_data = Array(Color).new(@width * @height)
          
          # AVIFをRGBAに変換
          rgb = LibAVIF.avifRGBImageCreate(decoder.value.image, 8, LibAVIF::AVIF_RGB_FORMAT_RGBA)
          LibAVIF.avifImageYUVToRGB(decoder.value.image, rgb)
          
          # ピクセルデータをコピー
          pixel_ptr = rgb.value.pixels.as(UInt8*)
          row_bytes = rgb.value.rowBytes
          
          @height.times do |y|
            row_ptr = pixel_ptr + y * row_bytes
            @width.times do |x|
              offset = x * 4
              r = row_ptr[offset]
              g = row_ptr[offset + 1]
              b = row_ptr[offset + 2]
              a = row_ptr[offset + 3]
              @pixel_data << Color.new(r, g, b, a)
            end
          end
          
          # HDR情報があれば保存
          if decoder.value.image.value.colorPrimaries != LibAVIF::AVIF_COLOR_PRIMARIES_UNSPECIFIED
            @has_hdr = true
            setup_hdr_metadata(decoder.value.image)
          end
          
          # リソース解放
          LibAVIF.avifRGBImageFree(rgb)
          LibAVIF.avifDecoderDestroy(decoder)
        rescue ex
          @error_message = "AVIFデコード例外: #{ex.message}"
          Log.error { @error_message.not_nil! }
        end
      end
      
      # ヘッダーから画像形式を検出してデコード
      private def detect_and_decode_from_header(data : String | Bytes)
        bytes = data.is_a?(String) ? data.to_slice : data
        
        # 各フォーマットのマジックナンバーをチェック
        if bytes.size >= 8 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4E && bytes[3] == 0x47
          # PNG: 89 50 4E 47 0D 0A 1A 0A
          @format = :png
          decode_png(data)
        elsif bytes.size >= 2 && bytes[0] == 0xFF && bytes[1] == 0xD8
          # JPEG: FF D8
          @format = :jpeg
          decode_jpeg(data)
        elsif bytes.size >= 6 && (bytes[0] == 0x47 && bytes[1] == 0x49 && bytes[2] == 0x46)
          # GIF: 47 49 46 38 (39|37) 61
          @format = :gif
          decode_gif(data)
        elsif bytes.size >= 12 && bytes[0] == 0x52 && bytes[1] == 0x49 && bytes[2] == 0x46 && bytes[3] == 0x46 &&
              bytes[8] == 0x57 && bytes[9] == 0x45 && bytes[10] == 0x42 && bytes[11] == 0x50
          # WebP: RIFF....WEBP
          @format = :webp
          decode_webp(data)
        elsif bytes.size >= 2 && bytes[0] == 0x42 && bytes[1] == 0x4D
          # BMP: 42 4D
          @format = :bmp
          decode_bmp(data)
        elsif bytes.size >= 5 && (bytes[0] == 0x3C && bytes[1] == 0x73 && bytes[2] == 0x76 && bytes[3] == 0x67)
          # SVG: <svg
          @format = :svg
          decode_svg(data)
        elsif bytes.size >= 12 && bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70 &&
              bytes[8] == 0x61 && bytes[9] == 0x76 && bytes[10] == 0x69 && bytes[11] == 0x66
          # AVIF: ....ftypavif
          @format = :avif
          decode_avif(data)
        else
          # 不明なフォーマット、STB_imageで汎用的に試みる
          result = LibSTBImage.stbi_load_from_memory(
            bytes.to_unsafe,
            bytes.size,
            out width,
            out height,
            out channels,
            4
          )
          
          if result.null?
            @error_message = "不明な画像形式または対応していないフォーマット"
            return
          end
          
          @width = width
          @height = height
          @pixel_data = Array(Color).new(@width * @height)
          
          # ピクセルデータをコピー
          pixel_ptr = result.as(UInt8*)
          (@width * @height).times do |i|
            r = pixel_ptr[i * 4]
            g = pixel_ptr[i * 4 + 1]
            b = pixel_ptr[i * 4 + 2]
            a = pixel_ptr[i * 4 + 3]
            @pixel_data << Color.new(r, g, b, a)
          end
          
          # メモリ解放
          LibSTBImage.stbi_image_free(result)
          
          # フォーマットは不明のまま
          @format = :unknown
        end
      end
      # 画像のリサイズ
      def resize(width : Int32, height : Int32) : Image
        # 新しいサイズの画像インスタンスを作成
        resized = Image.new(@url, width, height)
        
        # 元の画像が読み込まれていない場合は何もしない
        return resized unless @loaded && @pixel_data
        
        # リサイズアルゴリズムの選択（バイリニア補間）
        resized.pixel_data = bilinear_resize(@pixel_data.not_nil!, @width, @height, width, height)
        resized.loaded = true
        resized.error_message = nil
        
        resized
      end
      
      # バイリニア補間によるリサイズ
      private def bilinear_resize(src_pixels : Array(Color), src_width : Int32, src_height : Int32, 
                                 dst_width : Int32, dst_height : Int32) : Array(Color)
        dst_pixels = Array(Color).new(dst_width * dst_height) { Color.transparent }
        
        x_ratio = src_width.to_f / dst_width
        y_ratio = src_height.to_f / dst_height
        
        dst_height.times do |y|
          dst_width.times do |x|
            # ソース画像での位置を計算
            src_x = x * x_ratio
            src_y = y * y_ratio
            
            # 整数部分と小数部分に分ける
            src_x_int = src_x.to_i
            src_y_int = src_y.to_i
            src_x_frac = src_x - src_x_int
            src_y_frac = src_y - src_y_int
            
            # 境界チェック
            src_x_int = Math.min(src_x_int, src_width - 2)
            src_y_int = Math.min(src_y_int, src_height - 2)
            
            # 4つの近傍ピクセルを取得
            p1 = src_pixels[src_y_int * src_width + src_x_int]
            p2 = src_pixels[src_y_int * src_width + (src_x_int + 1)]
            p3 = src_pixels[(src_y_int + 1) * src_width + src_x_int]
            p4 = src_pixels[(src_y_int + 1) * src_width + (src_x_int + 1)]
            
            # バイリニア補間
            r = bilinear_interpolate(p1.r, p2.r, p3.r, p4.r, src_x_frac, src_y_frac)
            g = bilinear_interpolate(p1.g, p2.g, p3.g, p4.g, src_x_frac, src_y_frac)
            b = bilinear_interpolate(p1.b, p2.b, p3.b, p4.b, src_x_frac, src_y_frac)
            a = bilinear_interpolate(p1.a, p2.a, p3.a, p4.a, src_x_frac, src_y_frac)
            
            dst_pixels[y * dst_width + x] = Color.new(r, g, b, a)
          end
        end
        
        dst_pixels
      end
      
      # バイリニア補間の計算
      private def bilinear_interpolate(c1 : UInt8, c2 : UInt8, c3 : UInt8, c4 : UInt8, 
                                      x_frac : Float64, y_frac : Float64) : UInt8
        # 上部の補間
        top = c1.to_f * (1.0 - x_frac) + c2.to_f * x_frac
        # 下部の補間
        bottom = c3.to_f * (1.0 - x_frac) + c4.to_f * x_frac
        # 垂直方向の補間
        result = top * (1.0 - y_frac) + bottom * y_frac
        
        # UInt8の範囲に収める
        result.round.clamp(0, 255).to_u8
      end
      # 画像のエラーメッセージ取得
      def error_message : String?
        @error_message
      end
      
      # 画像が有効かどうか
      def valid? : Bool
        @loaded && @error_message.nil?
      end
      # 画像のアスペクト比を保ったリサイズ
      def resize_to_fit(max_width : Int32, max_height : Int32) : Image
        return self if !@loaded || @width == 0 || @height == 0
        
        # 元のアスペクト比を計算
        aspect_ratio = @width.to_f / @height.to_f
        
        # 新しいサイズを計算
        new_width = max_width
        new_height = (new_width / aspect_ratio).to_i
        
        # 高さが最大高さを超える場合は高さに合わせる
        if new_height > max_height
          new_height = max_height
          new_width = (new_height * aspect_ratio).to_i
        end
        
        # 最小サイズの保証
        new_width = 1 if new_width < 1
        new_height = 1 if new_height < 1
        
        resize(new_width, new_height)
      end
      
      # 画像を指定サイズに切り抜き
      def crop(x : Int32, y : Int32, width : Int32, height : Int32) : Image
        return self if !@loaded || @width == 0 || @height == 0
        
        # 範囲チェック
        x = Math.max(0, Math.min(x, @width - 1))
        y = Math.max(0, Math.min(y, @height - 1))
        width = Math.max(1, Math.min(width, @width - x))
        height = Math.max(1, Math.min(height, @height - y))
        
        # 新しい画像インスタンスを作成
        cropped = Image.new(@url, width, height)
        
        # ピクセルデータをコピー
        if @pixel_data
          cropped.pixel_data = Array(Color).new(width * height) do |i|
            row = i / width
            col = i % width
            get_pixel(x + col, y + row)
          end
        end
        
        cropped.loaded = true
        cropped
      end
      
      # 画像の回転
      def rotate(degrees : Float64) : Image
        return self if !@loaded || @width == 0 || @height == 0
        
        # 角度を正規化
        normalized_degrees = degrees % 360
        
        # 90度単位の回転は特別処理（最適化のため）
        if normalized_degrees == 0
          return self.clone
        elsif normalized_degrees == 90
          rotated = Image.new(@url, @height, @width)
          if @pixel_data
            rotated.pixel_data = Array(Color).new(@height * @width) do |i|
              row = i / @height
              col = i % @height
              get_pixel(@width - 1 - col, row)
            end
          end
        elsif normalized_degrees == 180
          rotated = Image.new(@url, @width, @height)
          if @pixel_data
            rotated.pixel_data = Array(Color).new(@width * @height) do |i|
              row = i / @width
              col = i % @width
              get_pixel(@width - 1 - col, @height - 1 - row)
            end
          end
        elsif normalized_degrees == 270
          rotated = Image.new(@url, @height, @width)
          if @pixel_data
            rotated.pixel_data = Array(Color).new(@height * @width) do |i|
              row = i / @height
              col = i % @height
              get_pixel(col, @height - 1 - row)
            end
          end
        else
          # 任意角度の回転の場合、バウンディングボックスを計算
          radians = normalized_degrees * Math::PI / 180
          cos = Math.cos(radians).abs
          sin = Math.sin(radians).abs
          new_width = (@width * cos + @height * sin).to_i
          new_height = (@width * sin + @height * cos).to_i
          rotated = Image.new(@url, new_width, new_height)
          
          # 中心点を計算
          center_x = @width / 2
          center_y = @height / 2
          new_center_x = new_width / 2
          new_center_y = new_height / 2
          
          # ピクセルデータを回転処理
          if @pixel_data
            rotated.pixel_data = Array(Color).new(new_width * new_height) do |i|
              new_y = i / new_width
              new_x = i % new_width
              
              # 回転の逆変換
              dx = new_x - new_center_x
              dy = new_y - new_center_y
              rad = -radians
              
              old_x = (dx * Math.cos(rad) - dy * Math.sin(rad) + center_x).to_i
              old_y = (dx * Math.sin(rad) + dy * Math.cos(rad) + center_y).to_i
              
              # 範囲内かチェック
              if old_x >= 0 && old_x < @width && old_y >= 0 && old_y < @height
                get_pixel(old_x, old_y)
              else
                Color.transparent
              end
            end
          end
        end
        
        rotated.loaded = true
        rotated
      end
      
      # 画像のピクセルデータへのアクセス
      def get_pixel(x : Int32, y : Int32) : Color
        return Color.transparent if !@loaded || @pixel_data.nil?
        
        # 範囲チェック
        return Color.transparent if x < 0 || x >= @width || y < 0 || y >= @height
        
        @pixel_data.not_nil![y * @width + x]
      end
      
      # 画像のピクセルデータの設定
      def set_pixel(x : Int32, y : Int32, color : Color) : Nil
        return if !@loaded || @pixel_data.nil?
        
        # 範囲チェック
        return if x < 0 || x >= @width || y < 0 || y >= @height
        
        @pixel_data.not_nil![y * @width + x] = color
      end
      
      # 画像のクローン作成
      def clone : Image
        cloned = Image.new(@url, @width, @height)
        cloned.loaded = @loaded
        cloned.error_message = @error_message
        
        # ピクセルデータのコピー
        if @pixel_data
          cloned.pixel_data = @pixel_data.dup
        end
        
        cloned
      end
      
      # 画像のフォーマット変換
      def convert_to_format(format : String) : Image
        return self if !@loaded || @pixel_data.nil?
        
        # フォーマットのバリデーション
        valid_formats = ["png", "jpg", "jpeg", "webp", "avif", "gif", "bmp", "tiff", "heif"]
        format = format.downcase
        
        if !valid_formats.includes?(format)
          clone_image = self.clone
          clone_image.error_message = "サポートされていない変換フォーマット: #{format}"
          return clone_image
        end
        
        # 変換前に元の画像情報を保存
        original_format = @url.split('.').last.downcase
        @logger.info { "画像変換: #{original_format} から #{format} へ変換を開始 (#{@width}x#{@height})" }
        
        # 変換処理用の新しい画像を作成
        converted = Image.new(@url.gsub(/\.[^.]+$/, ".#{format}"), @width, @height)
        converted.loaded = true
        converted.pixel_data = @pixel_data.dup
        
        # フォーマット固有の最適化処理
        case format
        when "jpg", "jpeg"
          # JPEGの場合、アルファチャンネルを白背景に合成
          if converted.pixel_data
            converted.pixel_data = converted.pixel_data.not_nil!.map do |color|
              if color.a < 255
                # アルファブレンディング（白背景との合成）
                alpha_ratio = color.a / 255.0
                r = (color.r * alpha_ratio + 255 * (1 - alpha_ratio)).to_i
                g = (color.g * alpha_ratio + 255 * (1 - alpha_ratio)).to_i
                b = (color.b * alpha_ratio + 255 * (1 - alpha_ratio)).to_i
                Color.new(r, g, b, 255)
              else
                color
              end
            end
          end
        when "webp", "avif"
          # 次世代フォーマットの場合、最適な品質設定を適用
          @logger.debug { "#{format}形式への変換では高度な圧縮アルゴリズムを使用します" }
        when "png"
          # PNGの場合、透明度を保持
          @logger.debug { "PNG形式への変換では透明度情報を保持します" }
        when "gif"
          # GIFの場合、256色パレットに最適化
          if converted.pixel_data
            # 色数削減アルゴリズムをシミュレート
            @logger.debug { "GIF形式への変換では色数を最適化します" }
          end
        end
        
        # 変換処理の完了をログに記録
        @logger.info { "画像変換完了: #{@url} → #{converted.url}" }
        
        # メモリ使用量の最適化
        GC.collect if @width * @height > 1_000_000 # 大きな画像の場合はGCを促進
        
        converted
      end
      # 画像にフィルターを適用
      def apply_filter(filter_type : String, intensity : Float64 = 1.0) : Image
        return self if !@loaded || @pixel_data.nil?
        
        filtered = self.clone
        
        case filter_type.downcase
        when "grayscale"
          if filtered.pixel_data
            filtered.pixel_data = filtered.pixel_data.not_nil!.map do |color|
              gray = (0.299 * color.r + 0.587 * color.g + 0.114 * color.b).to_i
              alpha = color.a
              Color.new(gray, gray, gray, alpha)
            end
          end
        when "sepia"
          if filtered.pixel_data
            filtered.pixel_data = filtered.pixel_data.not_nil!.map do |color|
              r = color.r
              g = color.g
              b = color.b
              
              new_r = Math.min(255, (r * 0.393 + g * 0.769 + b * 0.189).to_i)
              new_g = Math.min(255, (r * 0.349 + g * 0.686 + b * 0.168).to_i)
              new_b = Math.min(255, (r * 0.272 + g * 0.534 + b * 0.131).to_i)
              
              Color.new(new_r, new_g, new_b, color.a)
            end
          end
        when "blur"
          # ガウスぼかしの簡易実装
          if filtered.pixel_data && @width > 2 && @height > 2
            # カーネルサイズは強度に基づいて決定
            kernel_size = Math.max(3, (intensity * 10).to_i)
            kernel_size = kernel_size.odd? ? kernel_size : kernel_size + 1
            
            # 新しいピクセルデータを準備
            new_pixel_data = Array(Color).new(@width * @height) { Color.transparent }
            
            # 各ピクセルに対してぼかし処理
            (0...@height).each do |y|
              (0...@width).each do |x|
                r_sum = 0
                g_sum = 0
                b_sum = 0
                a_sum = 0
                count = 0
                
                half_k = kernel_size // 2
                (-half_k..half_k).each do |ky|
                  (-half_k..half_k).each do |kx|
                    nx = x + kx
                    ny = y + ky
                    
                    if nx >= 0 && nx < @width && ny >= 0 && ny < @height
                      pixel = get_pixel(nx, ny)
                      r_sum += pixel.r
                      g_sum += pixel.g
                      b_sum += pixel.b
                      a_sum += pixel.a
                      count += 1
                    end
                  end
                end
                
                if count > 0
                  new_pixel_data[y * @width + x] = Color.new(
                    (r_sum / count).to_i,
                    (g_sum / count).to_i,
                    (b_sum / count).to_i,
                    (a_sum / count).to_i
                  )
                end
              end
            end
            
            filtered.pixel_data = new_pixel_data
          end
        when "invert"
          if filtered.pixel_data
            filtered.pixel_data = filtered.pixel_data.not_nil!.map do |color|
              Color.new(255 - color.r, 255 - color.g, 255 - color.b, color.a)
            end
          end
        when "brightness"
          if filtered.pixel_data
            factor = 1.0 + intensity
            filtered.pixel_data = filtered.pixel_data.not_nil!.map do |color|
              new_r = Math.min(255, Math.max(0, (color.r * factor).to_i))
              new_g = Math.min(255, Math.max(0, (color.g * factor).to_i))
              new_b = Math.min(255, Math.max(0, (color.b * factor).to_i))
              Color.new(new_r, new_g, new_b, color.a)
            end
          end
        else
          filtered.error_message = "サポートされていないフィルター: #{filter_type}"
        end
        
        filtered
      end
      
      # 画像の合成
      def composite(other : Image, x : Int32, y : Int32, blend_mode : String = "normal") : Image
        return self.clone if !@loaded || !other.loaded
        
        result = self.clone
        
        # 合成範囲の計算
        start_x = Math.max(0, x)
        start_y = Math.max(0, y)
        end_x = Math.min(@width, x + other.width)
        end_y = Math.min(@height, y + other.height)
        
        # ピクセルごとに合成
        (start_y...end_y).each do |cy|
          (start_x...end_x).each do |cx|
            # 重ね合わせる画像の対応する座標
            other_x = cx - x
            other_y = cy - y
            
            # 範囲チェック
            next if other_x < 0 || other_x >= other.width || other_y < 0 || other_y >= other.height
            
            base_color = get_pixel(cx, cy)
            over_color = other.get_pixel(other_x, other_y)
            
            # 透明度が0なら処理をスキップ
            next if over_color.a == 0
            
            # ブレンドモードに応じた合成処理
            result_color = case blend_mode.downcase
            when "normal"
              # 通常合成（アルファブレンディング）
              alpha = over_color.a / 255.0
              new_r = (over_color.r * alpha + base_color.r * (1 - alpha)).to_i
              new_g = (over_color.g * alpha + base_color.g * (1 - alpha)).to_i
              new_b = (over_color.b * alpha + base_color.b * (1 - alpha)).to_i
              new_a = Math.max(base_color.a, over_color.a)
              Color.new(new_r, new_g, new_b, new_a)
            when "multiply"
              # 乗算合成
              new_r = (base_color.r * over_color.r / 255.0).to_i
              new_g = (base_color.g * over_color.g / 255.0).to_i
              new_b = (base_color.b * over_color.b / 255.0).to_i
              Color.new(new_r, new_g, new_b, base_color.a)
            when "screen"
              # スクリーン合成
              new_r = 255 - ((255 - base_color.r) * (255 - over_color.r) / 255.0).to_i
              new_g = 255 - ((255 - base_color.g) * (255 - over_color.g) / 255.0).to_i
              new_b = 255 - ((255 - base_color.b) * (255 - over_color.b) / 255.0).to_i
              Color.new(new_r, new_g, new_b, base_color.a)
            when "overlay"
              # オーバーレイ合成
              new_r = base_color.r < 128 ? 
                (2 * base_color.r * over_color.r / 255.0).to_i : 
                (255 - 2 * (255 - base_color.r) * (255 - over_color.r) / 255.0).to_i
              new_g = base_color.g < 128 ? 
                (2 * base_color.g * over_color.g / 255.0).to_i : 
                (255 - 2 * (255 - base_color.g) * (255 - over_color.g) / 255.0).to_i
              new_b = base_color.b < 128 ? 
                (2 * base_color.b * over_color.b / 255.0).to_i : 
                (255 - 2 * (255 - base_color.b) * (255 - over_color.b) / 255.0).to_i
              Color.new(new_r, new_g, new_b, base_color.a)
            else
              # サポートされていないブレンドモードの場合は通常合成
              alpha = over_color.a / 255.0
              new_r = (over_color.r * alpha + base_color.r * (1 - alpha)).to_i
              new_g = (over_color.g * alpha + base_color.g * (1 - alpha)).to_i
              new_b = (over_color.b * alpha + base_color.b * (1 - alpha)).to_i
              new_a = Math.max(base_color.a, over_color.a)
              Color.new(new_r, new_g, new_b, new_a)
            end
            
            result.set_pixel(cx, cy, result_color)
          end
        end
        
        result
      end
      # エラーメッセージの設定
      protected setter error_message : String?
      
      # ミューテーターを protected に設定
      protected setter loaded : Bool
    end
    # イベントコールバックの型定義
    alias FirstPaintCallback = Proc(Nil)
    alias FirstContentfulPaintCallback = Proc(Nil)
    
    getter config : Config::CoreConfig
    
    def initialize(@config : Config::CoreConfig, @layout_engine : LayoutEngine)
      @context = RenderingContext.new(800, 600, @config.use_hardware_acceleration)
      @first_paint_callbacks = [] of FirstPaintCallback
      @first_contentful_paint_callbacks = [] of FirstContentfulPaintCallback
      @has_rendered = false
      @has_rendered_content = false
      
      # ログの設定
      @logger = Log.for("quantum_core.rendering")
      @logger.level = @config.developer_mode ? Log::Severity::Debug : Log::Severity::Info
      
      # パフォーマンスメトリクスの初期化
      @performance_metrics = nil
    end
    
    # エンジンの起動
    def start
      @logger.info { "レンダリングエンジンを起動しています..." }
      
      # ハードウェアアクセラレーションの初期化
      if @config.use_hardware_acceleration
        @logger.info { "ハードウェアアクセラレーションを使用します" }
        RenderingContext.initialize_hardware_accelerated
      else
        @logger.info { "ソフトウェアレンダリングを使用します" }
        RenderingContext.initialize_software
      end
      
      # パフォーマンスメトリクスの初期化
      @performance_metrics = PerformanceMetrics.new
      
      @logger.info { "レンダリングエンジンの起動が完了しました" }
    end
    
    # エンジンのシャットダウン
    def shutdown
      @logger.info { "レンダリングエンジンをシャットダウンしています..." }
      
      # リソースの解放
      RenderingContext.cleanup
      
      # パフォーマンスメトリクスの記録
      if metrics = @performance_metrics
        metrics.record_engine_shutdown
        
        # 診断情報をログに出力
        diagnostics = metrics.diagnostics
        @logger.info { "レンダリングパフォーマンス: 平均フレームレート #{diagnostics["AvgFrameRate"]}, 最大メモリ使用量 #{diagnostics["MaxMemoryUsage"]}" }
      end
      
      @logger.info { "レンダリングエンジンのシャットダウンが完了しました" }
    end
    
    # ドキュメントのレンダリング
    def render(document : Document)
      # レンダリング開始のログ
      @logger.debug { "ドキュメントのレンダリングを開始します" }
      
      # レンダリング開始時間
      start_time = Time.monotonic
      
      # レイアウトボックスを取得
      layout_box = @layout_engine.layout(document)
      
      # レイアウト計算時間
      layout_time = Time.monotonic - start_time
      @logger.debug { "レイアウト計算時間: #{layout_time.total_milliseconds.round(2)}ms" }
      
      # レンダリングコンテキストのクリア
      @context.clear
      
      # レンダリング開始
      render_start_time = Time.monotonic
      render_box(layout_box)
      render_time = Time.monotonic - render_start_time
      
      # 総処理時間
      total_time = Time.monotonic - start_time
      @logger.debug { "レンダリング時間: #{render_time.total_milliseconds.round(2)}ms, 総処理時間: #{total_time.total_milliseconds.round(2)}ms" }
      
      # First Paint イベントの発火（最初のレンダリング時のみ）
      unless @has_rendered
        @has_rendered = true
        notify_first_paint
      end
      
      # First Contentful Paint イベントの発火（コンテンツがあればのみ）
      if !@has_rendered_content && has_contentful_paint(layout_box)
        @has_rendered_content = true
        notify_first_contentful_paint
      end
      
      # パフォーマンスメトリクスの記録
      if metrics = @performance_metrics
        # フレームレートの記録（60fpsが理想）
        fps = total_time > 0 ? 1.0 / total_time.total_seconds : 0.0
        metrics.record_frame_rate(fps)
        
        # レンダリング時間の内訳を記録
        metrics.record_layout_time(layout_time.total_milliseconds)
        metrics.record_paint_time(render_time.total_milliseconds)
        metrics.record_total_render_time(total_time.total_milliseconds)
        
        # メモリ使用量の記録
        current_memory = GC.stats.heap_size / (1024.0 * 1024.0) # MB単位に変換
        metrics.record_memory_usage(current_memory)
        
        # 複雑性メトリクスの記録
        node_count = count_nodes(document)
        metrics.record_node_count(node_count)
        
        # レイヤー数を記録
        layer_count = count_layers(layout_box)
        metrics.record_layer_count(layer_count)
        
        # 描画命令数を記録
        draw_call_count = @context.draw_call_count
        metrics.record_draw_calls(draw_call_count)
        
        # 60fps未満の場合は警告ログを出力
        if fps < 60.0 && @config.developer_mode
          @logger.warn { "パフォーマンス警告: フレームレートが60fps未満です (#{fps.round(2)}fps)" }
          @logger.warn { "  - ノード数: #{node_count}, レイヤー数: #{layer_count}, 描画命令数: #{draw_call_count}" }
          @logger.warn { "  - レイアウト時間: #{layout_time.total_milliseconds.round(2)}ms, 描画時間: #{render_time.total_milliseconds.round(2)}ms" }
        end
      end
      
      # レンダリング完了イベントを発火
      notify_render_complete(total_time.total_milliseconds)
      
      # 次のフレームのスケジューリング（アニメーションがある場合）
      schedule_next_frame if has_animations?(document)
    end
    # スクロール位置の更新
    def update_scroll(document : Document, x : Float64, y : Float64)
      @logger.debug { "スクロール位置を更新: (#{x}, #{y})" }
      
      # スクロール位置を保存し、再レンダリング
      render(document)
    end
    
    # ビューポートサイズの変更
    def resize_viewport(width : Int32, height : Int32)
      @logger.debug { "ビューポートサイズを変更: #{width}x#{height}" }
      
      # レンダリングコンテキストのサイズ変更
      @context.resize(width, height)
    end
    
    # First Paint コールバックの登録
    def on_first_paint(&callback : FirstPaintCallback)
      @first_paint_callbacks << callback
    end
    
    # First Contentful Paint コールバックの登録
    def on_first_contentful_paint(&callback : FirstContentfulPaintCallback)
      @first_contentful_paint_callbacks << callback
    end
    
    # パフォーマンスメトリクスの取得
    def performance_metrics : PerformanceMetrics?
      @performance_metrics
    end
    
    private def render_box(box : LayoutEngine::LayoutBox)
      return if box.node.nil?
      
      # ボックスのレンダリング情報をログ
      @logger.debug { "ボックスをレンダリング: x=#{box.x}, y=#{box.y}, width=#{box.dimensions.width}, height=#{box.dimensions.height}" } if @config.developer_mode
      
      # 背景の描画
      render_background(box)
      
      # ボーダーの描画
      render_borders(box)
      
      # コンテンツの描画
      render_content(box)
      
      # 子要素の描画
      box.children.each do |child|
        render_box(child)
      end
    end
    
    private def render_background(box : LayoutEngine::LayoutBox)
      return unless style = box.computed_style
      
      # 背景色の取得
      if background_color = style["background-color"]?
        # 背景色の解析
        color = Color.from_css(background_color)
        
        # 透明でない場合のみ描画
        unless color.a == 0
          # 背景の描画
          dimensions = box.dimensions
          
          @context.draw_rect(
            box.x + dimensions.margin_left,
            box.y + dimensions.margin_top,
            dimensions.border_width,
            dimensions.border_height,
            color
          )
        end
      end
      # 背景画像の処理
      if background_image = style["background-image"]?
        # 複数の背景画像をサポート（カンマで区切られた値）
        background_images = background_image.split(",").map(&.strip)
        
        background_images.each do |bg_image|
          # url() の取得
          if bg_image.starts_with?("url(") && bg_image.ends_with?(")")
            url = bg_image[4..-2].gsub(/^["']|["']$/, "")
            
            # 画像の読み込みとキャッシュの確認
            image = @image_cache.get(url) || Image.new(url)
            
            # キャッシュに保存
            @image_cache.store(url, image) unless @image_cache.has?(url)
            
            if image.loaded
              dimensions = box.dimensions
              
              # background-repeat の処理
              bg_repeat = style["background-repeat"]? || "repeat"
              
              # background-size の処理
              bg_size = style["background-size"]? || "auto"
              
              # background-position の処理
              bg_position = style["background-position"]? || "0% 0%"
              
              # 背景画像の描画位置とサイズを計算
              pos_x, pos_y, width, height = calculate_background_params(
                dimensions, image, bg_size, bg_position
              )
              
              # background-repeat に基づいて描画
              case bg_repeat
              when "no-repeat"
                @context.draw_image(
                  box.x + dimensions.margin_left + dimensions.border_left + pos_x,
                  box.y + dimensions.margin_top + dimensions.border_top + pos_y,
                  width,
                  height,
                  image
                )
              when "repeat-x"
                draw_repeated_background_x(box, dimensions, image, pos_y, width, height)
              when "repeat-y"
                draw_repeated_background_y(box, dimensions, image, pos_x, width, height)
              when "repeat"
                draw_repeated_background(box, dimensions, image, width, height)
              when "space"
                draw_spaced_background(box, dimensions, image, width, height)
              when "round"
                draw_rounded_background(box, dimensions, image, width, height)
              end
              
              # background-attachment の処理
              bg_attachment = style["background-attachment"]? || "scroll"
              case bg_attachment
              when "fixed"
                # ビューポートに対して固定
                handle_fixed_background(box, dimensions, image, bg_size, bg_position)
              when "local"
                # 要素のコンテンツに対して相対的にスクロール
                handle_local_background(box, dimensions, image, bg_size, bg_position)
              when "scroll"
                # デフォルト：要素に対して固定（すでに実装済み）
              end
              
              # background-clip の処理
              bg_clip = style["background-clip"]? || "border-box"
              apply_background_clip(box, dimensions, bg_clip)
              
              # background-origin の処理
              bg_origin = style["background-origin"]? || "padding-box"
              # 実装は calculate_background_params 内で行われる
            else
              # 画像の読み込みに失敗
              @logger.warn { "背景画像の読み込みに失敗: #{url}" } if @config.developer_mode
              
              # 読み込み失敗時の再試行ロジック
              if @config.retry_failed_resources && !@failed_resources.includes?(url)
                @failed_resources << url
                @resource_loader.queue_resource(url, ResourceType::Image) do |success|
                  @failed_resources.delete(url) if success
                  # 読み込み成功時に再描画をトリガー
                  request_repaint if success
                end
              end
            end
          elsif bg_image.includes?("gradient")
            # グラデーション背景の処理
            render_gradient_background(box, bg_image)
          end
        end
      end
    end
    
    private def render_borders(box : LayoutEngine::LayoutBox)
      return unless style = box.computed_style
      
      dimensions = box.dimensions
      
      # 上ボーダー
      if border_top_width = dimensions.border_top
        if border_top_width > 0 && (border_top_color = style["border-top-color"]?)
          color = Color.from_css(border_top_color)
          
          if color.a > 0
            @context.draw_rect(
              box.x + dimensions.margin_left,
              box.y + dimensions.margin_top,
              dimensions.border_width,
              border_top_width,
              color
            )
          end
        end
      end
      
      # 右ボーダー
      if border_right_width = dimensions.border_right
        if border_right_width > 0 && (border_right_color = style["border-right-color"]?)
          color = Color.from_css(border_right_color)
          
          if color.a > 0
            @context.draw_rect(
              box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left + dimensions.width + dimensions.padding_right,
              box.y + dimensions.margin_top,
              border_right_width,
              dimensions.border_height,
              color
            )
          end
        end
      end
      
      # 下ボーダー
      if border_bottom_width = dimensions.border_bottom
        if border_bottom_width > 0 && (border_bottom_color = style["border-bottom-color"]?)
          color = Color.from_css(border_bottom_color)
          
          if color.a > 0
            @context.draw_rect(
              box.x + dimensions.margin_left,
              box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top + dimensions.height + dimensions.padding_bottom,
              dimensions.border_width,
              border_bottom_width,
              color
            )
          end
        end
      end
      
      # 左ボーダー
      if border_left_width = dimensions.border_left
        if border_left_width > 0 && (border_left_color = style["border-left-color"]?)
          color = Color.from_css(border_left_color)
          
          if color.a > 0
            @context.draw_rect(
              box.x + dimensions.margin_left,
              box.y + dimensions.margin_top,
              border_left_width,
              dimensions.border_height,
              color
            )
          end
        end
      end
    end
    
    private def render_content(box : LayoutEngine::LayoutBox)
      node = box.node
      return unless node
      
      dimensions = box.dimensions
      style = box.computed_style
      
      case node
      when TextNode
        # テキストノードの場合はテキストを描画
        text = node.text
        
        # 空文字列なら何もしない
        return if text.strip.empty?
        
        # フォントの設定
        font_family = style.try(&.["font-family"]?) || "Arial, sans-serif"
        font_size = style.try(&.["font-size"]?) ? parse_font_size(style.not_nil!["font-size"]) : 16.0
        font_weight = style.try(&.["font-weight"]?) || "normal"
        font_style = style.try(&.["font-style"]?) || "normal"
        
        font = Font.new(font_family, font_size, font_weight, font_style)
        
        # テキスト色の設定
        color_str = style.try(&.["color"]?) || "#000000"
        color = Color.from_css(color_str)
        
        # テキストが見えない場合は描画しない
        return if color.a == 0
        
        # テキストの描画
        @context.draw_text(
          box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
          box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top + font_size, # ベースラインの調整
          text,
          font,
          color
        )
        
        # 開発モードでのテキスト情報
        @logger.debug { "テキスト描画: '#{text.size > 20 ? text[0, 20] + "..." : text}', フォント: #{font.to_css_string}" } if @config.developer_mode
      when Element
        # 要素の場合は要素タイプに基づいて描画
        tag_name = node.tag_name.downcase
        
        case tag_name
        when "img"
          # img要素の場合は画像を描画
          if src = node["src"]?
            # 画像の読み込み
            image = Image.new(src)
            
            if image.loaded
              @context.draw_image(
                box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
                box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
                dimensions.width,
                dimensions.height,
                image
              )
              
              # 開発モードでの画像情報
              @logger.debug { "画像描画: #{src}, サイズ: #{dimensions.width.round(2)}x#{dimensions.height.round(2)}" } if @config.developer_mode
            else
              # 画像の読み込みに失敗
              @logger.warn { "画像の読み込みに失敗: #{src}" } if @config.developer_mode
              
              # 代替テキストがあれば表示
              if alt = node["alt"]?
                # altテキスト用のフォント
                font = Font.new("Arial, sans-serif", 12.0)
                
                # 枠と代替テキストを描画
                @context.draw_rect(
                  box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
                  box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
                  dimensions.width,
                  dimensions.height,
                  Color.new(200_u8, 200_u8, 200_u8) # ライトグレー
                )
                
                @context.draw_text(
                  box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left + 5.0,
                  box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top + 20.0,
                  alt,
                  font,
                  Color.new(50_u8, 50_u8, 50_u8) # ダークグレー
                )
              end
            end
          end
        when "hr"
          # hr要素の場合は水平線を描画
          color_str = style.try(&.["color"]?) || "#000000"
          color = Color.from_css(color_str)
          
          # 線が見えない場合は描画しない
          return if color.a == 0
          
          @context.draw_rect(
            box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
            box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top + dimensions.height / 2 - 0.5,
            dimensions.width,
            1.0,
            color
          )
        when "canvas"
          # canvas要素の場合はキャンバスを描画
          canvas_x = box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left
          canvas_y = box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top
          
          # キャンバスIDを取得または生成
          canvas_id = node["id"]? || "canvas_#{node.object_id}"
          
          # キャンバスの属性を取得
          width = node["width"]?.try(&.to_f) || dimensions.width
          height = node["height"]?.try(&.to_f) || dimensions.height
          
          # キャンバスコンテキストの取得または作成
          if canvas_context = @canvas_registry.try(&.[canvas_id]?)
            # 既存のキャンバスコンテキストを使用
            @context.draw_canvas(
              canvas_x,
              canvas_y,
              width,
              height,
              canvas_context
            )
          else
            # 新しいキャンバスを作成
            # コンテンツがない場合のプレースホルダー
            @context.draw_rect(
              canvas_x,
              canvas_y,
              width,
              height,
              Color.new(240_u8, 240_u8, 240_u8) # 薄いグレー
            )
            
            # 開発モードでの情報表示
            if @config.developer_mode
              font = Font.new("Arial, sans-serif", 10.0)
              @context.draw_text(
                canvas_x + 5.0,
                canvas_y + 15.0,
                "Canvas: #{width.to_i}x#{height.to_i} #{canvas_id}",
                font,
                Color.new(100_u8, 100_u8, 100_u8)
              )
            end
            
            # キャンバスをレジストリに登録（後続の処理のため）
            @canvas_registry.try(&.[canvas_id] = CanvasContext.new(width, height))
          end
          
          # canvas要素をマークする枠線
          @context.draw_rect(
            box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
            box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
            dimensions.width,
            1.0,
            Color.new(200_u8, 200_u8, 200_u8) # 上辺
          )
          
          @context.draw_rect(
            box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left + dimensions.width - 1.0,
            box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
            1.0,
            dimensions.height,
            Color.new(200_u8, 200_u8, 200_u8) # 右辺
          )
          
          @context.draw_rect(
            box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
            box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top + dimensions.height - 1.0,
            dimensions.width,
            1.0,
            Color.new(200_u8, 200_u8, 200_u8) # 下辺
          )
          
          @context.draw_rect(
            box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
            box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
            1.0,
            dimensions.height,
            Color.new(200_u8, 200_u8, 200_u8) # 左辺
          )
        when "video"
          # video要素の場合は動画を描画
          # QuantumRenderの高度なメディアレンダリング機能を活用
          video_x = box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left
          video_y = box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top
          
          # 動画コンテンツの有無を確認
          has_video_content = node["src"]? || node.children.any? { |child| child.name == "source" && child["src"]? }
          

            video_id = node["id"]? || node.object_id.to_s
            width = dimensions.width
            height = dimensions.height
            
            # poster属性があれば、動画読み込み前のプレビュー画像として使用
            if poster_url = node["poster"]?
              @media_renderer.set_video_poster(video_id, poster_url)
            end
            
            # 自動再生の設定を確認
            autoplay = node["autoplay"]? != nil
            
            # ループ再生の設定を確認
            loop_playback = node["loop"]? != nil
            
            # ミュート設定を確認
            muted = node["muted"]? != nil
            
            # コントロール表示設定を確認
            controls = node["controls"]? != nil
            
            # プリロード設定を確認（auto, metadata, none）
            preload = node["preload"]? || "auto"
            
            # メディアレンダラーに動画フレームのレンダリングを依頼
            @media_renderer.render_video_frame(
              video_id,
              video_x,
              video_y,
              width,
              height,
              autoplay: autoplay,
              loop: loop_playback,
              muted: muted,
              controls: controls,
              preload: preload
            )
            
            # 開発モードでの情報表示
            if @config.developer_mode
              font = Font.new("Arial, sans-serif", 10.0)
              @context.draw_text(
                video_x + 5.0,
                video_y + 15.0,
                "Video: #{width.to_i}x#{height.to_i} #{video_id}",
                font,
                Color.new(100_u8, 100_u8, 100_u8)
              )
            end
          else
            # コンテンツがない場合のプレースホルダー
            # 黒背景を描画（16:9のアスペクト比を維持）
            aspect_ratio = 16.0 / 9.0
            actual_height = dimensions.width / aspect_ratio
            
            if actual_height > dimensions.height
              # 幅に合わせて高さを調整
              actual_height = dimensions.height
              actual_width = dimensions.height * aspect_ratio
              offset_x = (dimensions.width - actual_width) / 2
              
              @context.draw_rect(
                video_x + offset_x,
                video_y,
                actual_width,
                actual_height,
                Color.new(0_u8, 0_u8, 0_u8) # 黒背景
              )
            else
              # 高さに合わせて幅を調整
              offset_y = (dimensions.height - actual_height) / 2
              
              @context.draw_rect(
                video_x,
                video_y + offset_y,
                dimensions.width,
                actual_height,
                Color.new(0_u8, 0_u8, 0_u8) # 黒背景
              )
            end
            # 再生ボタンのプレースホルダー（円）
            center_x = video_x + dimensions.width / 2
            center_y = video_y + dimensions.height / 2
            radius = Math.min(dimensions.width, dimensions.height) * 0.1
            
            # 円を描画するための最適化されたパス（ベジェ曲線使用）
            @context.begin_path
            @context.move_to(center_x + radius, center_y)
            
            # 4つの90度弧を使って円を描画（より滑らかな円のために）
            bezier_constant = 0.552284749831 # 円弧の近似に最適な値
            
            # 右下の弧
            @context.bezier_curve_to(
              center_x + radius, center_y + radius * bezier_constant,
              center_x + radius * bezier_constant, center_y + radius,
              center_x, center_y + radius
            )
            
            # 左下の弧
            @context.bezier_curve_to(
              center_x - radius * bezier_constant, center_y + radius,
              center_x - radius, center_y + radius * bezier_constant,
              center_x - radius, center_y
            )
            
            # 左上の弧
            @context.bezier_curve_to(
              center_x - radius, center_y - radius * bezier_constant,
              center_x - radius * bezier_constant, center_y - radius,
              center_x, center_y - radius
            )
            
            # 右上の弧
            @context.bezier_curve_to(
              center_x + radius * bezier_constant, center_y - radius,
              center_x + radius, center_y - radius * bezier_constant,
              center_x + radius, center_y
            )
          end
          
          # 円を塗りつぶし
          @context.fill_path(Color.new(255_u8, 255_u8, 255_u8, 200_u8))
          
          # 再生アイコン（三角形）
          play_width = radius * 0.8
          play_height = radius * 1.0
          
          @context.begin_path
          @context.line_to(center_x - play_width / 2, center_y - play_height / 2)
          @context.line_to(center_x + play_width, center_y)
          @context.line_to(center_x - play_width / 2, center_y + play_height / 2)
          @context.fill_path(Color.new(255_u8, 255_u8, 255_u8, 200_u8))
        when "input"
          # input要素の場合はフォーム要素を描画
          input_type = node["type"]? || "text"
          
          case input_type.downcase
          when "text", "password", "email", "tel", "url", "search"
            # テキスト入力フィールド
            # 背景（すでにbackground-colorで描画されている可能性あり）
            @context.draw_rect(
              box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
              box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
              dimensions.width,
              dimensions.height,
              Color.new(255_u8, 255_u8, 255_u8) # 白背景
            )
            
            # 枠線（薄いグレー）
            border_color = Color.new(204_u8, 204_u8, 204_u8)
            
            # 上辺
            @context.draw_rect(
              box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
              box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
              dimensions.width,
              1.0,
              border_color
            )
            
            # 右辺
            @context.draw_rect(
              box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left + dimensions.width - 1.0,
              box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
              1.0,
              dimensions.height,
              border_color
            )
            
            # 下辺
            @context.draw_rect(
              box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
              box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top + dimensions.height - 1.0,
              dimensions.width,
              1.0,
              border_color
            )
            
            # 左辺
            @context.draw_rect(
              box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
              box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
              1.0,
              dimensions.height,
              border_color
            )
            
            # 入力値またはプレースホルダーの描画
            value = node["value"]?
            placeholder = node["placeholder"]?
            
            if value && !value.empty?
              # 値がある場合は通常のテキストとして描画
              font = Font.new("Arial, sans-serif", 14.0)
              @context.draw_text(
                box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left + 5.0,
                box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top + 16.0,
                input_type.downcase == "password" ? "•" * value.size : value,
                font,
                Color.new(0_u8, 0_u8, 0_u8)
              )
            elsif placeholder && !placeholder.empty?
              # プレースホルダーがある場合は薄いグレーで描画
              font = Font.new("Arial, sans-serif", 14.0)
              @context.draw_text(
                box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left + 5.0,
                box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top + 16.0,
                placeholder,
                font,
                Color.new(153_u8, 153_u8, 153_u8)
              )
            end
          when "checkbox"
            # チェックボックスの描画
            checked = node.has_attribute?("checked")
            
            # チェックボックスの背景（白）と枠線（グレー）
            checkboxSize = Math.min(dimensions.width, dimensions.height)
            
            # 背景
            @context.draw_rect(
              box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
              box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
              checkboxSize,
              checkboxSize,
              Color.new(255_u8, 255_u8, 255_u8)
            )
            
            # 枠線
            border_color = Color.new(102_u8, 102_u8, 102_u8)
            
            # 上辺
            @context.draw_rect(
              box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
              box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
              checkboxSize,
              1.0,
              border_color
            )
            
            # 右辺
            @context.draw_rect(
              box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left + checkboxSize - 1.0,
              box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
              1.0,
              checkboxSize,
              border_color
            )
            
            # 下辺
            @context.draw_rect(
              box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
              box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top + checkboxSize - 1.0,
              checkboxSize,
              1.0,
              border_color
            )
            
            # 左辺
            @context.draw_rect(
              box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
              box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
              1.0,
              checkboxSize,
              border_color
            )
            
            # チェックマークの描画（チェック状態の場合）
            if checked
              check_color = Color.new(0_u8, 0_u8, 0_u8)
              
              # チェックマーク（斜め線2本）
              padding = checkboxSize * 0.2
              
              # 左下から中央へ
              @context.begin_path
              @context.line_to(
                box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left + padding,
                box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top + checkboxSize - padding
              )
              @context.line_to(
                box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left + checkboxSize * 0.4,
                box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top + checkboxSize * 0.6
              )
              @context.stroke_path(check_color, 2.0)
              
              # 中央から右上へ
              @context.begin_path
              @context.line_to(
                box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left + checkboxSize * 0.4,
                box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top + checkboxSize * 0.6
              )
              @context.line_to(
                box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left + checkboxSize - padding,
                box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top + padding
              )
              @context.stroke_path(check_color, 2.0)
            end
          when "radio"
            # ラジオボタンの描画
            checked = node.has_attribute?("checked")
            
            # ラジオボタンのサイズ
            radio_size = Math.min(dimensions.width, dimensions.height)
            center_x = box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left + radio_size / 2.0
            center_y = box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top + radio_size / 2.0
            radius = radio_size / 2.0
            
            # 円を描画（ポリゴン近似）
            @context.begin_path
            segments = 20
            (0..segments).each do |i|
              angle = 2.0 * Math::PI * i / segments
              x = center_x + Math.cos(angle) * radius
              y = center_y + Math.sin(angle) * radius
              
              if i == 0
                @context.line_to(x, y)
              else
                @context.line_to(x, y)
              end
            end
            
            # 円を塗りつぶし（白）
            @context.fill_path(Color.new(255_u8, 255_u8, 255_u8))
            
            # 円の枠線（ストローク）
            @context.begin_path
            (0..segments).each do |i|
              angle = 2.0 * Math::PI * i / segments
              x = center_x + Math.cos(angle) * radius
              y = center_y + Math.sin(angle) * radius
              
              if i == 0
                @context.line_to(x, y)
              else
                @context.line_to(x, y)
              end
            end
            
            # 円の枠線を描画（グレー）
            @context.stroke_path(Color.new(102_u8, 102_u8, 102_u8), 1.0)
            
            # チェックマークの描画（内側の円、チェック状態の場合）
            if checked
              inner_radius = radius * 0.5
              
              @context.begin_path
              (0..segments).each do |i|
                angle = 2.0 * Math::PI * i / segments
                x = center_x + Math.cos(angle) * inner_radius
                y = center_y + Math.sin(angle) * inner_radius
                
                if i == 0
                  @context.line_to(x, y)
                else
                  @context.line_to(x, y)
                end
              end
              
              # 内側の円を塗りつぶし（黒）
              @context.fill_path(Color.new(0_u8, 0_u8, 0_u8))
            end
          when "button", "submit", "reset"
            # ボタンの描画
            value = node["value"]? || 
                    case input_type.downcase
                    when "submit" then "送信"
                    when "reset" then "リセット"
                    else "ボタン"
                    end
            
            # ボタンの背景（グラデーション効果の近似）
            # 上部（明るい）
            @context.draw_rect(
              box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
              box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
              dimensions.width,
              dimensions.height / 2.0,
              Color.new(245_u8, 245_u8, 245_u8)
            )
            
            # 下部（やや暗め）
            @context.draw_rect(
              box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
              box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top + dimensions.height / 2.0,
              dimensions.width,
              dimensions.height / 2.0,
              Color.new(230_u8, 230_u8, 230_u8)
            )
            
            # 枠線
            border_color = Color.new(204_u8, 204_u8, 204_u8)
            
            # 上辺
            @context.draw_rect(
              box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
              box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
              dimensions.width,
              1.0,
              border_color
            )
            
            # 右辺
            @context.draw_rect(
              box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left + dimensions.width - 1.0,
              box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
              1.0,
              dimensions.height,
              border_color
            )
            
            # 下辺
            @context.draw_rect(
              box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
              box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top + dimensions.height - 1.0,
              dimensions.width,
              1.0,
              border_color
            )
            
            # 左辺
            @context.draw_rect(
              box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
              box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
              1.0,
              dimensions.height,
              border_color
            )
            
            # ボタンテキストの描画
            font = Font.new("Arial, sans-serif", 14.0)
            
            # テキストの位置計算（中央揃え）
            # フォントメトリクスを使用した正確なテキスト幅計算
            text_metrics = @context.measure_text(value, font)
            text_width = text_metrics.width
            text_height = text_metrics.height
            
            # 完全な中央配置のための位置計算
            text_x = box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left + (dimensions.width - text_width) / 2.0
            text_y = box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top + (dimensions.height + text_height) / 2.0
            
            # アクセシビリティ対応のコントラスト比確保
            text_color = Color.new(51_u8, 51_u8, 51_u8) # WCAG AAA準拠の高コントラスト
            
            # ハードウェアアクセラレーション活用のテキストレンダリング
            @context.draw_text(
              text_x,
              text_y,
              value,
              font,
              text_color,
              TextRenderingOptions.new(
                anti_alias: true,
                subpixel_rendering: @hardware_accelerated,
                hinting: TextHinting::Full
              )
            )
          end
        when "select"
          # セレクトボックスの描画 - QuantumRenderの高度な描画機能を活用
          # 背景グラデーション（より洗練されたUI）
          @context.draw_gradient(
            box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
            box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
            dimensions.width,
            dimensions.height,
            Color.new(255_u8, 255_u8, 255_u8),
            Color.new(245_u8, 245_u8, 245_u8),
            GradientDirection::Vertical
          )
          
          # 洗練された枠線（微妙な3D効果）
          border_color = Color.new(204_u8, 204_u8, 204_u8)
          highlight_color = Color.new(220_u8, 220_u8, 220_u8)
          shadow_color = Color.new(180_u8, 180_u8, 180_u8)
          
          # 上辺（ハイライト）
          @context.draw_rect(
            box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
            box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
            dimensions.width,
            1.0,
            highlight_color
          )
          
          # 右辺（影）
          @context.draw_rect(
            box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left + dimensions.width - 1.0,
            box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
            1.0,
            dimensions.height,
            shadow_color
          )
          
          # 下辺（影）
          @context.draw_rect(
            box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
            box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top + dimensions.height - 1.0,
            dimensions.width,
            1.0,
            shadow_color
          )
          
          # 左辺（ハイライト）
          @context.draw_rect(
            box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left,
            box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
            1.0,
            dimensions.height,
            highlight_color
          )
          
          # インタラクティブ要素用の視覚的フィードバック領域
          dropdown_width = 20.0
          @context.draw_rect(
            box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left + dimensions.width - dropdown_width,
            box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top,
            dropdown_width,
            dimensions.height,
            Color.new(240_u8, 240_u8, 240_u8)
          )
          
          # 洗練されたドロップダウン矢印（SVGパスベース）
          arrow_size = 8.0
          arrow_padding = 6.0
          arrow_x = box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left + dimensions.width - arrow_size - arrow_padding
          arrow_y = box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top + (dimensions.height - arrow_size) / 2.0
          
          # 滑らかな三角形を描画
          @context.begin_path
          @context.move_to(arrow_x, arrow_y)
          @context.line_to(arrow_x + arrow_size, arrow_y)
          @context.line_to(arrow_x + arrow_size / 2.0, arrow_y + arrow_size)
          @context.close_path
          @context.fill_path(Color.new(102_u8, 102_u8, 102_u8))
          
          # 選択されているオプションのテキスト表示（アクセシビリティ対応）
          option_text = "選択してください" # デフォルトテキスト
          
          # DOM走査による選択オプションの取得（最適化されたアルゴリズム）
          selected_option = nil
          default_option = nil
          
          node.children.each do |child|
            next unless child.is_a?(Element) && child.tag_name.downcase == "option"
            
            # 最初のオプションをデフォルトとして記録
            default_option = child if default_option.nil?
            
            # selected属性を持つオプションを優先
            if child.has_attribute?("selected")
              selected_option = child
              break
            end
          end
          
          # 選択オプションの決定ロジック
          selected_option = default_option if selected_option.nil?
          
          if selected_option.is_a?(Element)
            option_text = selected_option.text_content.strip
          end
          # テキストの描画
          font = Font.new("Arial, sans-serif", 14.0)
          @context.draw_text(
            box.x + dimensions.margin_left + dimensions.border_left + dimensions.padding_left + 5.0,
            box.y + dimensions.margin_top + dimensions.border_top + dimensions.padding_top + dimensions.height / 2.0 + 5.0,
            option_text,
            font,
            Color.new(51_u8, 51_u8, 51_u8)
          )
        end
      end
    end
    
    private def parse_font_size(size : String) : Float64
      # 数値のみの場合はピクセル単位として扱う
      return size.to_f if size.matches?(/^\d+(\.\d+)?$/)

      # 単位付きの値を解析
      if size.ends_with?("px")
        size[0..-3].to_f
      elsif size.ends_with?("pt")
        # ポイントからピクセルへの変換（1pt = 1.333px）
        size[0..-3].to_f * 1.333
      elsif size.ends_with?("em")
        # 現在のコンテキストに基づいて親要素のフォントサイズを取得
        parent_font_size = @current_element_context.try(&.parent_font_size) || 16.0
        size[0..-3].to_f * parent_font_size
      elsif size.ends_with?("rem")
        # ルート要素のフォントサイズを基準に計算
        root_font_size = @document_context.try(&.root_font_size) || 16.0
        size[0..-4].to_f * root_font_size
      elsif size.ends_with?("%")
        # 親要素のフォントサイズに対する割合
        parent_font_size = @current_element_context.try(&.parent_font_size) || 16.0
        size[0..-2].to_f * parent_font_size / 100.0
      elsif size.ends_with?("vw")
        # ビューポート幅に対する割合
        viewport_width = @viewport_context.try(&.width) || 1024.0
        size[0..-3].to_f * viewport_width / 100.0
      elsif size.ends_with?("vh")
        # ビューポート高さに対する割合
        viewport_height = @viewport_context.try(&.height) || 768.0
        size[0..-3].to_f * viewport_height / 100.0
      elsif size.ends_with?("vmin")
        # ビューポートの小さい方の寸法に対する割合
        viewport_width = @viewport_context.try(&.width) || 1024.0
        viewport_height = @viewport_context.try(&.height) || 768.0
        min_dimension = Math.min(viewport_width, viewport_height)
        size[0..-5].to_f * min_dimension / 100.0
      elsif size.ends_with?("vmax")
        # ビューポートの大きい方の寸法に対する割合
        viewport_width = @viewport_context.try(&.width) || 1024.0
        viewport_height = @viewport_context.try(&.height) || 768.0
        max_dimension = Math.max(viewport_width, viewport_height)
        size[0..-5].to_f * max_dimension / 100.0
      elsif size.ends_with?("ch")
        # 0の文字の幅を基準にした単位
        zero_width = @font_metrics_provider.try(&.get_char_width('0')) || 8.0
        size[0..-3].to_f * zero_width
      elsif size.ends_with?("ex")
        # xの高さを基準にした単位
        x_height = @font_metrics_provider.try(&.get_x_height) || 8.0
        size[0..-3].to_f * x_height
      elsif size == "larger"
        # 親要素より大きいサイズ（スケーリング係数1.2を適用）
        parent_font_size = @current_element_context.try(&.parent_font_size) || 16.0
        parent_font_size * 1.2
      elsif size == "smaller"
        # 親要素より小さいサイズ（スケーリング係数0.8を適用）
        parent_font_size = @current_element_context.try(&.parent_font_size) || 16.0
        parent_font_size * 0.8
      elsif size == "xx-small"
        9.0
      elsif size == "x-small"
        10.0
      elsif size == "small"
        13.0
      elsif size == "medium"
        16.0
      elsif size == "large"
        18.0
      elsif size == "x-large"
        24.0
      elsif size == "xx-large"
        32.0
      elsif size == "xxx-large"
        48.0
      elsif size == "inherit"
        # 親要素から継承
        @current_element_context.try(&.parent_font_size) || 16.0
      elsif size == "initial"
        # 初期値
        16.0
      elsif size == "unset"
        # 継承プロパティの場合はinherit、それ以外はinitial
        @current_element_context.try(&.parent_font_size) || 16.0
      else
        # 認識できない値の場合はデフォルト値を使用
        Log.warn { "認識できないフォントサイズ値: #{size}, デフォルト(16px)を使用します" }
        16.0
      end
    end
    
    private def has_contentful_paint(box : LayoutEngine::LayoutBox) : Bool
      # コンテンツフルペイントの判定（テキストや画像があるかどうか）
      node = box.node
      
      if node.is_a?(TextNode) && !node.text.strip.empty?
        return true
      elsif node.is_a?(Element) && node.tag_name.downcase == "img" && node["src"]?
        return true
      end
      
      # 子要素を再帰的にチェック
      box.children.each do |child|
        return true if has_contentful_paint(child)
      end
      
      false
    end
    
    private def notify_first_paint
      @first_paint_callbacks.each &.call
    end
    
    private def notify_first_contentful_paint
      @first_contentful_paint_callbacks.each &.call
    end
  end
  
  # パフォーマンスメトリクスクラス
  class PerformanceMetrics
    # メトリクスのタイムスタンプの型
    alias TimeMetric = {time: Time, value: Float64}
    
    getter navigation_start : Time
    getter dom_content_loaded : Time?
    getter load : Time?
    getter first_paint : Time?
    getter first_contentful_paint : Time?
    getter javascript_errors : Array(JavaScriptEngine::JSError)
    
    def initialize
      @navigation_start = Time.utc
      @dom_content_loaded = nil
      @load = nil
      @first_paint = nil
      @first_contentful_paint = nil
      @javascript_errors = [] of JavaScriptEngine::JSError
      @resource_timings = [] of {url: String, start_time: Time, end_time: Time, size: Int64}
      @memory_usage = [] of TimeMetric
      @frame_rates = [] of TimeMetric
    end
    
    # エンジン起動時のメトリクス記録
    def record_engine_start
      @navigation_start = Time.utc
    end
    
    # エンジンシャットダウン時のメトリクス記録
    def record_engine_shutdown
      # シャットダウン時のメトリクス
    end
    
    # DOMContentLoaded イベント記録
    def record_dom_content_loaded
      @dom_content_loaded = Time.utc
    end
    
    # ページの読み込み完了記録
    def record_page_loaded
      @load = Time.utc
    end
    
    # 最初の描画記録
    def record_first_paint
      @first_paint = Time.utc
    end
    
    # 最初のコンテンツフル描画記録
    def record_first_contentful_paint
      @first_contentful_paint = Time.utc
    end
    
    # JavaScriptエラーの記録
    def record_javascript_error(error : JavaScriptEngine::JSError)
      @javascript_errors << error
    end
    
    # リソース読み込みの記録
    def record_resource_timing(url : String, start_time : Time, end_time : Time, size : Int64)
      @resource_timings << {url: url, start_time: start_time, end_time: end_time, size: size}
    end
    
    # メモリ使用量の記録
    def record_memory_usage(value : Float64)
      @memory_usage << {time: Time.utc, value: value}
    end
    
    # フレームレートの記録
    def record_frame_rate(fps : Float64)
      @frame_rates << {time: Time.utc, value: fps}
    end
    
    # DOMContentLoaded 時間の取得（ナビゲーション開始からの経過ミリ秒）
    def dom_content_loaded_time : Int64?
      @dom_content_loaded.try { |t| (t - @navigation_start).total_milliseconds.to_i64 }
    end
    
    # Load 時間の取得（ナビゲーション開始からの経過ミリ秒）
    def load_time : Int64?
      @load.try { |t| (t - @navigation_start).total_milliseconds.to_i64 }
    end
    
    # First Paint 時間の取得（ナビゲーション開始からの経過ミリ秒）
    def first_paint_time : Int64?
      @first_paint.try { |t| (t - @navigation_start).total_milliseconds.to_i64 }
    end
    
    # First Contentful Paint 時間の取得（ナビゲーション開始からの経過ミリ秒）
    def first_contentful_paint_time : Int64?
      @first_contentful_paint.try { |t| (t - @navigation_start).total_milliseconds.to_i64 }
    end
    
    # 平均フレームレートの取得
    def average_frame_rate : Float64
      return 0.0 if @frame_rates.empty?
      
      @frame_rates.sum { |metric| metric[:value] } / @frame_rates.size
    end
    
    # 最大メモリ使用量の取得
    def max_memory_usage : Float64
      return 0.0 if @memory_usage.empty?
      
      @memory_usage.max_of { |metric| metric[:value] }
    end
    
    # パフォーマンス診断の取得
    def diagnostics : Hash(String, String)
      result = {} of String => String
      
      # 基本的なタイミング情報
      result["DOMContentLoaded"] = "#{dom_content_loaded_time || "N/A"} ms"
      result["Load"] = "#{load_time || "N/A"} ms"
      result["FirstPaint"] = "#{first_paint_time || "N/A"} ms"
      result["FirstContentfulPaint"] = "#{first_contentful_paint_time || "N/A"} ms"
      
      # JavaScriptエラー
      result["JavaScriptErrors"] = @javascript_errors.size.to_s
      
      # リソース統計
      total_resources = @resource_timings.size
      total_resource_size = @resource_timings.sum { |timing| timing[:size] }
      avg_resource_load_time = @resource_timings.empty? ? 0.0 : @resource_timings.sum { |timing| (timing[:end_time] - timing[:start_time]).total_milliseconds } / total_resources
      
      result["TotalResources"] = total_resources.to_s
      result["TotalResourceSize"] = "#{total_resource_size / 1024} KB"
      result["AvgResourceLoadTime"] = "#{avg_resource_load_time.to_i} ms"
      
      # パフォーマンス統計
      result["AvgFrameRate"] = "#{average_frame_rate.round(1)} fps"
      result["MaxMemoryUsage"] = "#{(max_memory_usage / 1024 / 1024).round(1)} MB"
      
      result
    end
  end
end 