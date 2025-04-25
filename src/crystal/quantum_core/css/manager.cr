# src/crystal/quantum_core/css/manager.cr
require "../css/parser"
require "../dom/manager"
require "../../utils/logger"

module QuantumCore::CSS
  # ロガー
  Log = ::Log.for(self)

  # --- CSS マネージャー ---
  class Manager
    getter stylesheets : Array(Stylesheet)

    def initialize
      @stylesheets = [] of Stylesheet
    end

    # すべてのスタイルシートをクリア
    def clear_stylesheets : Void
      @stylesheets.clear
      Log.debug { "すべてのスタイルシートをクリアしました" }
    end

    # ファイルからCSSを読み込み、スタイルシートを追加
    def add_stylesheet_file(path : String) : Void
      css = File.read(path)
      add_stylesheet(css)
      Log.debug { "CSSファイルを読み込みました: #{path}" }
    rescue ex
      Log.error { "CSSファイルの読み込みに失敗しました: #{path} - #{ex.message}" }
    end

    # 指定インデックスのスタイルシートを削除
    def remove_stylesheet(index : Int) : Bool
      if index >= 0 && index < @stylesheets.size
        @stylesheets.delete_at(index)
        Log.debug { "スタイルシートを削除しました: index=#{index}" }
        true
      else
        Log.warn { "無効なスタイルシートインデックス: #{index}" }
        false
      end
    end

    # 読み込まれたスタイルシート数を返す
    def count : Int32
      @stylesheets.size
    end

    # スタイルシートの概要情報リストを返す
    def list_summaries : Array(String)
      @stylesheets.map.with_index do |sheet, i|
        "[#{i}] #{sheet.rules.size} ルール"
      end
    end

    # 指定インデックスのスタイルシートを置換
    def replace_stylesheet(index : Int, css : String) : Bool
      return false unless index >= 0 && index < @stylesheets.size
      @stylesheets[index] = Stylesheet.parse(css)
      Log.debug { "スタイルシートを置換しました: index=#{index}" }
      true
    rescue ex
      Log.error { "スタイルシート置換に失敗しました: #{ex.message}" }
      false
    end

    # ファイルから読み込んだスタイルシートを置換
    def reload_stylesheet_file(index : Int, path : String) : Bool
      css = File.read(path)
      result = replace_stylesheet(index, css)
      Log.debug { "スタイルシートファイルを再読み込みしました: #{path}" } if result
      result
    rescue ex
      Log.error { "スタイルシートファイルの再読み込みに失敗しました: #{path} - #{ex.message}" }
      false
    end

    # ドキュメント内の全要素について computed_style をクリア
    def reset_computed_styles(document : ::QuantumCore::DOM::Document) : Void
      traverse_and_clear(document)
      Log.debug { "ドキュメント全要素のcomputed_styleをクリアしました" }
    end

    private def traverse_and_clear(node : ::QuantumCore::DOM::Node) : Void
      if node.is_a?(::QuantumCore::DOM::Element)
        node.computed_style.clear
      end
      node.children.each do |child|
        traverse_and_clear(child)
      end
    end

    # CSS文字列を追加してパース
    # @param css [String]
    def add_stylesheet(css : String) : Void
      raise ArgumentError.new("css must be a non-empty String") unless css.is_a?(String) && !css.empty?
      @stylesheets << Stylesheet.parse(css)
    end

    # 全スタイルシートを DOM に適用 (統合的にスタイルを解決)
    # @param document [QuantumCore::DOM::Document]
    def apply_to(document : ::QuantumCore::DOM::Document) : Void
      Log.debug { "CSS適用開始: スタイルシート数=#{@stylesheets.size}" }
      # 全要素の既存スタイルをクリア
      reset_computed_styles(document)
      # DOMを走査し要素ごとにスタイルを計算
      apply_node(document)
      Log.debug { "CSS適用完了" }
    end

    # DOMツリーをトラバースして各要素にスタイル適用
    private def apply_node(node : ::QuantumCore::DOM::Node) : Void
      if node.is_a?(::QuantumCore::DOM::Element)
        apply_to_element(node.as(::QuantumCore::DOM::Element))
      end
      node.children.each do |child|
        apply_node(child)
      end
    end

    # 要素にマッチする全シートの宣言を集約し computed_style に設定
    private def apply_to_element(element : ::QuantumCore::DOM::Element) : Void
      decls = [] of ComputedDeclaration
      # インライン style 属性 (最大優先度)
      if style = element.getAttribute("style")
        self.class.parse_inline_style(style).each do |d|
          decls << ComputedDeclaration.new(d.property, d.value, 1000, -1)
        end
      end
      # スタイルシートのルールを順番に適用
      @stylesheets.each_with_index do |sheet, s_index|
        sheet.rules.each_with_index do |rule, r_index|
          rule.selectors.each do |sel|
            if sel.match?(element)
              rule.declarations.each do |d|
                # sheet順(r_index)と優先度で order を計算
                decls << ComputedDeclaration.new(d.property, d.value, sel.specificity, s_index * 1000 + r_index)
              end
              break
            end
          end
        end
      end
      # プロパティ毎に特異度・orderで最適な値を選択
      element.computed_style.clear
      decls.group_by { |d| d.property }.each do |prop, ds|
        best = ds.max_by { |d| [d.specificity, d.order] }
        # カスタムプロパティと var() を解決して値を設定
        val = best.value
        element.computed_style[prop] = resolve_vars(val, element.computed_style)
      end
    end

    private def resolve_vars(value : String, computed : Hash(String, String)) : String
      # var(--name[, fallback]) を再帰的に解決
      result = value.dup
      var_pattern = /var\(\s*--([a-zA-Z0-9\-]+)(?:\s*,\s*([^\)]+))?\s*\)/
      # 最大ループ回数で無限ループ防止
      0.step(10) do
        break unless result.match?(var_pattern)
        result = result.gsub(var_pattern) do |match|
          name = $1
          fallback = $2?
          if computed[name]
            computed[name]
          elsif fallback
            fallback
          else
            ""
          end
        end
      end
      result
    end
  end
end 