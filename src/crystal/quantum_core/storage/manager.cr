require "db"
require "sqlite3"
require "log"
require "file_utils"
require "json"
require "uri"

require "../../events/event_dispatcher"
require "../../utils/logger"

module QuantumCore
  module Storage
    Log = ::Log.for(self)

    # ブラウザデータ（履歴、Cookie、設定など）の永続的ストレージを管理します。
    # 構造化データにはSQLiteを使用します。
    class Manager
      @db : DB::Database?
      @db_path : String
      @event_dispatcher : QuantumEvents::EventDispatcher
      @is_initialized : Bool
      @storage_mutex : Mutex
      @logger : ::Log::Context

      # マイグレーション用のデータベーススキーマバージョン
      private DB_VERSION = 1

      # EventDispatcherを注入、profile_pathは外部から決定
      def initialize(profile_path : String, @event_dispatcher : QuantumEvents::EventDispatcher)
        # プロファイルディレクトリの存在を確認
        begin
            FileUtils.mkdir_p(profile_path) unless Dir.exists?(profile_path)
        rescue ex
            Log.fatal(exception: ex) { "プロファイルディレクトリの作成に失敗: #{profile_path}" }
            raise InitializationError.new("プロファイルディレクトリを作成または使用できません: #{profile_path}")
        end

        @db_path = File.join(profile_path, "browser_storage.sqlite3")
        @logger = Log.for("Storage<#{profile_path}>")
        @logger.level = ::Log::Severity.parse(ENV.fetch("LOG_LEVEL", "INFO"))
        @db = nil
        @is_initialized = false
        @storage_mutex = Mutex.new

        @logger.info { "ストレージマネージャーを初期化: #{@db_path}" }
        # 実際のDB初期化は別メソッドに委譲
        # `setup_storage`は初期化後に外部から呼び出す必要があります。
      end

      # --- 公開API --- #

      # データベースに接続し、必要に応じてスキーマを設定します。
      # ストレージ操作の前に呼び出す必要があります。
      def setup_storage : Bool
        # ミューテックスを必要以上に長く保持しないよう注意
        return @is_initialized if @is_initialized

        @storage_mutex.synchronize do
          # ミューテックス内で初期化状態を再確認
          return @is_initialized if @is_initialized

          begin
            @logger.info { "ストレージデータベースをセットアップ: #{@db_path}" }
            @db = DB.open("sqlite3://#{@db_path}")
            # 同時実行性向上のためにWrite-Ahead Loggingを有効化
            @db.not_nil!.exec("PRAGMA journal_mode=WAL;")
            @logger.debug { "データベース接続を開きました（WAL有効）" }

            # スキーマの確認と必要に応じたマイグレーション
            check_and_migrate_schema

            @is_initialized = true
            @logger.info { "ストレージセットアップ完了（スキーマバージョン: #{DB_VERSION}）" }
            # ストレージ準備完了イベントの発行
            @event_dispatcher.dispatch(QuantumEvents::Event.new(QuantumEvents::EventType::STORAGE_READY))
            true
          rescue ex : DB::ConnectionError
            @logger.fatal(exception: ex) { "データベースの接続に失敗: #{@db_path}" }
            @db = nil
            @is_initialized = false
            false
          rescue ex
            @logger.fatal(exception: ex) { "ストレージセットアップ中に予期せぬエラーが発生" }
            @db.try(&.close)
            @db = nil
            @is_initialized = false
            false
          end
        end
      end

      # データベース接続を適切に閉じます。
      def close
        @storage_mutex.synchronize do
            if @db
                @logger.info { "ストレージデータベースを閉じています" }
                @db.try(&.close)
                @db = nil
                @is_initialized = false
            else
                @logger.debug { "ストレージデータベースは既に閉じられているか、初期化されていません" }
            end
        end
      end

      # --- 履歴操作 --- #

      def add_history_entry(url : String, title : String?) : Bool
        success = false
        begin
            # URL形式を検証
            uri = URI.parse(url)

            ensure_initialized do |db|
                timestamp = Time.utc.to_unix
                db.exec("INSERT INTO history (url, title, visit_time) VALUES (?, ?, ?)",
                    url, title, timestamp)
                @logger.debug { "履歴エントリを追加: #{url} (タイトル: #{title || "なし"})" }
                success = true
            end
        rescue ex : InitializationError
            @logger.error { "履歴エントリの追加に失敗: ストレージが初期化されていません" }
        rescue ex : URI::Error
            @logger.warn { "履歴エントリの追加に失敗: 無効なURL形式 '#{url}'" }
        rescue ex : DB::Error
            @logger.error(exception: ex) { "URL: #{url} の履歴エントリ追加中にデータベースエラーが発生" }
        rescue ex
            @logger.error(exception: ex) { "URL: #{url} の履歴エントリ追加中に予期せぬエラーが発生" }
        end

        # 成功時に特定のイベントを発行
        if success
          @event_dispatcher.dispatch(QuantumEvents::Event.new(
            QuantumEvents::EventType::STORAGE_HISTORY_ADDED,
            QuantumEvents::HistoryAddedData.new(url, title || "")
          ))
        end
        success
      end

      # 履歴エントリを取得します。オプションでクエリと時間範囲でフィルタリングできます。
      # 履歴エントリを表すハッシュの配列を返します。
      def get_history(query : String? = nil, start_time : Time? = nil, end_time : Time? = nil, limit : Int32 = 100) : Array(Hash(String, DB::Any)) | Nil
        results = [] of Hash(String, DB::Any)
        begin
            ensure_initialized do |db|
                sql = String::Builder.new
                sql << "SELECT url, title, visit_time FROM history"
                args = [] of DB::Any
                conditions = [] of String

                if q = query
                    conditions << "(url LIKE ? OR title LIKE ?)"
                    args << "%#{q}%"
                    args << "%#{q}%"
                end
                if st = start_time
                    conditions << "visit_time >= ?"
                    args << st.to_unix
                end
                if et = end_time
                    conditions << "visit_time <= ?"
                    args << et.to_unix
                end

                sql << " WHERE #{conditions.join(" AND ")}" if conditions.any?
                sql << " ORDER BY visit_time DESC"
                # 制限値が正の値であることを確認
                sql << " LIMIT ?"
                args << Math.max(1, limit)

                query_string = sql.to_s
                @logger.debug { "履歴クエリを実行: #{query_string} パラメータ: #{args}" }
                db.query_all(query_string, args: args, as: {url: String, title: String?, visit_time: Int64}) do |row|
                  results << {
                    "url"        => row[:url],
                    "title"      => row[:title]?, # nilの場合の処理を確保
                    "visit_time" => Time.unix(row[:visit_time]), # Unix時間からTimeオブジェクトに変換
                  }
                end
                @logger.debug { "#{results.size}件の履歴エントリを取得しました。" }
            end
            results # 成功時に結果を返す
        rescue ex : InitializationError
            @logger.error { "履歴の取得に失敗: ストレージが初期化されていません。" }
            nil # 初期化エラー時はnilを返す
        rescue ex : DB::Error
            @logger.error(exception: ex) { "履歴取得中にデータベースエラーが発生しました。" }
            nil # DBエラー時はnilを返す
        rescue ex
            @logger.error(exception: ex) { "履歴取得中に予期せぬエラーが発生しました。" }
            nil # その他のエラー時はnilを返す
        end
        # 取得操作ではイベント発行は不要
      end

      # 履歴エントリを削除します。オプションでURLや時間範囲でフィルタリングできます。
      # 成功時はtrue、失敗時はfalseを返します。
      def delete_history(url : String? = nil, start_time : Time? = nil, end_time : Time? = nil) : Bool
        success = false
        deleted_count = 0
        begin
            ensure_initialized do |db|
                sql = String::Builder.new
                sql << "DELETE FROM history"
                args = [] of DB::Any
                conditions = [] of String

                if u = url
                    conditions << "url = ?"
                    args << u
                end
                if st = start_time
                    conditions << "visit_time >= ?"
                    args << st.to_unix
                end
                if et = end_time
                    conditions << "visit_time <= ?"
                    args << et.to_unix
                end

                # 全削除の場合は明示的な確認が必要
                if conditions.empty?
                   @logger.warn { "全履歴エントリの削除を試みています。全削除には明示的にclear_all_historyを使用してください。" }
                   # 安全のため、誤って全削除することを防止
                   # 別途`clear_all_history`メソッドを追加可能
                   return false
                end

                sql << " WHERE #{conditions.join(" AND ")}"

                query_string = sql.to_s
                @logger.debug { "履歴削除クエリを実行: #{query_string} パラメータ: #{args}" }
                result = db.exec(query_string, args: args)
                deleted_count = result.rows_affected
                @logger.info { "#{deleted_count}件の履歴エントリを削除しました。" }
                success = true
            end
        rescue ex : InitializationError
            @logger.error { "履歴の削除に失敗: ストレージが初期化されていません。" }
        rescue ex : DB::Error
            @logger.error(exception: ex) { "履歴エントリの削除中にデータベースエラーが発生しました。" }
        rescue ex
            @logger.error(exception: ex) { "履歴エントリの削除中に予期せぬエラーが発生しました。" }
        end

        # 行が削除された場合は特定のイベントを発行
        if success && deleted_count > 0
            @event_dispatcher.dispatch(QuantumEvents::Event.new(
                QuantumEvents::EventType::STORAGE_HISTORY_CLEARED
                # 特定のデータは不要
            ))
        end
        success
      end

      # 全ての履歴を削除します
      # 成功時はtrue、失敗時はfalseを返します
      def clear_all_history : Bool
        success = false
        begin
            ensure_initialized do |db|
                @logger.warn { "全履歴エントリを削除します" }
                result = db.exec("DELETE FROM history")
                deleted_count = result.rows_affected
                @logger.info { "#{deleted_count}件の履歴エントリを完全に削除しました" }
                success = true
            end
        rescue ex : InitializationError
            @logger.error { "全履歴の削除に失敗: ストレージが初期化されていません" }
        rescue ex : DB::Error
            @logger.error(exception: ex) { "全履歴エントリの削除中にデータベースエラーが発生しました" }
        rescue ex
            @logger.error(exception: ex) { "全履歴エントリの削除中に予期せぬエラーが発生しました" }
        end

        # 成功時にイベントを発行
        if success
            @event_dispatcher.dispatch(QuantumEvents::Event.new(
                QuantumEvents::EventType::STORAGE_HISTORY_CLEARED
            ))
        end
        success
      end

      # --- Cookie操作 --- #

      # Cookieを追加または更新します
      def set_cookie(host : String, path : String, name : String, value : String, 
                    expiry : Time? = nil, secure : Bool = false, http_only : Bool = false) : Bool
        success = false
        begin
            ensure_initialized do |db|
                now = Time.utc.to_unix
                expiry_unix = expiry.try(&.to_unix)
                
                db.exec(
                    "INSERT OR REPLACE INTO cookies (host, path, name, value, expiry, is_secure, is_http_only, creation_time, last_access_time) 
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    host, path, name, value, expiry_unix, secure ? 1 : 0, http_only ? 1 : 0, now, now
                )
                
                @logger.debug { "Cookieを設定: #{host}#{path} #{name}=#{value} (有効期限: #{expiry || "セッション限り"})" }
                success = true
            end
        rescue ex : InitializationError
            @logger.error { "Cookieの設定に失敗: ストレージが初期化されていません" }
        rescue ex : DB::Error
            @logger.error(exception: ex) { "Cookie設定中にデータベースエラーが発生: #{host}#{path} #{name}" }
        rescue ex
            @logger.error(exception: ex) { "Cookie設定中に予期せぬエラーが発生: #{host}#{path} #{name}" }
        end

        # 成功時にイベントを発行
        if success
            @event_dispatcher.dispatch(QuantumEvents::Event.new(
                QuantumEvents::EventType::STORAGE_COOKIE_ADDED,
                QuantumEvents::CookieAddedData.new(host, path, name)
            ))
        end
        success
      end

      # 指定されたホスト、パス、名前に一致するCookieを取得します
      def get_cookie(host : String, path : String, name : String) : Hash(String, DB::Any)? 
        begin
            ensure_initialized do |db|
                result = db.query_one?(
                    "SELECT host, path, name, value, expiry, is_secure, is_http_only, creation_time, last_access_time 
                    FROM cookies WHERE host = ? AND path = ? AND name = ?",
                    host, path, name,
                    as: {String, String, String, String, Int64?, Int32, Int32, Int64, Int64}
                )
                
                if result
                    host, path, name, value, expiry, is_secure, is_http_only, creation_time, last_access_time = result
                    
                    # 最終アクセス時間を更新
                    now = Time.utc.to_unix
                    db.exec("UPDATE cookies SET last_access_time = ? WHERE host = ? AND path = ? AND name = ?",
                        now, host, path, name)
                    
                    @logger.debug { "Cookieを取得: #{host}#{path} #{name}" }
                    
                    return {
                        "host" => host,
                        "path" => path,
                        "name" => name,
                        "value" => value,
                        "expiry" => expiry ? Time.unix(expiry.not_nil!) : nil,
                        "secure" => is_secure == 1,
                        "http_only" => is_http_only == 1,
                        "creation_time" => Time.unix(creation_time),
                        "last_access_time" => Time.unix(now)
                    }
                end
                
                @logger.debug { "Cookie未検出: #{host}#{path} #{name}" }
                nil
            end
        rescue ex : InitializationError
            @logger.error { "Cookieの取得に失敗: ストレージが初期化されていません" }
            nil
        rescue ex : DB::Error
            @logger.error(exception: ex) { "Cookie取得中にデータベースエラーが発生: #{host}#{path} #{name}" }
            nil
        rescue ex
            @logger.error(exception: ex) { "Cookie取得中に予期せぬエラーが発生: #{host}#{path} #{name}" }
            nil
        end
      end

      # 指定されたホストのCookieを全て取得します
      # パスの階層を考慮して適切なCookieを返します
      def get_cookies_for_host(host : String) : Array(Hash(String, DB::Any))
        results = [] of Hash(String, DB::Any)
        begin
            ensure_initialized do |db|
                # ホストに完全一致するCookieを取得
                db.query_all(
                    "SELECT host, path, name, value, expiry, is_secure, is_http_only, creation_time, last_access_time 
                    FROM cookies WHERE host = ? OR host = ? OR ? LIKE '%' || host",
                    host, host.sub(/^www\./, ""), host,
                    as: {String, String, String, String, Int64?, Int32, Int32, Int64, Int64}
                ) do |row|
                    host, path, name, value, expiry, is_secure, is_http_only, creation_time, last_access_time = row
                    
                    # 有効期限切れのCookieをスキップ
                    if expiry && Time.unix(expiry.not_nil!) < Time.utc
                        next
                    end
                    
                    results << {
                        "host" => host,
                        "path" => path,
                        "name" => name,
                        "value" => value,
                        "expiry" => expiry ? Time.unix(expiry.not_nil!) : nil,
                        "secure" => is_secure == 1,
                        "http_only" => is_http_only == 1,
                        "creation_time" => Time.unix(creation_time),
                        "last_access_time" => Time.unix(last_access_time)
                    }
                end
                
                # 最終アクセス時間を一括更新
                if !results.empty?
                    now = Time.utc.to_unix
                    host_patterns = [host, host.sub(/^www\./, "")]
                    placeholders = host_patterns.map { "?" }.join(", ")
                    db.exec("UPDATE cookies SET last_access_time = ? WHERE host IN (#{placeholders}) OR ? LIKE '%' || host",
                        now, *host_patterns, host)
                    
                    # 最終アクセス時間を結果にも反映
                    results.each do |cookie|
                        cookie["last_access_time"] = Time.unix(now)
                    end
                end
                
                @logger.debug { "ホスト #{host} に対して #{results.size} 件のCookieを取得" }
            end
        rescue ex : InitializationError
            @logger.error { "ホストのCookie取得に失敗: ストレージが初期化されていません" }
        rescue ex : DB::Error
            @logger.error(exception: ex) { "ホスト #{host} のCookie取得中にデータベースエラーが発生" }
        rescue ex
            @logger.error(exception: ex) { "ホスト #{host} のCookie取得中に予期せぬエラーが発生" }
        end
        results
      end

      # 指定されたCookieを削除します
      def delete_cookie(host : String, path : String, name : String) : Bool
        success = false
        begin
            ensure_initialized do |db|
                result = db.exec("DELETE FROM cookies WHERE host = ? AND path = ? AND name = ?",
                    host, path, name)
                deleted = result.rows_affected > 0
                
                if deleted
                    @logger.debug { "Cookieを削除: #{host}#{path} #{name}" }
                    success = true
                else
                    @logger.debug { "削除対象のCookieが見つかりません: #{host}#{path} #{name}" }
                end
            end
        rescue ex : InitializationError
            @logger.error { "Cookieの削除に失敗: ストレージが初期化されていません" }
        rescue ex : DB::Error
            @logger.error(exception: ex) { "Cookie削除中にデータベースエラーが発生: #{host}#{path} #{name}" }
        rescue ex
            @logger.error(exception: ex) { "Cookie削除中に予期せぬエラーが発生: #{host}#{path} #{name}" }
        end

        # 成功時にイベントを発行
        if success
            @event_dispatcher.dispatch(QuantumEvents::Event.new(
                QuantumEvents::EventType::STORAGE_COOKIE_REMOVED,
                QuantumEvents::CookieRemovedData.new(host, path, name)
            ))
        end
        success
      end

      # 有効期限切れのCookieを削除します
      def cleanup_expired_cookies : Int32
        deleted_count = 0
        begin
            ensure_initialized do |db|
                now = Time.utc.to_unix
                result = db.exec("DELETE FROM cookies WHERE expiry IS NOT NULL AND expiry < ?", now)
                deleted_count = result.rows_affected.to_i
                
                if deleted_count > 0
                    @logger.info { "#{deleted_count}件の有効期限切れCookieを削除しました" }
                    
                    # 多数のCookieが削除された場合のみイベント発行
                    @event_dispatcher.dispatch(QuantumEvents::Event.new(
                        QuantumEvents::EventType::STORAGE_COOKIES_CLEANED
                    ))
                end
            end
        rescue ex : InitializationError
            @logger.error { "有効期限切れCookieの削除に失敗: ストレージが初期化されていません" }
        rescue ex : DB::Error
            @logger.error(exception: ex) { "有効期限切れCookie削除中にデータベースエラーが発生" }
        rescue ex
            @logger.error(exception: ex) { "有効期限切れCookie削除中に予期せぬエラーが発生" }
        end
        deleted_count
      end

      # --- 設定操作 --- #

      # 設定値を保存します（JSON形式で格納）。
      # 成功時はtrue、失敗時はfalseを返します。
      def save_setting(key : String, value : JSON::Any) : Bool
        success = false
        begin
          ensure_initialized do |db|
            json_value = value.to_json # JSON文字列として保存
            db.exec("INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)", key, json_value)
            @logger.debug { "設定を保存: #{key} = #{json_value}" }
            success = true
          end
        rescue ex : InitializationError
          @logger.error { "設定 '#{key}' の保存に失敗: ストレージが初期化されていません" }
        rescue ex : JSON::GeneratorError
            @logger.error(exception: ex) { "設定 '#{key}' のJSON変換に失敗しました"}
        rescue ex : DB::Error
          @logger.error(exception: ex) { "設定保存中にデータベースエラーが発生: #{key}" }
        rescue ex
          @logger.error(exception: ex) { "設定保存中に予期せぬエラーが発生: #{key}" }
        end

        # 成功時に設定変更イベントを発行
        if success
          @event_dispatcher.dispatch(QuantumEvents::Event.new(
            QuantumEvents::EventType::APP_CONFIG_CHANGED
            # 機密データに注意: QuantumEvents::AppConfigChangedData.new(key: key, value: value)
          ))
        end
        success
      end

      # 設定値を取得します。見つからない場合やエラー時はデフォルト値を返します。
      def get_setting(key : String, default_value : JSON::Any = JSON::Any.new(nil)) : JSON::Any
        result_value = default_value
        begin
            ensure_initialized do |db|
                result = db.query_one?("SELECT value FROM settings WHERE key = ?", key, as: String)
                if result
                    begin
                        result_value = JSON.parse(result)
                        @logger.debug { "設定を取得: #{key} = #{result}" }
                    rescue ex : JSON::ParseException
                        @logger.error(exception: ex) { "設定 '#{key}' の保存されたJSONの解析に失敗しました。値: #{result}。デフォルト値を返します。" }
                        result_value = default_value # 解析失敗時はデフォルト値を返す
                    end
                else
                    @logger.debug { "設定 '#{key}' が見つかりません。デフォルト値を返します。" }
                    result_value = default_value
                end
            end
        rescue ex : InitializationError
            @logger.error { "設定 '#{key}' の取得に失敗: ストレージが初期化されていません。デフォルト値を返します。" }
        rescue ex : DB::Error
            @logger.error(exception: ex) { "設定取得中にデータベースエラーが発生: #{key}。デフォルト値を返します。" }
        rescue ex
            @logger.error(exception: ex) { "設定取得中に予期せぬエラーが発生: #{key}。デフォルト値を返します。" }
        end
        # 取得操作ではイベント発行は不要
        result_value
      end

      # 設定キーを削除します。
      # キーが存在し削除された場合はtrue、それ以外やエラー時はfalseを返します。
      def delete_setting(key : String) : Bool
        success = false
        deleted = false
        begin
          ensure_initialized do |db|
            result = db.exec("DELETE FROM settings WHERE key = ?", key)
            deleted = result.rows_affected > 0
            success = true # DB操作自体は成功
            if deleted
                @logger.debug { "設定を削除: #{key}" }
            else
                @logger.debug { "存在しない設定の削除を試みました: #{key}" }
            end
          end
        rescue ex : InitializationError
          @logger.error { "設定 '#{key}' の削除に失敗: ストレージが初期化されていません" }
        rescue ex : DB::Error
          @logger.error(exception: ex) { "設定削除中にデータベースエラーが発生: #{key}" }
        rescue ex
          @logger.error(exception: ex) { "設定削除中に予期せぬエラーが発生: #{key}" }
        end

        # 削除成功時に設定変更イベントを発行
        if success && deleted
          @event_dispatcher.dispatch(QuantumEvents::Event.new(
            QuantumEvents::EventType::APP_CONFIG_CHANGED
            # オプションでデータを追加: QuantumEvents::AppConfigChangedData.new(key: key, deleted: true)
          ))
        end
        success && deleted # 削除された場合のみtrueを返す
      end

      # --- プライベートヘルパーメソッド --- #

      # データベースが初期化されていることを確認してからブロックを実行します。
      # セットアップが呼び出されていないか失敗した場合はInitializationErrorを発生させます。
      private def ensure_initialized(&block)
        unless @is_initialized && @db
          raise InitializationError.new("ストレージマネージャーは使用前に正常にセットアップされている必要があります。")
        end
        # DBアクセスのスレッドセーフティを確保するためにミューテックス内でブロックを実行
        @storage_mutex.synchronize do
          yield @db.not_nil!
        end
      end

      # --- スキーマ管理 --- #

      private def check_and_migrate_schema
        # このメソッドは@storage_mutex内で呼び出されることを前提としています
        db = @db.not_nil!

        # メタデータテーブルの確認
        db.exec("CREATE TABLE IF NOT EXISTS metadata (key TEXT PRIMARY KEY, value TEXT)")
        @logger.debug { "メタデータテーブルを確認しました。" }

        # 現在のバージョンを取得
        current_version = 0
        begin
          result = db.query_one?("SELECT value FROM metadata WHERE key = 'db_version'", as: String)
          current_version = result.to_i if result
        rescue ex : DB::Error # テーブル/行がまだ存在しない場合を適切に処理
            @logger.warn(exception: ex) { "DBバージョンを読み取れませんでした。バージョン0と仮定します。" }
            current_version = 0
        end

        @logger.info { "現在のDBスキーマバージョン: #{current_version}。必要なバージョン: #{DB_VERSION}" }

        if current_version < DB_VERSION
          @logger.info { "データベーススキーマをバージョン#{current_version}からバージョン#{DB_VERSION}に移行しています..." }
          # 移行にトランザクションを使用
          db.transaction do
            (current_version + 1).upto(DB_VERSION) do |version|
                migrate_to_version(version) # dbを明示的に渡す
                # トランザクション内でメタデータテーブルのバージョンを更新
                db.exec("INSERT OR REPLACE INTO metadata (key, value) VALUES (?, ?)", "db_version", version.to_s)
                @logger.info { "スキーマをバージョン#{version}に正常に移行しました。" }
            end
          end
          @logger.info { "データベース移行が完了しました。" }
        elsif current_version > DB_VERSION
          @logger.error { "データベースバージョン(#{current_version})がサポートされているバージョン(#{DB_VERSION})より新しいです。続行できません。" }
          raise MigrationError.new("データベースバージョンがサポートされているバージョンより新しいです。")
        else
          @logger.info { "データベーススキーマは最新です（バージョン#{DB_VERSION}）。" }
          # 移行が不要でも（新規DBの場合）テーブルが存在することを確認
          ensure_tables_exist(db)
        end
      rescue ex
        @logger.error(exception: ex) { "スキーマ確認/移行プロセス中にエラーが発生しました。"}
        # セットアップ失敗を示すために例外を再発生
        raise ex
      end

      # 特定のバージョンの移行を適用します。トランザクション内で呼び出されることを前提としています。
      private def migrate_to_version(version : Int32)
        # このメソッドはensure_initializedブロック内またはdbが非nilであることが保証されている場所で呼び出される必要があります
        db = @db.not_nil!
        @logger.info { "バージョン#{version}への移行を適用しています..." }
        begin
            case version
            when 1
                # 初期テーブルの作成
                db.exec(<<-SQL)
                    CREATE TABLE history (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        url TEXT NOT NULL,
                        title TEXT,
                        visit_time INTEGER NOT NULL -- Unix時間（秒）
                    );
                SQL
                db.exec("CREATE INDEX idx_history_url ON history (url);")
                db.exec("CREATE INDEX idx_history_visit_time ON history (visit_time);")

                db.exec(<<-SQL)
                    CREATE TABLE cookies (
                        id INTEGER PRIMARY KEY AUTOINCREMENT,
                        host TEXT NOT NULL,
                        path TEXT NOT NULL,
                        name TEXT NOT NULL,
                        value TEXT,
                        expiry INTEGER, -- Unix時間（秒）、セッションCookieの場合はNULL
                        is_secure INTEGER NOT NULL DEFAULT 0, -- ブール値（0または1）
                        is_http_only INTEGER NOT NULL DEFAULT 0, -- ブール値（0または1）
                        creation_time INTEGER NOT NULL,
                        last_access_time INTEGER NOT NULL,
                        UNIQUE (host, path, name)
                    );
                SQL
                db.exec("CREATE INDEX idx_cookies_host_path ON cookies (host, path);")

                db.exec(<<-SQL)
                    CREATE TABLE settings (
                        key TEXT PRIMARY KEY,
                        value TEXT -- 複雑な値はJSON文字列として保存
                    );
                SQL
                @logger.info { "バージョン1の移行を適用しました（履歴、Cookie、設定テーブルを作成）。" }
            # 将来のバージョンのケースを追加（例：when 2）
            else
                raise MigrationError.new("サポートされていない移行バージョン: #{version}")
            end
        rescue ex # 移行SQL実行中のエラーをキャッチ
            @logger.error(exception: ex) { "バージョン#{version}の移行SQLの実行中にエラーが発生しました。" }
            raise ex # 移行失敗を示すために再スロー（トランザクションをロールバック）
        end
      end


      # 基本テーブルが存在することを確認します。スキーマが既に最新だが
      # 新規DBのためにテーブルを確保する必要がある場合に呼び出されます。DB接続が存在することを前提としています。
      private def ensure_tables_exist(db : DB::Database)
          begin
            # 安全のためにIF NOT EXISTSを使用
            db.exec("CREATE TABLE IF NOT EXISTS history (id INTEGER PRIMARY KEY AUTOINCREMENT, url TEXT NOT NULL, title TEXT, visit_time INTEGER NOT NULL);")
            db.exec("CREATE INDEX IF NOT EXISTS idx_history_url ON history (url);")
            db.exec("CREATE INDEX IF NOT EXISTS idx_history_visit_time ON history (visit_time);")

            db.exec(<<-SQL)
                CREATE TABLE IF NOT EXISTS cookies (
                    id INTEGER PRIMARY KEY AUTOINCREMENT, host TEXT NOT NULL, path TEXT NOT NULL, name TEXT NOT NULL, value TEXT,
                    expiry INTEGER, is_secure INTEGER NOT NULL DEFAULT 0, is_http_only INTEGER NOT NULL DEFAULT 0,
                    creation_time INTEGER NOT NULL, last_access_time INTEGER NOT NULL, UNIQUE (host, path, name)
                );
            SQL
            db.exec("CREATE INDEX IF NOT EXISTS idx_cookies_host_path ON cookies (host, path);")

            db.exec("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT);")
            @logger.debug { "Ensured core tables (history, cookies, settings) exist." }
          rescue ex : DB::Error
              @logger.error(exception: ex) { "Database error ensuring core tables exist." }
              raise ex # Signal setup failure
          rescue ex
              @logger.error(exception: ex) { "Unexpected error ensuring core tables exist."}
              raise ex
          end
      end

      # --- Custom Error Types --- #
      class InitializationError < Exception
      end

      class MigrationError < Exception
      end

    end # End Class Manager
  end # End Module Storage
end # End Module QuantumCore