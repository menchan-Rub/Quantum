# src/crystal/ui/component.cr
require "concave" # 仮。実際のUIライブラリに依存
require "../events/event_types"

module QuantumUI
  # 全てのUIコンポーネントが実装すべきインターフェース
  # レンダリング、イベント処理、レイアウトに関する責務を持つ
  abstract class Component
    # 自身の領域を描画する
    # @param window [Concave::Window] 描画対象のウィンドウ
    abstract def render(window : Concave::Window)

    # イベントを処理する
    # @param event [QuantumEvents::Event] 処理対象のイベント
    # @return [Bool] イベントを消費したかどうか
    abstract def handle_event(event : QuantumEvents::Event) : Bool

    # レイアウト計算のための推奨サイズを返す
    # @return [Tuple(Int32, Int32)] (推奨幅, 推奨高さ)
    abstract def preferred_size : Tuple(Int32, Int32)

    # 自身のレイアウト矩形を設定/取得する
    property bounds : Tuple(Int32, Int32, Int32, Int32)? # {x, y, width, height}

    # 可視状態を設定/取得する
    property visible : Bool = true

    # フォーカス状態を設定/取得する
    property focused : Bool = false

    # 子コンポーネントを持つ場合の共通処理 (例)
    # getter children : Array(Component) = [] of Component
    # def add_child(child : Component)
    #   children << child
    # end
  end
end 