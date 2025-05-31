# src/crystal/ui/screens/settings/settings_panels/general_panel.cr
require "./base_panel"
require "../../../../quantum_core/config"

module QuantumUI
  # 一般設定パネル
  class GeneralSettingsPanel < SettingsPanel
    def initialize(@config_manager : QuantumCore::ConfigManager)
      super
    end
    
    protected def setup_items
      # 起動設定
      @items << SectionHeader.new("起動設定", "一般")
      
      @items << ToggleSetting.new(
        "起動時に前回のセッションを復元",
        "前回閉じたタブとウィンドウを起動時に再開します",
        "一般",
        @config_manager.get_bool("general.startup.restore_session", true),
        ->(enabled : Bool) {
          @config_manager.set("general.startup.restore_session", enabled)
        }
      )
      
      @items << ToggleSetting.new(
        "起動時に新しいタブページを開く",
        "新しいタブでスタートページを表示します",
        "一般",
        @config_manager.get_bool("general.startup.open_new_tab", true),
        ->(enabled : Bool) {
          @config_manager.set("general.startup.open_new_tab", enabled)
        }
      )
      
      # ホームページ設定
      @items << SectionHeader.new("ホームページ", "一般")
      
      @items << InputSetting.new(
        "ホームページURL",
        "ホームボタンをクリックしたときに開くページのURL",
        "一般",
        @config_manager.get_string("general.homepage.url", "about:home"),
        "https://example.com",
        ->(value : String) {
          @config_manager.set("general.homepage.url", value)
        }
      )
      
      @items << ToggleSetting.new(
        "新しいタブでホームページを開く",
        "新しいタブを開いたとき、ホームページを表示します",
        "一般",
        @config_manager.get_bool("general.homepage.use_as_newtab", false),
        ->(enabled : Bool) {
          @config_manager.set("general.homepage.use_as_newtab", enabled)
        }
      )
      
      # 検索エンジン設定
      @items << SectionHeader.new("既定の検索エンジン", "一般")
      
      search_engines = ["Google", "Bing", "DuckDuckGo", "Yahoo", "カスタム"]
      selected_engine = @config_manager.get_string("general.search.default_engine", "Google")
      selected_index = search_engines.index(selected_engine) || 0
      
      @items << SelectSetting.new(
        "検索エンジン",
        "アドレスバーでの検索に使用するエンジン",
        "一般",
        search_engines,
        selected_index,
        ->(value : String) {
          @config_manager.set("general.search.default_engine", value)
          # カスタムエンジンが選択された場合は、カスタムURLの入力欄を表示
          @items[6].visible = (value == "カスタム")
        }
      )
      
      # カスタム検索エンジンのURL入力欄（初期状態では非表示）
      custom_url_input = InputSetting.new(
        "カスタム検索URL",
        "検索クエリは %s で置換されます (例: https://example.com/search?q=%s)",
        "一般",
        @config_manager.get_string("general.search.custom_url", ""),
        "https://example.com/search?q=%s",
        ->(value : String) {
          @config_manager.set("general.search.custom_url", value)
        }
      )
      custom_url_input.visible = (selected_engine == "カスタム")
      @items << custom_url_input
      
      # ダウンロード設定
      @items << SectionHeader.new("ダウンロード", "一般")
      
      @items << InputSetting.new(
        "ダウンロード保存先",
        "ファイルをダウンロードするデフォルトのフォルダ",
        "一般",
        @config_manager.get_string("general.download.default_directory", ""),
        "C:\\Users\\Username\\Downloads",
        ->(value : String) {
          @config_manager.set("general.download.default_directory", value)
        }
      )
      
      @items << ToggleSetting.new(
        "ダウンロード前に保存先を確認",
        "ファイルをダウンロードする前に保存先を確認するダイアログを表示します",
        "一般",
        @config_manager.get_bool("general.download.ask_before_download", true),
        ->(enabled : Bool) {
          @config_manager.set("general.download.ask_before_download", enabled)
        }
      )
      
      @items << ToggleSetting.new(
        "ダウンロード完了後にファイルを自動的に開く",
        "ダウンロードが完了したらファイルを自動的に開きます",
        "一般",
        @config_manager.get_bool("general.download.auto_open", false),
        ->(enabled : Bool) {
          @config_manager.set("general.download.auto_open", enabled)
        }
      )
      
      # 言語設定
      @items << SectionHeader.new("言語", "一般")
      
      languages = ["日本語", "English", "中文", "Español", "Français", "Deutsch", "Italiano", "Русский", "العربية"]
      selected_language = @config_manager.get_string("general.language", "日本語")
      selected_index = languages.index(selected_language) || 0
      
      @items << SelectSetting.new(
        "表示言語",
        "ブラウザのUIに使用する言語",
        "一般",
        languages,
        selected_index,
        ->(value : String) {
          @config_manager.set("general.language", value)
        }
      )
      
      # 更新設定
      @items << SectionHeader.new("更新", "一般")
      
      update_options = ["自動的に更新する", "更新を確認するが自動インストールはしない", "更新を確認しない"]
      selected_update = @config_manager.get_string("general.update.policy", "自動的に更新する")
      selected_index = update_options.index(selected_update) || 0
      
      @items << SelectSetting.new(
        "ブラウザの更新",
        "ブラウザの更新方法を選択します",
        "一般",
        update_options,
        selected_index,
        ->(value : String) {
          @config_manager.set("general.update.policy", value)
        }
      )
      
      @items << ButtonSetting.new(
        "今すぐ更新を確認",
        "利用可能な更新を今すぐ確認します",
        "一般",
        "確認する",
        ->() {
          # 更新確認の処理
          Logger.info("更新を確認しています...")
        }
      )
    end
    
    def panel_title : String
      "一般設定"
    end
    
    def refresh
      # 設定値を最新の状態に更新
      @items.each do |item|
        case item
        when ToggleSetting
          if item.label == "起動時に前回のセッションを復元"
            item.enabled = @config_manager.get_bool("general.startup.restore_session", true)
          elsif item.label == "起動時に新しいタブページを開く"
            item.enabled = @config_manager.get_bool("general.startup.open_new_tab", true)
          elsif item.label == "新しいタブでホームページを開く"
            item.enabled = @config_manager.get_bool("general.homepage.use_as_newtab", false)
          elsif item.label == "ダウンロード前に保存先を確認"
            item.enabled = @config_manager.get_bool("general.download.ask_before_download", true)
          elsif item.label == "ダウンロード完了後にファイルを自動的に開く"
            item.enabled = @config_manager.get_bool("general.download.auto_open", false)
          end
        when InputSetting
          if item.label == "ホームページURL"
            item.value = @config_manager.get_string("general.homepage.url", "about:home")
          elsif item.label == "カスタム検索URL"
            item.value = @config_manager.get_string("general.search.custom_url", "")
          elsif item.label == "ダウンロード保存先"
            item.value = @config_manager.get_string("general.download.default_directory", "")
          end
        when SelectSetting
          if item.label == "検索エンジン"
            selected_engine = @config_manager.get_string("general.search.default_engine", "Google")
            item.selected_index = item.options.index(selected_engine) || 0
          elsif item.label == "表示言語"
            selected_language = @config_manager.get_string("general.language", "日本語")
            item.selected_index = item.options.index(selected_language) || 0
          elsif item.label == "ブラウザの更新"
            selected_update = @config_manager.get_string("general.update.policy", "自動的に更新する")
            item.selected_index = item.options.index(selected_update) || 0
          end
        end
      end
      
      # カスタム検索エンジンの表示/非表示
      selected_engine = @config_manager.get_string("general.search.default_engine", "Google")
      @items[6].visible = (selected_engine == "カスタム")
    end
  end
end 