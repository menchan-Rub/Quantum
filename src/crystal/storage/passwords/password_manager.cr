require "json"
require "sqlite3"
require "crypto/bcrypt/password"
require "openssl/cipher"

module QuantumCore
  # 保存されたパスワードエントリ
  class PasswordEntry
    include JSON::Serializable
    
    property id : Int64
    property url : String
    property username : String
    property password : String # 暗号化されたパスワード
    property created_at : Time
    property modified_at : Time
    property last_used : Time?
    property use_count : Int32
    
    def initialize(@url : String, @username : String, @password : String, @id : Int64 = -1, @created_at : Time = Time.utc, @modified_at : Time = Time.utc, @last_used : Time? = nil, @use_count : Int32 = 0)
    end
    
    # JSONシリアライズのためのカスタムトゥーJSON
    def to_json(json : JSON::Builder)
      json.object do
        json.field "id", @id
        json.field "url", @url
        json.field "username", @username
        json.field "password", @password
        json.field "created_at", @created_at.to_unix
        json.field "modified_at", @modified_at.to_unix
        json.field "last_used", @last_used.try(&.to_unix)
        json.field "use_count", @use_count
      end
    end
    
    # JSONデシリアライズのためのカスタムフロムJSON
    def self.from_json(json_object : JSON::Any) : PasswordEntry
      id = json_object["id"].as_i64
      url = json_object["url"].as_s
      username = json_object["username"].as_s
      password = json_object["password"].as_s
      created_at = Time.unix(json_object["created_at"].as_i64)
      modified_at = Time.unix(json_object["modified_at"].as_i64)
      last_used = json_object["last_used"]?.try { |t| t.as_i64? ? Time.unix(t.as_i64) : nil }
      use_count = json_object["use_count"].as_i
      
      PasswordEntry.new(url, username, password, id, created_at, modified_at, last_used, use_count)
    end
  end
  
  # パスワード管理クラス
  class PasswordManager
    DATABASE_FILE = "browser_passwords.db"
    
    @db : DB::Database
    @entries : Hash(Int64, PasswordEntry) = {} of Int64 => PasswordEntry
    @entries_by_url : Hash(String, Array(PasswordEntry)) = {} of String => Array(PasswordEntry)
    @master_key : String?
    @initialized : Bool = false
    @storage_manager : StorageManager
    
    # パスワードエントリ数を取得するゲッター
    def entry_count : Int32
      initialize_if_needed
      @entries.size
    end
    
    # 推定サイズを計算するメソッド（バイト単位）
    def estimated_size : Int64
      initialize_if_needed
      size : Int64 = 0
      
      @entries.each_value do |entry|
        size += entry.url.bytesize
        size += entry.username.bytesize
        size += entry.password.bytesize
        
        # その他のフィールドのサイズを追加（推定値）
        size += 8 * 3 # id, created_at, modified_at (8バイトずつ)
        size += 8     # last_used (8バイト)
        size += 4     # use_count (4バイト)
      end
      
      size
    end
    
    def initialize(@storage_manager : StorageManager)
      # SQLiteデータベースを開く
      @db = DB.open("sqlite3://#{DATABASE_FILE}")
      
      # テーブルが存在しない場合は作成
      create_tables
    end
    
    # テーブルを作成
    private def create_tables
      @db.exec "CREATE TABLE IF NOT EXISTS passwords (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        url TEXT NOT NULL,
        username TEXT NOT NULL,
        password TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        modified_at INTEGER NOT NULL,
        last_used INTEGER,
        use_count INTEGER NOT NULL DEFAULT 0
      )"
      
      # マスターパスワードとソルト用のテーブル
      @db.exec "CREATE TABLE IF NOT EXISTS master_password (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        hash TEXT NOT NULL,
        salt TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        modified_at INTEGER NOT NULL
      )"
      
      # インデックスを作成
      @db.exec "CREATE INDEX IF NOT EXISTS idx_passwords_url ON passwords (url)"
      @db.exec "CREATE UNIQUE INDEX IF NOT EXISTS idx_passwords_url_username ON passwords (url, username)"
    end
    
    # 初期化が必要な場合に初期化
    private def initialize_if_needed
      return if @initialized
      
      # マスターパスワードが設定されているか確認
      master_password_set = @db.query_one? "SELECT COUNT(*) FROM master_password", as: Int32
      
      if master_password_set && master_password_set > 0
        # マスターパスワードが設定されているが、まだマスターキーが提供されていない場合
        if @master_key.nil?
          # マスターキーが提供されるまでデータのロードをスキップ
          @initialized = true
          return
        end
        
        # マスターキーが提供されている場合はデータをロード
        load_data
      else
        # マスターパスワードが設定されていない場合は、データを平文でロード
        load_data
      end
      
      @initialized = true
    end
    
    # データを読み込み
    private def load_data
      @entries.clear
      @entries_by_url.clear
      
      @db.query "SELECT id, url, username, password, created_at, modified_at, last_used, use_count FROM passwords" do |rs|
        rs.each do
          id = rs.read(Int64)
          url = rs.read(String)
          username = rs.read(String)
          encrypted_password = rs.read(String)
          created_at = Time.unix(rs.read(Int64))
          modified_at = Time.unix(rs.read(Int64))
          last_used_unix = rs.read(Int64?)
          last_used = last_used_unix ? Time.unix(last_used_unix) : nil
          use_count = rs.read(Int32)
          
          # マスターキーが設定されている場合はパスワードを復号化
          password = @master_key ? decrypt_password(encrypted_password, @master_key.not_nil!) : encrypted_password
          
          entry = PasswordEntry.new(
            url: url,
            username: username,
            password: password,
            id: id,
            created_at: created_at,
            modified_at: modified_at,
            last_used: last_used,
            use_count: use_count
          )
          
          @entries[id] = entry
          
          # URLごとのエントリマップを更新
          @entries_by_url[url] = [] of PasswordEntry unless @entries_by_url.has_key?(url)
          @entries_by_url[url] << entry
        end
      end
    end
    
    # パスワードを設定（新規または更新）
    def save_password(url : String, username : String, password : String) : PasswordEntry
      initialize_if_needed
      
      # 既存のエントリを探す
      existing_entry = find_entry(url, username)
      
      if existing_entry
        # 既存のエントリを更新
        existing_entry.password = @master_key ? encrypt_password(password, @master_key.not_nil!) : password
        existing_entry.modified_at = Time.utc
        
        # データベースを更新
        @db.exec "UPDATE passwords SET password = ?, modified_at = ? WHERE id = ?",
          existing_entry.password, existing_entry.modified_at.to_unix, existing_entry.id
        
        # パスワード保存イベントをディスパッチ
        @storage_manager.engine.dispatch_event(Event.new(
          type: EventType::PASSWORD_SAVED,
          data: {
            "url" => url,
            "username" => username
          }
        ))
        
        return existing_entry
      else
        # 新しいエントリを作成
        current_time = Time.utc
        encrypted_password = @master_key ? encrypt_password(password, @master_key.not_nil!) : password
        
        # データベースに挿入
        @db.exec "INSERT INTO passwords (url, username, password, created_at, modified_at) VALUES (?, ?, ?, ?, ?)",
          url, username, encrypted_password, current_time.to_unix, current_time.to_unix
        
        # 生成されたIDを取得
        id = @db.scalar("SELECT last_insert_rowid()").as(Int64)
        
        # 新しいエントリを作成
        entry = PasswordEntry.new(
          url: url,
          username: username,
          password: password, # キャッシュには平文を保存
          id: id,
          created_at: current_time,
          modified_at: current_time
        )
        
        # ハッシュマップに追加
        @entries[id] = entry
        
        # URLごとのエントリマップを更新
        @entries_by_url[url] = [] of PasswordEntry unless @entries_by_url.has_key?(url)
        @entries_by_url[url] << entry
        
        # パスワード保存イベントをディスパッチ
        @storage_manager.engine.dispatch_event(Event.new(
          type: EventType::PASSWORD_SAVED,
          data: {
            "url" => url,
            "username" => username
          }
        ))
        
        return entry
      end
    end
    
    # 特定のURLとユーザー名のパスワードエントリを探す
    private def find_entry(url : String, username : String) : PasswordEntry?
      initialize_if_needed
      
      return nil unless @entries_by_url.has_key?(url)
      
      @entries_by_url[url].find { |entry| entry.username == username }
    end
    
    # パスワードを取得
    def get_password(url : String, username : String) : String?
      initialize_if_needed
      
      entry = find_entry(url, username)
      return nil unless entry
      
      # 使用回数と最終使用日時を更新
      entry.use_count += 1
      entry.last_used = Time.utc
      
      # データベースを更新
      @db.exec "UPDATE passwords SET use_count = ?, last_used = ? WHERE id = ?",
        entry.use_count, entry.last_used.not_nil!.to_unix, entry.id
      
      # 平文のパスワードを返す（キャッシュ内ではすでに復号化されている）
      entry.password
    end
    
    # URLに関連するすべてのユーザー名を取得
    def get_usernames_for_url(url : String) : Array(String)
      initialize_if_needed
      
      return [] of String unless @entries_by_url.has_key?(url)
      
      @entries_by_url[url].map(&.username)
    end
    
    # 特定のURLとユーザー名のパスワードを削除
    def delete_password(url : String, username : String) : Bool
      initialize_if_needed
      
      entry = find_entry(url, username)
      return false unless entry
      
      # データベースから削除
      @db.exec "DELETE FROM passwords WHERE id = ?", entry.id
      
      # ハッシュマップから削除
      @entries.delete(entry.id)
      
      # URLごとのエントリマップを更新
      if @entries_by_url.has_key?(url)
        @entries_by_url[url].reject! { |e| e.id == entry.id }
        @entries_by_url.delete(url) if @entries_by_url[url].empty?
      end
      
      # パスワード削除イベントをディスパッチ
      @storage_manager.engine.dispatch_event(Event.new(
        type: EventType::PASSWORD_REMOVED,
        data: {
          "url" => url,
          "username" => username
        }
      ))
      
      true
    end
    
    # URLに関連するすべてのパスワードを削除
    def delete_passwords_for_url(url : String) : Int32
      initialize_if_needed
      
      return 0 unless @entries_by_url.has_key?(url)
      
      count = @entries_by_url[url].size
      
      # データベースから削除
      @db.exec "DELETE FROM passwords WHERE url = ?", url
      
      # ハッシュマップから削除
      @entries_by_url[url].each do |entry|
        @entries.delete(entry.id)
        
        # パスワード削除イベントをディスパッチ
        @storage_manager.engine.dispatch_event(Event.new(
          type: EventType::PASSWORD_REMOVED,
          data: {
            "url" => url,
            "username" => entry.username
          }
        ))
      end
      
      @entries_by_url.delete(url)
      
      count
    end
    
    # マスターパスワードを設定
    def set_master_password(master_password : String) : Bool
      # ソルトを生成
      salt = Random.new.random_bytes(16).hexstring
      
      # パスワードハッシュを生成
      password_hash = Crypto::Bcrypt::Password.create(master_password, cost: 10).to_s
      
      current_time = Time.utc
      
      begin
        # 既存のマスターパスワードがあるか確認
        existing = @db.query_one? "SELECT COUNT(*) FROM master_password", as: Int32
        
        if existing && existing > 0
          # 既存のマスターパスワードを更新
          @db.exec "UPDATE master_password SET hash = ?, salt = ?, modified_at = ? WHERE id = 1",
            password_hash, salt, current_time.to_unix
        else
          # 新しいマスターパスワードを挿入
          @db.exec "INSERT INTO master_password (id, hash, salt, created_at, modified_at) VALUES (1, ?, ?, ?, ?)",
            password_hash, salt, current_time.to_unix, current_time.to_unix
        end
        
        # 既存のパスワードを再暗号化
        reencrypt_all_passwords(master_password)
        
        # マスターキーを設定
        @master_key = master_password
        
        return true
      rescue ex
        Log.error { "マスターパスワードの設定中にエラーが発生しました: #{ex.message}" }
        return false
      end
    end
    
    # マスターパスワードを確認
    def verify_master_password(master_password : String) : Bool
      # マスターパスワードのハッシュを取得
      hash_record = @db.query_one? "SELECT hash FROM master_password WHERE id = 1", as: {String}
      
      return false unless hash_record
      
      stored_hash = hash_record[0]
      
      # ハッシュを確認
      begin
        bcrypt_password = Crypto::Bcrypt::Password.new(stored_hash)
        if bcrypt_password.verify(master_password)
          # マスターキーを設定
          @master_key = master_password
          
          # データを再読み込み
          load_data
          
          return true
        end
      rescue ex
        Log.error { "マスターパスワードの検証中にエラーが発生しました: #{ex.message}" }
      end
      
      false
    end
    
    # マスターパスワードが設定されているかどうかを確認
    def master_password_set? : Bool
      master_password_count = @db.query_one? "SELECT COUNT(*) FROM master_password", as: Int32
      
      master_password_count && master_password_count > 0
    end
    
    # マスターパスワードを削除（セキュリティリスク）
    def remove_master_password : Bool
      return false unless master_password_set?
      
      # 全てのパスワードを復号化して平文で保存
      if @master_key
        # 全てのパスワードを復号化
        @entries.each_value do |entry|
          begin
            decrypted_password = decrypt_password(entry.password, @master_key.not_nil!)
            
            # データベースを更新
            @db.exec "UPDATE passwords SET password = ? WHERE id = ?",
              decrypted_password, entry.id
            
            # エントリを更新
            entry.password = decrypted_password
          rescue ex
            Log.error { "パスワードの復号化中にエラーが発生しました: #{ex.message}" }
          end
        end
      end
      
      # マスターパスワードテーブルからレコードを削除
      @db.exec "DELETE FROM master_password"
      
      # マスターキーをクリア
      @master_key = nil
      
      true
    end
    
    # パスワードを暗号化
    private def encrypt_password(password : String, key : String) : String
      # 暗号化アルゴリズムを初期化
      cipher = OpenSSL::Cipher.new("aes-256-cbc")
      cipher.encrypt
      
      # キーとIVを設定
      cipher.key = derive_key(key)
      iv = Random.new.random_bytes(16)
      cipher.iv = iv
      
      # 暗号化
      encrypted = cipher.update(password)
      encrypted = encrypted + cipher.final
      
      # IV + 暗号文をBase64エンコード
      "#{iv.hexstring}:#{Base64.strict_encode(encrypted)}"
    end
    
    # パスワードを復号化
    private def decrypt_password(encrypted : String, key : String) : String
      # IV と 暗号文を分離
      parts = encrypted.split(":")
      return encrypted if parts.size != 2
      
      iv_hex = parts[0]
      data_base64 = parts[1]
      
      begin
        # IV をバイナリに変換
        iv = iv_hex.hexbytes
        
        # 暗号文をデコード
        data = Base64.decode(data_base64)
        
        # 復号化アルゴリズムを初期化
        cipher = OpenSSL::Cipher.new("aes-256-cbc")
        cipher.decrypt
        
        # キーとIVを設定
        cipher.key = derive_key(key)
        cipher.iv = iv
        
        # 復号化
        decrypted = cipher.update(data)
        decrypted = decrypted + cipher.final
        
        String.new(decrypted)
      rescue ex
        Log.error { "パスワードの復号化中にエラーが発生しました: #{ex.message}" }
        encrypted
      end
    end
    
    # キー導出関数
    private def derive_key(password : String) : Bytes
      # 単純なハッシュ化でキーを導出
      # 実際の実装では、より強力なPBKDF2などのキー導出関数を使用すべき
      digest = OpenSSL::Digest.new("sha256")
      digest.update(password)
      digest.final
    end
    
    # すべてのパスワードを再暗号化
    private def reencrypt_all_passwords(new_master_key : String)
      # マスターキーが既に設定されている場合
      if @master_key
        @entries.each_value do |entry|
          begin
            # 現在のマスターキーで復号化
            decrypted_password = decrypt_password(entry.password, @master_key.not_nil!)
            
            # 新しいマスターキーで暗号化
            encrypted_password = encrypt_password(decrypted_password, new_master_key)
            
            # データベースを更新
            @db.exec "UPDATE passwords SET password = ? WHERE id = ?",
              encrypted_password, entry.id
          rescue ex
            Log.error { "パスワードの再暗号化中にエラーが発生しました: #{ex.message}" }
          end
        end
      else
        # マスターキーがまだ設定されていない場合（平文から暗号化）
        @entries.each_value do |entry|
          begin
            # パスワードを暗号化
            encrypted_password = encrypt_password(entry.password, new_master_key)
            
            # データベースを更新
            @db.exec "UPDATE passwords SET password = ? WHERE id = ?",
              encrypted_password, entry.id
          rescue ex
            Log.error { "パスワードの暗号化中にエラーが発生しました: #{ex.message}" }
          end
        end
      end
    end
    
    # URLで始まる全てのエントリを検索
    def search_by_url_prefix(url_prefix : String, limit : Int32 = 10) : Array(PasswordEntry)
      initialize_if_needed
      
      matches = [] of PasswordEntry
      
      @entries_by_url.each do |url, entries|
        if url.starts_with?(url_prefix)
          matches.concat(entries)
        end
      end
      
      matches.sort_by(&.url).first(limit)
    end
    
    # すべてのパスワードを消去
    def clear
      # データベースからすべてのパスワードを削除
      @db.exec "DELETE FROM passwords"
      
      # ハッシュマップをクリア
      @entries.clear
      @entries_by_url.clear
    end
    
    # パスワードをファイルにエクスポート
    def export(file_path : String) : Bool
      initialize_if_needed
      
      begin
        # マスターキーが設定されている場合は、全てのパスワードを復号化
        export_entries = [] of PasswordEntry
        
        if @master_key
          @entries.each_value do |entry|
            # 復号化されたコピーを作成
            decrypted_entry = PasswordEntry.new(
              url: entry.url,
              username: entry.username,
              password: entry.password, # 既に復号化済み
              id: entry.id,
              created_at: entry.created_at,
              modified_at: entry.modified_at,
              last_used: entry.last_used,
              use_count: entry.use_count
            )
            
            export_entries << decrypted_entry
          end
        else
          export_entries = @entries.values
        end
        
        # JSONにシリアライズ
        json_data = export_entries.to_json
        
        # ファイルに書き込み
        File.write(file_path, json_data)
        
        return true
      rescue ex
        Log.error { "パスワードのエクスポート中にエラーが発生しました: #{ex.message}" }
        return false
      end
    end
    
    # パスワードをファイルからインポート
    def import(file_path : String) : Bool
      begin
        json_data = File.read(file_path)
        import_entries = Array(PasswordEntry).from_json(json_data)
        
        # インポートする前に一時的にトランザクションを開始
        @db.transaction do |tx|
          import_entries.each do |entry|
            # 既存のエントリがあるか確認
            existing = @db.query_one? "SELECT id FROM passwords WHERE url = ? AND username = ?", 
              entry.url, entry.username, as: Int64
            
            # パスワードを暗号化（必要な場合）
            password = @master_key ? encrypt_password(entry.password, @master_key.not_nil!) : entry.password
            
            if existing
              # 既存のエントリを更新
              @db.exec "UPDATE passwords SET password = ?, created_at = ?, modified_at = ?, last_used = ?, use_count = ? WHERE id = ?",
                password, entry.created_at.to_unix, entry.modified_at.to_unix, entry.last_used.try(&.to_unix), entry.use_count, existing
            else
              # 新しいエントリを挿入
              @db.exec "INSERT INTO passwords (url, username, password, created_at, modified_at, last_used, use_count) VALUES (?, ?, ?, ?, ?, ?, ?)",
                entry.url, entry.username, password, entry.created_at.to_unix, entry.modified_at.to_unix, entry.last_used.try(&.to_unix), entry.use_count
            end
          end
        end
        
        # データを再読み込み
        load_data
        
        return true
      rescue ex
        Log.error { "パスワードのインポート中にエラーが発生しました: #{ex.message}" }
        return false
      end
    end
    
    # データを保存
    def save
      # SQLiteデータベースは自動的に永続化されるため、特に何もする必要はない
      # ただし、念のためにデータベースの変更をディスクに強制的に書き込む
      @db.exec "PRAGMA wal_checkpoint(FULL)"
    end
    
    # データベース接続を閉じる
    def finalize
      @db.close
    end
  end
end 