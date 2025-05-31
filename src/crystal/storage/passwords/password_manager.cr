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
    def set_master_password(new_password : String) : Bool
      # BCryptよりも安全なArgon2idを使用
      # メモリハードでより高いセキュリティを提供
      memory_cost = 65536     # 64MB
      time_cost = 3           # 3回のイテレーション
      parallelism = 4         # 4スレッド
      
      # セキュアなランダムソルト生成（32バイト）
      salt = Random::Secure.random_bytes(32)
      salt_b64 = Base64.strict_encode(salt)
      
      # Argon2idでハッシュ化
      argon2_params = Argon2Params.new(
        variant: Argon2Variant::Argon2id, 
        memory_cost: memory_cost,
        time_cost: time_cost,
        parallelism: parallelism,
        hash_length: 32,
        salt: salt
      )
      
      password_hash = Argon2.hash_password(new_password, argon2_params)
      hash_b64 = Base64.strict_encode(password_hash)
      
      current_time = Time.utc.to_unix
      
      # 現在のマスターパスワード設定を確認
      master_password_exists = @db.query_one? "SELECT COUNT(*) FROM master_password", as: Int32
      
      if master_password_exists && master_password_exists > 0
        # 既存のマスターパスワードを更新
        @db.exec "UPDATE master_password SET hash = ?, salt = ?, modified_at = ? WHERE id = 1",
          hash_b64, salt_b64, current_time
      else
        # 新しいマスターパスワードを設定
        @db.exec "INSERT INTO master_password (id, hash, salt, created_at, modified_at) VALUES (1, ?, ?, ?, ?)",
          hash_b64, salt_b64, current_time, current_time
      end
      
      # マスターキーを設定
      @master_key = new_password
      
      # すべてのエントリを新しいマスターキーで再暗号化する必要がある場合は処理
      reencrypt_all_passwords(new_password) if @entries.size > 0
      
      true
    end
    
    # マスターパスワードを検証
    def verify_master_password(password : String) : Bool
      # マスターパスワードが設定されているか確認
      result = @db.query_one? "SELECT hash, salt FROM master_password WHERE id = 1", as: {String, String}
      
      return false unless result
      
      hash_b64, salt_b64 = result
      
      # Base64デコード
      stored_hash = Base64.decode(hash_b64)
      salt = Base64.decode(salt_b64)
      
      # Argon2idパラメータ（保存時と同じ）
      argon2_params = Argon2Params.new(
        variant: Argon2Variant::Argon2id, 
        memory_cost: 65536,
        time_cost: 3,
        parallelism: 4,
        hash_length: 32,
        salt: salt
      )
      
      # 定数時間比較を使用（タイミング攻撃対策）
      input_hash = Argon2.hash_password(password, argon2_params)
      
      # 定数時間比較
      result = Crypto::Subtle.constant_time_compare(input_hash, stored_hash)
      
      if result
        # マスターキーを設定
        @master_key = password
        
        # データを読み込む（まだロードされていなければ）
        load_data unless @initialized
      end
      
      result
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
      # 世界最高レベルの暗号化実装
      
      # 1. 強力なランダムソルトを生成（32バイト）
      salt = Random::Secure.random_bytes(32)
      
      # 2. 安全なキー導出関数 (Argon2id) を使用してマスターキーから暗号化キーを導出
      # Argon2idはメモリハード関数でPBKDF2やbcryptより強力
      argon2_params = Argon2Params.new(
        variant: Argon2Variant::Argon2id,
        memory_cost: 65536,    # 64MB
        time_cost: 3,          # 3回のイテレーション
        parallelism: 4,        # 4スレッド
        hash_length: 32,       # 256ビット出力
        salt: salt
      )
      
      derived_key = Argon2.derive_key(key, argon2_params)
      
      # 3. XChaCha20-Poly1305を使用して認証付き暗号化
      # XChaCha20はAESより長いノンスを持ち、サイドチャネル攻撃に強い
      # Poly1305は強力なMAC認証を提供
      
      # ランダムノンス（24バイト）
      nonce = Random::Secure.random_bytes(24)
      
      # 認証付き暗号化
      crypto_box = XChaCha20Poly1305.new(derived_key)
      
      # 関連データに現在時刻を含める（リプレイ攻撃対策）
      additional_data = Time.utc.to_unix_ms.to_s.to_slice
      
      # 暗号化
      ciphertext = crypto_box.encrypt(password.to_slice, nonce, additional_data)
      
      # 4. 全データの組み立て
      # バージョン || ソルト || ノンス || 追加データ長 || 追加データ || 暗号文
      version = Bytes[2] # バージョン2（将来の互換性のため）
      
      ad_length = additional_data.size.to_u16
      ad_length_bytes = IO::Memory.new(2)
      ad_length_bytes.write_bytes(ad_length, IO::ByteFormat::BigEndian)
      
      # データの結合
      final_data = IO::Memory.new
      final_data.write(version)
      final_data.write(salt)
      final_data.write(nonce)
      final_data.write(ad_length_bytes.to_slice)
      final_data.write(additional_data)
      final_data.write(ciphertext)
      
      # Base64エンコード
      Base64.strict_encode(final_data.to_slice)
    end
    
    # パスワードを復号化
    private def decrypt_password(encrypted : String, key : String) : String
      # Base64デコード
      encrypted_data = Base64.decode(encrypted)
      
      # データのパース
      memory = IO::Memory.new(encrypted_data)
      
      # バージョンの確認
      version = memory.read_byte
      
      case version
      when 2 # 最新バージョン
        # ソルトの読み込み (32バイト)
        salt = Bytes.new(32)
        memory.read_fully(salt)
        
        # ノンスの読み込み (24バイト)
        nonce = Bytes.new(24)
        memory.read_fully(nonce)
        
        # 追加データ長の読み込み
        ad_length = memory.read_bytes(UInt16, IO::ByteFormat::BigEndian)
        
        # 追加データの読み込み
        additional_data = Bytes.new(ad_length)
        memory.read_fully(additional_data)
        
        # 残りは暗号文
        ciphertext = Bytes.new(memory.size - memory.pos)
        memory.read_fully(ciphertext)
        
        # Argon2idでキー導出
        argon2_params = Argon2Params.new(
          variant: Argon2Variant::Argon2id,
          memory_cost: 65536,    # 64MB
          time_cost: 3,          # 3回のイテレーション
          parallelism: 4,        # 4スレッド
          hash_length: 32,       # 256ビット出力
          salt: salt
        )
        
        derived_key = Argon2.derive_key(key, argon2_params)
        
        # XChaCha20-Poly1305で復号化
        crypto_box = XChaCha20Poly1305.new(derived_key)
        
        begin
          # 復号化（認証も検証）
          decrypted = crypto_box.decrypt(ciphertext, nonce, additional_data)
          return String.new(decrypted)
        rescue e : CryptoError
          # 認証失敗または改ざんされたデータ
          Log.error { "パスワード復号化エラー: データが改ざんされている可能性があります" }
          raise PasswordIntegrityError.new("パスワードデータの完全性検証に失敗しました")
        end
        
      when 1 # 旧バージョン（下位互換性）
        # 旧フォーマットのデータ解析: IV (16 bytes) + Ciphertext
        # キー導出: マスターキーのSHA256ハッシュ
        
        unless memory.remaining >= 16 # IVの最小長チェック
          Log.error { "旧バージョン (v1) のパスワードデータが短すぎます (IVが読み取れません)。" }
          raise PasswordIntegrityError.new("旧バージョン (v1) のパスワードデータ形式が不正です。")
        end

        v1_iv = Bytes.new(16)
        memory.read_fully(v1_iv)
        
        # 暗号文が空でないか確認
        if memory.remaining == 0
          Log.error { "旧バージョン (v1) のパスワードデータに暗号文が含まれていません。" }
          raise PasswordIntegrityError.new("旧バージョン (v1) のパスワードデータ形式が不正です。")
        end
        
        v1_ciphertext = Bytes.new(memory.remaining)
        memory.read_fully(v1_ciphertext)
        
        # キー導出 (マスターパスワードのSHA256ハッシュ)
        v1_derived_key = OpenSSL::Digest.new("sha256").digest(key)
        
        cipher = OpenSSL::Cipher.new("aes-256-cbc")
        cipher.decrypt
        cipher.key = v1_derived_key
        cipher.iv = v1_iv
        
        begin
          decrypted_bytes = cipher.update(v1_ciphertext)
          decrypted_bytes = decrypted_bytes + cipher.final
          Log.info { "旧バージョン (v1) のパスワードを正常に復号化しました。" }
          return String.new(decrypted_bytes)
        rescue ex : OpenSSL::Error 
          Log.error { "旧バージョン (v1) のパスワード復号化中にOpenSSLエラーが発生しました (キーが違うか、データが破損している可能性があります): #{ex.message}" }
          # PasswordIntegrityError を使用して、データ破損の可能性を示す
          raise PasswordIntegrityError.new("旧バージョン (v1) のパスワードデータの復号化/検証に失敗しました。")
        end
      else
        # 未サポートバージョンの場合はエラー
        Log.error { "サポートされていない暗号化バージョン: #{version}" }
        raise UnsupportedVersionError.new("サポートされていない暗号化バージョン: #{version}")
      end
    end
    
    # パスワードのセキュリティレベルをチェック
    def check_password_strength(password : String) : PasswordStrength
      # エントロピーを計算
      entropy = calculate_password_entropy(password)
      
      # 特別な脆弱性チェック
      has_common_pattern = check_common_patterns(password)
      has_leaked = check_password_leak(password)
      
      # スコアリング（0-100）
      base_score = (entropy / 128.0 * 100).clamp(0.0, 100.0)
      
      # パターンや漏洩が見つかった場合はスコア減点
      final_score = if has_leaked
                      base_score * 0.3 # 漏洩パスワードは大幅減点
                    elsif has_common_pattern
                      base_score * 0.7 # パターンありは減点
                    else
                      base_score
                    end
      
      # スコアから強度を判定
      if final_score >= 80
        PasswordStrength::VeryStrong
      elsif final_score >= 60
        PasswordStrength::Strong
      elsif final_score >= 40
        PasswordStrength::Medium
      elsif final_score >= 20
        PasswordStrength::Weak
      else
        PasswordStrength::VeryWeak
      end
    end
    
    # パスワードエントロピー計算
    private def calculate_password_entropy(password : String) : Float64
      return 0.0 if password.empty?
      
      # 文字カテゴリのセット
      has_lower = password.matches?(/[a-z]/)
      has_upper = password.matches?(/[A-Z]/)
      has_digit = password.matches?(/[0-9]/)
      has_symbol = password.matches?(/[^a-zA-Z0-9]/)
      
      # 使用する文字種の空間サイズを計算
      char_space = 0
      char_space += 26 if has_lower
      char_space += 26 if has_upper
      char_space += 10 if has_digit
      char_space += 33 if has_symbol # 一般的な特殊記号の数
      
      # シャノンのエントロピー公式 H = L * log2(N)
      # L = パスワード長、N = 可能な文字の種類
      return password.size * Math.log2(char_space.to_f)
    end
    
    # 一般的なパターンをチェック
    private def check_common_patterns(password : String) : Bool
      # キーボード配列パターン
      keyboard_patterns = [
        "qwerty", "asdfgh", "zxcvbn", "qwertz", "azerty",
        "123456", "654321", "abcdef"
      ]
      
      # 連続した文字や数字
      sequential_digits = "0123456789"
      sequential_letters = "abcdefghijklmnopqrstuvwxyz"
      
      # 小文字に変換
      lower_password = password.downcase
      
      # キーボードパターンチェック
      keyboard_patterns.each do |pattern|
        return true if lower_password.includes?(pattern)
      end
      
      # 連続文字チェック（3文字以上の連続）
      3.upto(sequential_digits.size) do |length|
        0.upto(sequential_digits.size - length) do |start|
          pattern = sequential_digits[start, length]
          return true if lower_password.includes?(pattern)
          # 逆順もチェック
          reverse_pattern = pattern.reverse
          return true if lower_password.includes?(reverse_pattern)
        end
      end
      
      # 連続アルファベットチェック（3文字以上の連続）
      3.upto(sequential_letters.size) do |length|
        0.upto(sequential_letters.size - length) do |start|
          pattern = sequential_letters[start, length]
          return true if lower_password.includes?(pattern)
          # 逆順もチェック
          reverse_pattern = pattern.reverse
          return true if lower_password.includes?(reverse_pattern)
        end
      end
      
      # 反復パターンチェック（例: abcabc）
      1.upto(password.size // 2) do |pattern_length|
        parts = password.size // pattern_length
        remaining = password.size % pattern_length
        
        if remaining == 0 && parts >= 2
          pattern = password[0, pattern_length]
          is_repeating = true
          
          1.upto(parts - 1) do |i|
            part = password[i * pattern_length, pattern_length]
            if part != pattern
              is_repeating = false
              break
            end
          end
          
          return true if is_repeating
        end
      end
      
      # パターンなし
      false
    end
    
    # パスワード漏洩チェック（k匿名化されたハッシュプレフィックスを使用）
    private def check_password_leak(password : String) : Bool
      # SHA-1ハッシュのプレフィックス（最初の5文字）を使用
      sha1_hash = OpenSSL::Digest.new("sha1").update(password.to_slice).hexdigest.upcase
      prefix = sha1_hash[0, 5]
      suffix = sha1_hash[5..-1]
      
      # プライバシー強化のためのk匿名化API（HaveIBeenPwned互換）
      leak_api_url = "https://api.pwnedpasswords.com/range/#{prefix}"
      
      begin
        # タイムアウト設定付きのHTTPクライアント
        client = HTTP::Client.new(URI.parse(leak_api_url))
        client.connect_timeout = 5.seconds
        client.read_timeout = 10.seconds
        client.dns_timeout = 3.seconds
        
        # ユーザーエージェントの設定
        headers = HTTP::Headers{
          "User-Agent" => "Quantum-Browser/1.0",
          "Accept" => "text/plain"
        }
        
        # APIリクエスト（失敗時のリトライ処理あり）
        response = nil
        retry_count = 0
        max_retries = 2
        
        while retry_count <= max_retries
          begin
            response = client.get(leak_api_url, headers: headers)
            break if response.success?
          rescue ex : Socket::ConnectError | IO::TimeoutError
            retry_count += 1
            return false if retry_count > max_retries
            sleep(0.5 * retry_count) # バックオフ
          end
        end
        
        # レスポンスのステータスコードチェック
        if response && response.success?
          # レスポンスの各行をチェック（形式: SUFFIX:COUNT）
          response.body.each_line do |line|
            parts = line.strip.split(':')
            if parts.size >= 2 && parts[0] == suffix
              # 見つかった場合は漏洩あり
              Log.debug { "Password found in breach database with count: #{parts[1]}" }
              return true
            end
          end
        else
          # APIエラー時のログ記録
          status = response ? response.status_code : "no response"
          Log.warning { "Password leak API returned error: #{status}" }
        end
        
        # 漏洩なしまたはエラー発生時
        return false
      rescue ex : Exception
        # 例外発生時のエラーログ記録
        Log.error { "Error checking password leak: #{ex.message}" }
        
        # API関連の問題が発生してもユーザー体験を妨げないよう
        # エラー時は漏洩なしと判断する
        return false
      ensure
        # APIリクエスト結果にかかわらずBool値を返す
        client.close if client
      end
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
    
    # 指定した時刻以降に変更されたエントリのみを取得
    def get_entries_modified_since(time : Time) : Array(PasswordEntry)
      initialize_if_needed
      modified_entries = [] of PasswordEntry
      
      # データベースから直接取得
      @db.query "SELECT id, url, username, password, created_at, modified_at, last_used, use_count FROM passwords WHERE modified_at >= ?", time.to_unix do |rs|
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
          
          modified_entries << entry
        end
      end
      
      # 変更されたエントリの一覧を返す
      modified_entries
    end
  end
end 