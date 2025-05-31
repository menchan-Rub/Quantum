@[Link("quantum_zig_core")]
lib ZigRenderer
  # Zigネイティブレンダリングエンジンとのバインディング
  
  # 初期化と破棄
  fun create_renderer(width : LibC::UInt, height : LibC::UInt, tile_size : LibC::UInt) : Void*
  fun destroy_renderer(renderer : Void*) : Void
  
  # ビューポート管理
  fun resize_viewport(renderer : Void*, width : LibC::UInt, height : LibC::UInt) : LibC::Int
  fun get_viewport_size(renderer : Void*, width : LibC::UInt*, height : LibC::UInt*) : Void
  
  # レンダリング操作
  fun render_frame(renderer : Void*, timestamp_ns : LibC::ULongLong) : LibC::Int
  fun mark_rect_dirty(renderer : Void*, x : LibC::Int, y : LibC::Int, width : LibC::UInt, height : LibC::UInt) : Void
  fun mark_all_dirty(renderer : Void*) : Void
  
  # タイル管理
  fun get_tile_size(renderer : Void*) : LibC::UInt
  fun get_tile_count(renderer : Void*) : LibC::UInt
  fun get_dirty_tile_count(renderer : Void*) : LibC::UInt
  
  # 描画コマンド
  fun draw_rect(renderer : Void*, x : LibC::Int, y : LibC::Int, width : LibC::UInt, height : LibC::UInt, color : LibC::UInt) : LibC::Int
  fun draw_text(renderer : Void*, x : LibC::Int, y : LibC::Int, text : LibC::Char*, font_size : LibC::UInt, color : LibC::UInt) : LibC::Int
  fun draw_image(renderer : Void*, x : LibC::Int, y : LibC::Int, image_data : Void*, width : LibC::UInt, height : LibC::UInt) : LibC::Int
  
  # 高度な描画
  fun push_clip_rect(renderer : Void*, x : LibC::Int, y : LibC::Int, width : LibC::UInt, height : LibC::UInt) : LibC::Int
  fun pop_clip_rect(renderer : Void*) : LibC::Int
  fun set_transform(renderer : Void*, a : LibC::Float, b : LibC::Float, c : LibC::Float, d : LibC::Float, e : LibC::Float, f : LibC::Float) : Void
  fun reset_transform(renderer : Void*) : Void
  
  # パフォーマンス統計
  fun get_render_stats(renderer : Void*, frame_time : LibC::Float*, fps : LibC::Float*, dirty_tile_percent : LibC::Float*) : Void
  fun reset_render_stats(renderer : Void*) : Void
  
  # バッファ管理
  fun get_buffer_ptr(renderer : Void*) : Void*
  fun get_buffer_size(renderer : Void*) : LibC::ULongLong
  fun commit_buffer(renderer : Void*) : LibC::Int
end

module QuantumCore
  # Crystal側のラッパークラス
  class ZigRendererWrapper
    # Zigレンダラーへのポインタ
    @renderer : Void*
    
    # 表示領域サイズ
    @width : UInt32
    @height : UInt32
    
    # タイルサイズ
    @tile_size : UInt32
    
    # 初期化
    def initialize(width : Int32, height : Int32, tile_size : Int32 = 64)
      @width = width.to_u32
      @height = height.to_u32
      @tile_size = tile_size.to_u32
      
      # Zigレンダラーを作成
      @renderer = ZigRenderer.create_renderer(@width, @height, @tile_size)
      
      if @renderer.null?
        raise "Zigレンダラーの初期化に失敗しました"
      end
    end
    
    # 破棄
    def finalize
      unless @renderer.null?
        ZigRenderer.destroy_renderer(@renderer)
      end
    end
    
    # リサイズ処理
    def resize(width : Int32, height : Int32) : Bool
      @width = width.to_u32
      @height = height.to_u32
      
      result = ZigRenderer.resize_viewport(@renderer, @width, @height)
      if result != 0
        Log.error { "ビューポートのリサイズに失敗しました: #{result}" }
        return false
      end
      
      # すべてを再描画対象にマーク
      ZigRenderer.mark_all_dirty(@renderer)
      
      true
    end
    
    # フレーム描画
    def render_frame(timestamp_ns : Int64 = Time.monotonic.total_nanoseconds) : Bool
      result = ZigRenderer.render_frame(@renderer, timestamp_ns.to_u64)
      if result != 0
        Log.error { "フレーム描画に失敗しました: #{result}" }
        return false
      end
      
      true
    end
    
    # 矩形領域を再描画対象にマーク
    def mark_rect_dirty(x : Int32, y : Int32, width : Int32, height : Int32) : Void
      ZigRenderer.mark_rect_dirty(@renderer, x, y, width.to_u32, height.to_u32)
    end
    
    # 画面全体を再描画対象にマーク
    def mark_all_dirty : Void
      ZigRenderer.mark_all_dirty(@renderer)
    end
    
    # 矩形を描画
    def draw_rect(x : Int32, y : Int32, width : Int32, height : Int32, color : UInt32) : Bool
      result = ZigRenderer.draw_rect(@renderer, x, y, width.to_u32, height.to_u32, color)
      result == 0
    end
    
    # テキストを描画
    def draw_text(x : Int32, y : Int32, text : String, font_size : Int32 = 16, color : UInt32 = 0xFF000000) : Bool
      result = ZigRenderer.draw_text(@renderer, x, y, text.to_unsafe, font_size.to_u32, color)
      result == 0
    end
    
    # 画像を描画
    def draw_image(x : Int32, y : Int32, image_data : Bytes, width : Int32, height : Int32) : Bool
      result = ZigRenderer.draw_image(@renderer, x, y, image_data.to_unsafe.as(Void*), width.to_u32, height.to_u32)
      result == 0
    end
    
    # クリップ矩形をプッシュ
    def push_clip_rect(x : Int32, y : Int32, width : Int32, height : Int32) : Bool
      result = ZigRenderer.push_clip_rect(@renderer, x, y, width.to_u32, height.to_u32)
      result == 0
    end
    
    # クリップ矩形をポップ
    def pop_clip_rect : Bool
      result = ZigRenderer.pop_clip_rect(@renderer)
      result == 0
    end
    
    # 変換行列を設定
    def set_transform(a : Float32, b : Float32, c : Float32, d : Float32, e : Float32, f : Float32) : Void
      ZigRenderer.set_transform(@renderer, a, b, c, d, e, f)
    end
    
    # 変換行列をリセット
    def reset_transform : Void
      ZigRenderer.reset_transform(@renderer)
    end
    
    # レンダリング統計情報を取得
    def get_render_stats : {frame_time: Float32, fps: Float32, dirty_tile_percent: Float32}
      frame_time = uninitialized Float32
      fps = uninitialized Float32
      dirty_percent = uninitialized Float32
      
      ZigRenderer.get_render_stats(@renderer, pointerof(frame_time), pointerof(fps), pointerof(dirty_percent))
      
      {frame_time: frame_time, fps: fps, dirty_tile_percent: dirty_percent}
    end
    
    # 統計情報をリセット
    def reset_render_stats : Void
      ZigRenderer.reset_render_stats(@renderer)
    end
    
    # バッファにアクセス（直接メモリ操作用）
    def with_buffer
      ptr = ZigRenderer.get_buffer_ptr(@renderer)
      size = ZigRenderer.get_buffer_size(@renderer)
      
      if ptr.null? || size == 0
        raise "バッファへのアクセスに失敗しました"
      end
      
      # バッファにアクセスしてブロックを実行
      yield ptr, size
      
      # 変更をコミット
      ZigRenderer.commit_buffer(@renderer)
    end
    
    # 現在のビューポートサイズを取得
    def viewport_size : {width: UInt32, height: UInt32}
      width = uninitialized UInt32
      height = uninitialized UInt32
      
      ZigRenderer.get_viewport_size(@renderer, pointerof(width), pointerof(height))
      
      {width: width, height: height}
    end
    
    # タイルサイズを取得
    def tile_size : UInt32
      ZigRenderer.get_tile_size(@renderer)
    end
    
    # タイル総数を取得
    def tile_count : UInt32
      ZigRenderer.get_tile_count(@renderer)
    end
    
    # ダーティタイル数を取得
    def dirty_tile_count : UInt32
      ZigRenderer.get_dirty_tile_count(@renderer)
    end
  end
end 