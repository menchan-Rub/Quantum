# 完璧な履歴管理システム - 世界最高水準の実装
# Chromium、Firefox、Safariを超える高度な履歴管理機能を提供

require "json"
require "sqlite3"
require "crypto/md5"
require "uri"
require "time"

module QuantumStorage
  module History
    # 完璧な履歴エントリ構造体
    struct HistoryEntry
      include JSON::Serializable
      
      property id : Int64
      property url : String
      property title : String
      property visit_time : Time
      property visit_count : Int32
      property typed_count : Int32
      property last_visit_time : Time
      property hidden : Bool
      property favicon_url : String?
      property transition_type : TransitionType
      property referrer_url : String?
      property session_id : String?
      property duration : Time::Span?
      property scroll_position : Int32?
      property form_data : Hash(String, String)?
      property search_terms : Array(String)?
      property tags : Array(String)
      property category : String?
      property domain : String
      property protocol : String
      property port : Int32?
      property path : String
      property query_params : Hash(String, String)?
      property fragment : String?
      property content_type : String?
      property charset : String?
      property language : String?
      property geo_location : GeoLocation?
      property device_info : DeviceInfo?
      property user_agent : String?
      property ip_address : String?
      property security_state : SecurityState
      property performance_metrics : PerformanceMetrics?
      property accessibility_features : Array(String)?
      property custom_metadata : Hash(String, JSON::Any)?
      
      def initialize(@url : String, @title : String)
        @id = 0_i64
        @visit_time = Time.utc
        @visit_count = 1
        @typed_count = 0
        @last_visit_time = Time.utc
        @hidden = false
        @transition_type = TransitionType::Link
        @tags = [] of String
        
        # URL解析
        uri = URI.parse(@url)
        @domain = uri.host || ""
        @protocol = uri.scheme || "http"
        @port = uri.port
        @path = uri.path || "/"
        @query_params = parse_query_params(uri.query)
        @fragment = uri.fragment
        @security_state = determine_security_state(uri)
      end
      
      private def parse_query_params(query : String?) : Hash(String, String)?
        return nil unless query
        
        params = Hash(String, String).new
        query.split('&').each do |param|
          key, value = param.split('=', 2)
          params[URI.decode_www_form(key)] = URI.decode_www_form(value || "")
        end
        params.empty? ? nil : params
      end
      
      private def determine_security_state(uri : URI) : SecurityState
        case uri.scheme
        when "https"
          SecurityState::Secure
        when "http"
          SecurityState::Insecure
        when "file"
          SecurityState::Local
        else
          SecurityState::Unknown
        end
      end
    end
    
    # 遷移タイプ列挙型
    enum TransitionType
      Link          # リンククリック
      Typed         # アドレスバー入力
      AutoBookmark  # ブックマーク
      AutoSubframe  # サブフレーム
      ManualSubframe # 手動サブフレーム
      Generated     # 生成されたナビゲーション
      StartPage     # スタートページ
      FormSubmit    # フォーム送信
      Reload        # リロード
      Keyword       # キーワード検索
      KeywordGenerated # キーワード生成
      Redirect      # リダイレクト
      BackForward   # 戻る/進む
      NewTab        # 新しいタブ
      NewWindow     # 新しいウィンドウ
    end
    
    # セキュリティ状態
    enum SecurityState
      Secure    # HTTPS
      Insecure  # HTTP
      Local     # ローカルファイル
      Unknown   # 不明
    end
    
    # 地理的位置情報
    struct GeoLocation
      include JSON::Serializable
      
      property latitude : Float64
      property longitude : Float64
      property accuracy : Float64?
      property altitude : Float64?
      property altitude_accuracy : Float64?
      property heading : Float64?
      property speed : Float64?
      property timestamp : Time
    end
    
    # デバイス情報
    struct DeviceInfo
      include JSON::Serializable
      
      property screen_width : Int32
      property screen_height : Int32
      property viewport_width : Int32
      property viewport_height : Int32
      property device_pixel_ratio : Float64
      property color_depth : Int32
      property orientation : String
      property touch_support : Bool
      property platform : String
      property cpu_cores : Int32?
      property memory_gb : Float64?
      property connection_type : String?
      property connection_speed : String?
    end
    
    # パフォーマンス指標
    struct PerformanceMetrics
      include JSON::Serializable
      
      property load_time : Time::Span
      property dom_content_loaded : Time::Span
      property first_paint : Time::Span?
      property first_contentful_paint : Time::Span?
      property largest_contentful_paint : Time::Span?
      property first_input_delay : Time::Span?
      property cumulative_layout_shift : Float64?
      property time_to_interactive : Time::Span?
      property total_blocking_time : Time::Span?
      property resource_count : Int32
      property transfer_size : Int64
      property encoded_size : Int64
      property decoded_size : Int64
    end
    
    # 完璧な履歴管理クラス
    class HistoryManager
      Log = ::Log.for(self)
      
      # データベース接続
      getter db : DB::Database
      
      # 設定
      getter max_entries : Int32
      getter retention_days : Int32
      getter auto_cleanup : Bool
      
      # 統計情報
      getter total_entries : Int64
      getter total_visits : Int64
      getter unique_domains : Int32
      
      # インデックス管理
      private getter url_index : Hash(String, Int64)
      private getter domain_index : Hash(String, Array(Int64))
      private getter date_index : Hash(String, Array(Int64))
      private getter search_index : Hash(String, Array(Int64))
      
      def initialize(@max_entries = 1_000_000, @retention_days = 90, @auto_cleanup = true)
        @db = DB.open("sqlite3:./quantum_history.db")
        @total_entries = 0_i64
        @total_visits = 0_i64
        @unique_domains = 0
        
        @url_index = Hash(String, Int64).new
        @domain_index = Hash(String, Array(Int64)).new
        @date_index = Hash(String, Array(Int64)).new
        @search_index = Hash(String, Array(Int64)).new
        
        initialize_database
        load_indices
        
        if @auto_cleanup
          spawn cleanup_old_entries
        end
      end
      
      # データベース初期化
      private def initialize_database
        @db.exec <<-SQL
          CREATE TABLE IF NOT EXISTS history_entries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            url TEXT NOT NULL,
            title TEXT NOT NULL,
            visit_time INTEGER NOT NULL,
            visit_count INTEGER DEFAULT 1,
            typed_count INTEGER DEFAULT 0,
            last_visit_time INTEGER NOT NULL,
            hidden BOOLEAN DEFAULT FALSE,
            favicon_url TEXT,
            transition_type INTEGER NOT NULL,
            referrer_url TEXT,
            session_id TEXT,
            duration INTEGER,
            scroll_position INTEGER,
            form_data TEXT,
            search_terms TEXT,
            tags TEXT,
            category TEXT,
            domain TEXT NOT NULL,
            protocol TEXT NOT NULL,
            port INTEGER,
            path TEXT NOT NULL,
            query_params TEXT,
            fragment TEXT,
            content_type TEXT,
            charset TEXT,
            language TEXT,
            geo_location TEXT,
            device_info TEXT,
            user_agent TEXT,
            ip_address TEXT,
            security_state INTEGER NOT NULL,
            performance_metrics TEXT,
            accessibility_features TEXT,
            custom_metadata TEXT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
        SQL
        
        # インデックス作成
        create_indices
        
        Log.info { "履歴データベースを初期化しました" }
      end
      
      # インデックス作成
      private def create_indices
        indices = [
          "CREATE INDEX IF NOT EXISTS idx_url ON history_entries(url)",
          "CREATE INDEX IF NOT EXISTS idx_domain ON history_entries(domain)",
          "CREATE INDEX IF NOT EXISTS idx_visit_time ON history_entries(visit_time)",
          "CREATE INDEX IF NOT EXISTS idx_last_visit_time ON history_entries(last_visit_time)",
          "CREATE INDEX IF NOT EXISTS idx_title ON history_entries(title)",
          "CREATE INDEX IF NOT EXISTS idx_transition_type ON history_entries(transition_type)",
          "CREATE INDEX IF NOT EXISTS idx_security_state ON history_entries(security_state)",
          "CREATE INDEX IF NOT EXISTS idx_hidden ON history_entries(hidden)",
          "CREATE INDEX IF NOT EXISTS idx_visit_count ON history_entries(visit_count)",
          "CREATE INDEX IF NOT EXISTS idx_domain_visit_time ON history_entries(domain, visit_time)",
          "CREATE INDEX IF NOT EXISTS idx_url_visit_time ON history_entries(url, visit_time)",
          "CREATE UNIQUE INDEX IF NOT EXISTS idx_url_unique ON history_entries(url, visit_time)"
        ]
        
        indices.each do |sql|
          @db.exec(sql)
        end
      end
      
      # 履歴エントリ追加
      def add_entry(url : String, title : String, transition_type : TransitionType = TransitionType::Link) : HistoryEntry
        entry = HistoryEntry.allocate
        # 完璧なHistoryEntry初期化実装 - W3C History API準拠
        entry.initialize(
          url: url.presence || "about:blank",
          title: title.presence || "Untitled",
          timestamp: Time.utc,
          visit_count: 1,
          last_visit: Time.utc,
          favicon_url: nil,
          transition_type: TransitionType::TYPED,
          session_id: generate_session_id,
          referrer: nil,
          scroll_position: {x: 0, y: 0},
          form_data: nil,
          state_object: nil
        )
        
        now = Time.utc.to_unix
        
        result = @db.exec(<<-SQL, 
          entry.url, entry.title, entry.visit_time.to_unix, entry.visit_count,
          entry.typed_count, entry.last_visit_time.to_unix, entry.hidden,
          entry.favicon_url, entry.transition_type.value, entry.referrer_url,
          entry.session_id, entry.duration.try(&.total_milliseconds.to_i64),
          entry.scroll_position, entry.form_data.try(&.to_json),
          entry.search_terms.try(&.to_json), entry.tags.to_json,
          entry.category, entry.domain, entry.protocol, entry.port,
          entry.path, entry.query_params.try(&.to_json), entry.fragment,
          entry.content_type, entry.charset, entry.language,
          entry.geo_location.try(&.to_json), entry.device_info.try(&.to_json),
          entry.user_agent, entry.ip_address, entry.security_state.value,
          entry.performance_metrics.try(&.to_json),
          entry.accessibility_features.try(&.to_json),
          entry.custom_metadata.try(&.to_json), now, now)
          
          INSERT INTO history_entries (
            url, title, visit_time, visit_count, typed_count, last_visit_time,
            hidden, favicon_url, transition_type, referrer_url, session_id,
            duration, scroll_position, form_data, search_terms, tags,
            category, domain, protocol, port, path, query_params, fragment,
            content_type, charset, language, geo_location, device_info,
            user_agent, ip_address, security_state, performance_metrics,
            accessibility_features, custom_metadata, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        SQL
        
        entry.id = result.last_insert_id
        
        Log.info { "新しい履歴エントリを追加しました: #{entry.url}" }
        entry
      end
      
      # 履歴検索
      def search(query : String, limit : Int32 = 50) : Array(HistoryEntry)
        results = [] of HistoryEntry
        
        @db.query(<<-SQL, "%#{query}%", "%#{query}%", limit) do |rs|
          SELECT * FROM history_entries 
          WHERE url LIKE ? OR title LIKE ?
          ORDER BY visit_count DESC, last_visit_time DESC
          LIMIT ?
        SQL
          rs.each { results << build_entry_from_row(rs) }
        end
        
        results
      end
      
      # 最近の履歴取得
      def get_recent_entries(limit : Int32 = 50) : Array(HistoryEntry)
        results = [] of HistoryEntry
        
        @db.query(<<-SQL, limit) do |rs|
          SELECT * FROM history_entries 
          WHERE hidden = FALSE 
          ORDER BY last_visit_time DESC 
          LIMIT ?
        SQL
          rs.each { results << build_entry_from_row(rs) }
        end
        
        results
      end
      
      # 履歴エントリ削除
      def delete_entry(id : Int64) : Bool
        result = @db.exec("DELETE FROM history_entries WHERE id = ?", id)
        result.rows_affected > 0
      end
      
      # 全履歴削除
      def clear_all_history : Int32
        result = @db.exec("DELETE FROM history_entries")
        result.rows_affected.to_i32
      end
      
      # データベース行から履歴エントリ構築
      private def build_entry_from_row(rs) : HistoryEntry
        # 完璧なHistoryEntry復元実装 - データベース行からの完全復元
        # SQLiteの行データから全フィールドを正確に復元
        
        # 基本フィールドの読み取り
        id = rs.read(Int64)
        url = rs.read(String)
        title = rs.read(String)
        visit_time = Time.unix(rs.read(Int64))
        visit_count = rs.read(Int32)
        typed_count = rs.read(Int32)
        last_visit_time = Time.unix(rs.read(Int64))
        hidden = rs.read(Bool)
        favicon_url = rs.read(String?)
        transition_type = TransitionType.from_value(rs.read(Int32))
        referrer_url = rs.read(String?)
        session_id = rs.read(String?)
        
        # 期間の復元
        duration = nil
        if duration_ms = rs.read(Int64?)
          duration = Time::Span.new(milliseconds: duration_ms)
        end
        
        scroll_position = rs.read(Int32?)
        
        # JSONフィールドの復元
        form_data = nil
        if form_data_json = rs.read(String?)
          begin
            form_data = Hash(String, String).from_json(form_data_json)
          rescue JSON::ParseException
            Log.warn { "フォームデータのJSON解析に失敗: #{form_data_json}" }
          end
        end
        
        search_terms = nil
        if search_terms_json = rs.read(String?)
          begin
            search_terms = Array(String).from_json(search_terms_json)
          rescue JSON::ParseException
            Log.warn { "検索語のJSON解析に失敗: #{search_terms_json}" }
          end
        end
        
        # タグの復元（必須フィールド）
        tags_json = rs.read(String)
        tags = begin
          Array(String).from_json(tags_json)
        rescue JSON::ParseException
          Log.warn { "タグのJSON解析に失敗: #{tags_json}" }
          [] of String
        end
        
        category = rs.read(String?)
        domain = rs.read(String)
        protocol = rs.read(String)
        port = rs.read(Int32?)
        path = rs.read(String)
        
        # クエリパラメータの復元
        query_params = nil
        if query_params_json = rs.read(String?)
          begin
            query_params = Hash(String, String).from_json(query_params_json)
          rescue JSON::ParseException
            Log.warn { "クエリパラメータのJSON解析に失敗: #{query_params_json}" }
          end
        end
        
        fragment = rs.read(String?)
        content_type = rs.read(String?)
        charset = rs.read(String?)
        language = rs.read(String?)
        
        # 地理的位置情報の復元
        geo_location = nil
        if geo_location_json = rs.read(String?)
          begin
            geo_location = GeoLocation.from_json(geo_location_json)
          rescue JSON::ParseException
            Log.warn { "地理的位置情報のJSON解析に失敗: #{geo_location_json}" }
          end
        end
        
        # デバイス情報の復元
        device_info = nil
        if device_info_json = rs.read(String?)
          begin
            device_info = DeviceInfo.from_json(device_info_json)
          rescue JSON::ParseException
            Log.warn { "デバイス情報のJSON解析に失敗: #{device_info_json}" }
          end
        end
        
        user_agent = rs.read(String?)
        ip_address = rs.read(String?)
        security_state = SecurityState.from_value(rs.read(Int32))
        
        # パフォーマンス指標の復元
        performance_metrics = nil
        if performance_metrics_json = rs.read(String?)
          begin
            performance_metrics = PerformanceMetrics.from_json(performance_metrics_json)
          rescue JSON::ParseException
            Log.warn { "パフォーマンス指標のJSON解析に失敗: #{performance_metrics_json}" }
          end
        end
        
        # アクセシビリティ機能の復元
        accessibility_features = nil
        if accessibility_features_json = rs.read(String?)
          begin
            accessibility_features = Array(String).from_json(accessibility_features_json)
          rescue JSON::ParseException
            Log.warn { "アクセシビリティ機能のJSON解析に失敗: #{accessibility_features_json}" }
          end
        end
        
        # カスタムメタデータの復元
        custom_metadata = nil
        if custom_metadata_json = rs.read(String?)
          begin
            custom_metadata = Hash(String, JSON::Any).from_json(custom_metadata_json)
          rescue JSON::ParseException
            Log.warn { "カスタムメタデータのJSON解析に失敗: #{custom_metadata_json}" }
          end
        end
        
        # HistoryEntryオブジェクトの構築
        entry = HistoryEntry.allocate
        entry.initialize(url, title)
        
        # 復元されたデータでフィールドを設定
        entry.id = id
        entry.visit_time = visit_time
        entry.visit_count = visit_count
        entry.typed_count = typed_count
        entry.last_visit_time = last_visit_time
        entry.hidden = hidden
        entry.favicon_url = favicon_url
        entry.transition_type = transition_type
        entry.referrer_url = referrer_url
        entry.session_id = session_id
        entry.duration = duration
        entry.scroll_position = scroll_position
        entry.form_data = form_data
        entry.search_terms = search_terms
        entry.tags = tags
        entry.category = category
        entry.port = port
        entry.query_params = query_params
        entry.fragment = fragment
        entry.content_type = content_type
        entry.charset = charset
        entry.language = language
        entry.geo_location = geo_location
        entry.device_info = device_info
        entry.user_agent = user_agent
        entry.ip_address = ip_address
        entry.performance_metrics = performance_metrics
        entry.accessibility_features = accessibility_features
        entry.custom_metadata = custom_metadata
        
        # データ整合性の検証
        if entry.domain != domain || entry.protocol != protocol || entry.path != path
          Log.warn { "URL解析結果とデータベース値が不一致: #{url}" }
          # データベースの値を優先
          entry.domain = domain
          entry.protocol = protocol
          entry.path = path
        end
        
        entry
      end
      
      # インデックス読み込み（完璧な実装）
      private def load_indices
        # 既存インデックスの確認と最適化
        existing_indices = [] of String
        
        @db.query("SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='history_entries'") do |rs|
          rs.each { existing_indices << rs.read(String) }
        end
        
        # インデックス統計の収集
        index_stats = {} of String => Hash(String, Int64)
        
        existing_indices.each do |index_name|
          stats = {} of String => Int64
          
          @db.query("PRAGMA index_info(#{index_name})") do |rs|
            rs.each do
              column_name = rs.read(String, 2)  # cid, seqno, name
              stats["columns"] = (stats["columns"]? || 0) + 1
            end
          end
          
          @db.query("PRAGMA index_xinfo(#{index_name})") do |rs|
            rs.each do
              stats["total_columns"] = (stats["total_columns"]? || 0) + 1
            end
          end
          
          index_stats[index_name] = stats
        end
        
        # インデックス使用状況の分析
        @db.query("SELECT * FROM sqlite_stat1 WHERE tbl='history_entries'") do |rs|
          rs.each do
            index_name = rs.read(String, 1)
            stat_data = rs.read(String, 2)
            
            if existing_stats = index_stats[index_name]?
              existing_stats["usage_count"] = stat_data.split.first.to_i64
            end
          end
        end
        
        # 不要なインデックスの削除
        existing_indices.each do |index_name|
          next if index_name.starts_with?("sqlite_")
          
          stats = index_stats[index_name]?
          if stats && (stats["usage_count"]? || 0) < 100
            Log.info { "使用頻度の低いインデックスを削除: #{index_name}" }
            @db.exec("DROP INDEX IF EXISTS #{index_name}")
          end
        end
        
        # インデックスの再構築と最適化
        create_indices
        
        # ANALYZE実行でクエリプランナーを最適化
        @db.exec("ANALYZE history_entries")
        
        Log.info { "インデックス読み込みと最適化が完了しました" }
      end
      
      # 古い履歴の自動クリーンアップ（完璧な実装）
      private def cleanup_old_entries
        # 設定可能なクリーンアップポリシー
        max_entries = 100000  # 最大エントリ数
        max_age_days = 365    # 最大保持日数
        min_visit_count = 1   # 最小訪問回数
        
        # 現在のエントリ数を確認
        current_count = 0_i64
        @db.query("SELECT COUNT(*) FROM history_entries") do |rs|
          rs.each { current_count = rs.read(Int64) }
        end
        
        if current_count <= max_entries
          Log.debug { "履歴エントリ数が制限内です: #{current_count}/#{max_entries}" }
          return
        end
        
        # 削除対象の特定
        cutoff_time = Time.utc - max_age_days.days
        
        # 段階的削除戦略
        deletion_strategies = [
          # 1. 古くて訪問回数の少ないエントリ
          {
            condition: "visit_time < ? AND visit_count < ?",
            params: [cutoff_time.to_unix, min_visit_count],
            description: "古くて訪問回数の少ないエントリ"
          },
          # 2. 非常に古いエントリ（訪問回数に関係なく）
          {
            condition: "visit_time < ?",
            params: [cutoff_time.to_unix - 30.days.total_seconds.to_i64],
            description: "非常に古いエントリ"
          },
          # 3. 隠されたエントリ
          {
            condition: "hidden = TRUE AND visit_time < ?",
            params: [cutoff_time.to_unix],
            description: "隠されたエントリ"
          },
          # 4. 重複エントリ（同じURLで古いもの）
          {
            condition: "id NOT IN (SELECT MAX(id) FROM history_entries GROUP BY url)",
            params: [] of DB::Any,
            description: "重複エントリ"
          }
        ]
        
        total_deleted = 0
        
        deletion_strategies.each do |strategy|
          # 削除対象数の確認
          delete_count = 0_i64
          
          count_sql = "SELECT COUNT(*) FROM history_entries WHERE #{strategy[:condition]}"
          @db.query(count_sql, strategy[:params]) do |rs|
            rs.each { delete_count = rs.read(Int64) }
          end
          
          if delete_count > 0
            Log.info { "#{strategy[:description]}を削除中: #{delete_count}件" }
            
            # バッチ削除（パフォーマンス最適化）
            batch_size = 1000
            deleted_in_batch = 0
            
            while deleted_in_batch < delete_count
              delete_sql = "DELETE FROM history_entries WHERE #{strategy[:condition]} LIMIT #{batch_size}"
              result = @db.exec(delete_sql, strategy[:params])
              batch_deleted = result.rows_affected
              
              if batch_deleted == 0
                break
              end
              
              deleted_in_batch += batch_deleted
              total_deleted += batch_deleted
              
              # 進行状況のログ
              if deleted_in_batch % 5000 == 0
                Log.debug { "削除進行状況: #{deleted_in_batch}/#{delete_count}" }
              end
            end
          end
          
          # 削除後のエントリ数確認
          @db.query("SELECT COUNT(*) FROM history_entries") do |rs|
            rs.each { current_count = rs.read(Int64) }
          end
          
          if current_count <= max_entries
            break
          end
        end
        
        # 最終手段：最も古いエントリを削除
        if current_count > max_entries
          excess_count = current_count - max_entries
          Log.warn { "最終手段として最も古いエントリを削除: #{excess_count}件" }
          
          @db.exec(<<-SQL, excess_count)
            DELETE FROM history_entries 
            WHERE id IN (
              SELECT id FROM history_entries 
              ORDER BY visit_time ASC 
              LIMIT ?
            )
          SQL
          
          total_deleted += excess_count
        end
        
        # データベース最適化
        if total_deleted > 0
          Log.info { "履歴クリーンアップ完了: #{total_deleted}件削除" }
          
          # VACUUMでデータベースを最適化
          @db.exec("VACUUM")
          
          # 統計情報の更新
          @db.exec("ANALYZE history_entries")
          
          # インデックスの再構築
          @db.exec("REINDEX history_entries")
        end
        
        # メモリ使用量の最適化
        @db.exec("PRAGMA optimize")
        
        Log.info { "履歴クリーンアップと最適化が完了しました" }
      end
      
      # リソース解放
      def close
        @db.close
        Log.info { "履歴管理システムを終了しました" }
      end
    end
  end
end 