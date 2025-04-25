# src/crystal/ui/layout_engine.cr
require "./component"
require "../utils/logger"

module QuantumUI
  # UIコンポーネントのレイアウトを管理するエンジン
  # 現時点では固定レイアウトだが、将来的に拡張可能
  class LayoutEngine
    # レイアウトタイプ (例)
    enum LayoutType
      FIXED   # 固定配置 (現在)
      VERTICAL # 垂直配置
      HORIZONTAL # 水平配置
      GRID     # グリッド配置
    end

    # レイアウトを実行し、各コンポーネントの bounds を設定する
    # @param components [Array(Component)] レイアウト対象のコンポーネントリスト
    # @param window_width [Int32] ウィンドウ幅
    # @param window_height [Int32] ウィンドウ高さ
    def layout(components : Array(Component), window_width : Int32, window_height : Int32)
      Log.debug "Performing layout calculation for window size: #{window_width}x#{window_height}"
      # 現在は固定レイアウトを前提とする
      # TODO: より動的なレイアウトアルゴリズムを実装 (Flexbox, Grid等)
      #       - コンポーネントのスタイルプロパティ (display, flex, grid など) を解釈
      #       - Yoga (https://yogalayout.com/) のような外部ライブラリの利用も検討
      #       - または、シンプルな垂直/水平レイアウトコンテナの実装から始める
      perform_fixed_layout(components, window_width, window_height)
    end

    private def perform_fixed_layout(components : Array(Component), width : Int32, height : Int32)
      # 各コンポーネントの固定位置とサイズを定義 (仮)
      # この部分は実際のUIデザインに基づいて調整が必要
      component_layouts = {
        AddressBar         => {0, 0, width, 32},
        NavigationControls => {0, 32, 96, 32},
        TabBar             => {96, 32, width - 96, 32},
        SidePanel          => {0, 64, 200, height - 64 - 24},
        ContentArea        => {200, 64, width - 200, height - 64 - 24},
        StatusBar          => {0, height - 24, width, 24},
        NetworkStatusOverlay => {0, height - 48, width, 24}, # Status Barの上
        ContextMenu        => nil, # ContextMenu は動的に位置が決まるため、ここでは設定しない
        SettingsInterface  => {width / 4, height / 4, width / 2, height / 2} # 中央に表示 (仮)
      }

      components.each do |component|
        layout_rect = component_layouts[component.class]?
        if layout_rect
          x, y, w, h = layout_rect
          component.bounds = {x, y, w, h}
          # Log.debug "Layout set for #{component.class}: #{component.bounds}"
        else
          # ContextMenu や非表示コンポーネントなどは bounds を設定しない
          component.bounds = nil unless component.is_a?(ContextMenu)
          # Log.debug "Layout skipped for #{component.class}"
        end

        # SettingsInterface は visible 状態に応じて bounds を設定
        if component.is_a?(SettingsInterface)
           component.bounds = layout_rect if component.visible
        end

        # SidePanel も visible 状態に応じて ContentArea のレイアウトを調整すべきだが、
        # 現状では ContentArea が SidePanel の幅を直接参照しているため省略
      end
    rescue ex
      Log.error "Error during layout calculation", exception: ex
    end
  end
end 