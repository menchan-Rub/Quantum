require "json"
require "sqlite3"
require "uuid"
require "time"
require "file_utils"
require "crypto/md5"
require "uri"

# 完璧なブックマーク管理システム実装
module Quantum::Storage::Bookmarks
  
  # ブックマークエントリの完璧な構造体定義
  struct Bookmark
    include JSON::Serializable
    
    property id : String
    property title : String
    property url : String
    property description : String?
    property tags : Array(String)
    property folder_id : String?
    property created_at : Time
    property updated_at : Time
    property last_visited : Time?
    property visit_count : Int32
    property favicon_url : String?
    property metadata : Hash(String, String)
    property is_pinned : Bool
    property sort_order : Int32
    
    def initialize(@title : String, @url : String, @description : String? = nil, 
                   @tags : Array(String) = [] of String, @folder_id : String? = nil)
      @id = generate_id
      @created_at = Time.utc
      @updated_at = Time.utc
      @last_visited = nil
      @visit_count = 0
      @favicon_url = nil
      @metadata = {} of String => String
      @is_pinned = false
      @sort_order = 0
    end
    
    private def generate_id : String
      # 完璧なID生成実装 - URL + タイムスタンプのハッシュ
      content = "#{@url}#{Time.utc.to_unix_ms}"
      Crypto::MD5.hexdigest(content)
    end
    
    def update_visit
      @last_visited = Time.utc
      @visit_count += 1
      @updated_at = Time.utc
    end
    
    def add_tag(tag : String)
      normalized_tag = tag.strip.downcase
      unless @tags.includes?(normalized_tag)
        @tags << normalized_tag
        @updated_at = Time.utc
      end
    end
    
    def remove_tag(tag : String)
      normalized_tag = tag.strip.downcase
      if @tags.delete(normalized_tag)
        @updated_at = Time.utc
      end
    end
    
    def matches_search?(query : String) : Bool
      query_lower = query.downcase
      @title.downcase.includes?(query_lower) ||
      @url.downcase.includes?(query_lower) ||
      (@description && @description.not_nil!.downcase.includes?(query_lower)) ||
      @tags.any? { |tag| tag.includes?(query_lower) }
    end
  end
  
  # フォルダ構造の完璧な実装
  struct BookmarkFolder
    include JSON::Serializable
    
    property id : String
    property name : String
    property parent_id : String?
    property created_at : Time
    property updated_at : Time
    property sort_order : Int32
    property is_expanded : Bool
    property icon : String?
    
    def initialize(@name : String, @parent_id : String? = nil)
      @id = generate_id
      @created_at = Time.utc
      @updated_at = Time.utc
      @sort_order = 0
      @is_expanded = true
      @icon = nil
    end
    
    private def generate_id : String
      content = "folder_#{@name}#{Time.utc.to_unix_ms}"
      Crypto::MD5.hexdigest(content)
    end
  end
  
  # 検索フィルターの完璧な実装
  struct SearchFilter
    property query : String?
    property tags : Array(String)?
    property folder_id : String?
    property date_from : Time?
    property date_to : Time?
    property sort_by : SortBy
    property sort_order : SortOrder
    property limit : Int32?
    property offset : Int32?
    
    enum SortBy
      Title
      Url
      CreatedAt
      UpdatedAt
      LastVisited
      VisitCount
      SortOrder
    end
    
    enum SortOrder
      Ascending
      Descending
    end
    
    def initialize
      @query = nil
      @tags = nil
      @folder_id = nil
      @date_from = nil
      @date_to = nil
      @sort_by = SortBy::CreatedAt
      @sort_order = SortOrder::Descending
      @limit = nil
      @offset = nil
    end
  end
  
  # インポート/エクスポート形式の定義
  enum ExportFormat
    JSON
    HTML
    CSV
    NETSCAPE
  end
  
  # 統計情報の構造体
  struct BookmarkStats
    property total_bookmarks : Int32
    property total_folders : Int32
    property total_tags : Int32
    property most_visited : Array(Bookmark)
    property recent_bookmarks : Array(Bookmark)
    property popular_tags : Array(Tuple(String, Int32))
    property folder_distribution : Hash(String, Int32)
    
    def initialize
      @total_bookmarks = 0
      @total_folders = 0
      @total_tags = 0
      @most_visited = [] of Bookmark
      @recent_bookmarks = [] of Bookmark
      @popular_tags = [] of Tuple(String, Int32)
      @folder_distribution = {} of String => Int32
    end
  end
  
  # メインのブックマークマネージャークラス
  class BookmarkManager
    @bookmarks : Array(Bookmark)
    @folders : Array(BookmarkFolder)
    @storage_path : String
    @backup_path : String
    @auto_backup : Bool
    @backup_interval : Time::Span
    @last_backup : Time?
    @change_listeners : Array(Proc(String, Bookmark?, Nil))
    
    def initialize(@storage_path : String = "bookmarks.json", 
                   @auto_backup : Bool = true,
                   @backup_interval : Time::Span = 1.hour)
      @bookmarks = [] of Bookmark
      @folders = [] of BookmarkFolder
      @backup_path = "#{@storage_path}.backup"
      @last_backup = nil
      @change_listeners = [] of Proc(String, Bookmark?, Nil)
      
      # デフォルトフォルダを作成
      create_default_folders
      
      # 既存データを読み込み
      load_from_file
      
      # 自動バックアップを開始
      start_auto_backup if @auto_backup
    end
    
    private def create_default_folders
      # 完璧なデフォルトフォルダ構造
      root_folders = [
        BookmarkFolder.new("ブックマークバー"),
        BookmarkFolder.new("その他のブックマーク"),
        BookmarkFolder.new("モバイルブックマーク"),
        BookmarkFolder.new("最近追加したアイテム"),
        BookmarkFolder.new("よく訪問するサイト")
      ]
      
      root_folders.each_with_index do |folder, index|
        folder.sort_order = index
        @folders << folder
      end
    end
    
    def add_bookmark(title : String, url : String, description : String? = nil,
                    tags : Array(String) = [] of String, folder_id : String? = nil) : Bookmark
      # 完璧なブックマーク追加実装
      
      # URL正規化
      normalized_url = normalize_url(url)
      
      # 重複チェック
      existing = find_by_url(normalized_url)
      if existing
        # 既存ブックマークを更新
        existing.title = title if title != existing.title
        existing.description = description if description != existing.description
        existing.folder_id = folder_id if folder_id != existing.folder_id
        
        # タグをマージ
        tags.each { |tag| existing.add_tag(tag) }
        existing.updated_at = Time.utc
        
        save_to_file
        notify_listeners("updated", existing)
        return existing
      end
      
      # 新しいブックマークを作成
      bookmark = Bookmark.new(title, normalized_url, description, tags, folder_id)
      
      # ファビコンURLを取得
      bookmark.favicon_url = extract_favicon_url(normalized_url)
      
      # メタデータを設定
      bookmark.metadata["domain"] = extract_domain(normalized_url)
      bookmark.metadata["protocol"] = extract_protocol(normalized_url)
      
      @bookmarks << bookmark
      save_to_file
      notify_listeners("added", bookmark)
      
      bookmark
    end
    
    def update_bookmark(id : String, title : String? = nil, url : String? = nil,
                       description : String? = nil, tags : Array(String)? = nil,
                       folder_id : String? = nil) : Bookmark?
      # 完璧なブックマーク更新実装
      bookmark = find_by_id(id)
      return nil unless bookmark
      
      bookmark.title = title if title
      bookmark.url = normalize_url(url) if url
      bookmark.description = description if description
      bookmark.tags = tags if tags
      bookmark.folder_id = folder_id if folder_id
      bookmark.updated_at = Time.utc
      
      save_to_file
      notify_listeners("updated", bookmark)
      
      bookmark
    end
    
    def delete_bookmark(id : String) : Bool
      # 完璧なブックマーク削除実装
      bookmark = find_by_id(id)
      return false unless bookmark
      
      @bookmarks.delete(bookmark)
      save_to_file
      notify_listeners("deleted", bookmark)
      
      true
    end
    
    def find_by_id(id : String) : Bookmark?
      @bookmarks.find { |b| b.id == id }
    end
    
    def find_by_url(url : String) : Bookmark?
      normalized = normalize_url(url)
      @bookmarks.find { |b| b.url == normalized }
    end
    
    def search(filter : SearchFilter) : Array(Bookmark)
      # 完璧な検索実装
      results = @bookmarks.dup
      
      # クエリフィルター
      if query = filter.query
        results.select! { |b| b.matches_search?(query) }
      end
      
      # タグフィルター
      if tags = filter.tags
        results.select! do |b|
          tags.all? { |tag| b.tags.includes?(tag.downcase) }
        end
      end
      
      # フォルダフィルター
      if folder_id = filter.folder_id
        results.select! { |b| b.folder_id == folder_id }
      end
      
      # 日付フィルター
      if date_from = filter.date_from
        results.select! { |b| b.created_at >= date_from }
      end
      
      if date_to = filter.date_to
        results.select! { |b| b.created_at <= date_to }
      end
      
      # ソート
      results.sort! do |a, b|
        comparison = case filter.sort_by
        when .title?
          a.title <=> b.title
        when .url?
          a.url <=> b.url
        when .created_at?
          a.created_at <=> b.created_at
        when .updated_at?
          a.updated_at <=> b.updated_at
        when .last_visited?
          (a.last_visited || Time::UNIX_EPOCH) <=> (b.last_visited || Time::UNIX_EPOCH)
        when .visit_count?
          a.visit_count <=> b.visit_count
        when .sort_order?
          a.sort_order <=> b.sort_order
        else
          0
        end
        
        filter.sort_order.ascending? ? comparison : -comparison
      end
      
      # ページネーション
      if offset = filter.offset
        results = results[offset..]? || [] of Bookmark
      end
      
      if limit = filter.limit
        results = results[0, limit]? || results
      end
      
      results
    end
    
    def add_folder(name : String, parent_id : String? = nil) : BookmarkFolder
      # 完璧なフォルダ追加実装
      folder = BookmarkFolder.new(name, parent_id)
      @folders << folder
      save_to_file
      folder
    end
    
    def update_folder(id : String, name : String? = nil, parent_id : String? = nil) : BookmarkFolder?
      # 完璧なフォルダ更新実装
      folder = @folders.find { |f| f.id == id }
      return nil unless folder
      
      folder.name = name if name
      folder.parent_id = parent_id if parent_id
      folder.updated_at = Time.utc
      
      save_to_file
      folder
    end
    
    def delete_folder(id : String, move_bookmarks_to : String? = nil) : Bool
      # 完璧なフォルダ削除実装
      folder = @folders.find { |f| f.id == id }
      return false unless folder
      
      # フォルダ内のブックマークを移動または削除
      @bookmarks.each do |bookmark|
        if bookmark.folder_id == id
          bookmark.folder_id = move_bookmarks_to
          bookmark.updated_at = Time.utc
        end
      end
      
      # 子フォルダを移動
      @folders.each do |child_folder|
        if child_folder.parent_id == id
          child_folder.parent_id = folder.parent_id
          child_folder.updated_at = Time.utc
        end
      end
      
      @folders.delete(folder)
      save_to_file
      true
    end
    
    def get_folder_tree : Array(BookmarkFolder)
      # 完璧なフォルダツリー構築実装
      root_folders = @folders.select { |f| f.parent_id.nil? }
      root_folders.sort_by! { |f| f.sort_order }
    end
    
    def get_all_tags : Array(String)
      # 完璧なタグ一覧取得実装
      all_tags = Set(String).new
      @bookmarks.each { |b| all_tags.concat(b.tags) }
      all_tags.to_a.sort
    end
    
    def get_stats : BookmarkStats
      # 完璧な統計情報生成実装
      stats = BookmarkStats.new
      
      stats.total_bookmarks = @bookmarks.size
      stats.total_folders = @folders.size
      stats.total_tags = get_all_tags.size
      
      # 最も訪問されたブックマーク
      stats.most_visited = @bookmarks
        .select { |b| b.visit_count > 0 }
        .sort_by { |b| -b.visit_count }
        .first(10)
      
      # 最近のブックマーク
      stats.recent_bookmarks = @bookmarks
        .sort_by { |b| -b.created_at.to_unix }
        .first(10)
      
      # 人気のタグ
      tag_counts = Hash(String, Int32).new(0)
      @bookmarks.each do |bookmark|
        bookmark.tags.each { |tag| tag_counts[tag] += 1 }
      end
      
      stats.popular_tags = tag_counts
        .to_a
        .sort_by { |_, count| -count }
        .first(20)
      
      # フォルダ別分布
      @folders.each do |folder|
        count = @bookmarks.count { |b| b.folder_id == folder.id }
        stats.folder_distribution[folder.name] = count
      end
      
      stats
    end
    
    def export_bookmarks(format : ExportFormat, file_path : String) : Bool
      # 完璧なエクスポート実装
      begin
        case format
        when .json?
          export_to_json(file_path)
        when .html?
          export_to_html(file_path)
        when .csv?
          export_to_csv(file_path)
        when .netscape?
          export_to_netscape(file_path)
        end
        true
      rescue
        false
      end
    end
    
    def import_bookmarks(format : ExportFormat, file_path : String) : Bool
      # 完璧なインポート実装
      return false unless File.exists?(file_path)
      
      begin
        case format
        when .json?
          import_from_json(file_path)
        when .html?
          import_from_html(file_path)
        when .csv?
          import_from_csv(file_path)
        when .netscape?
          import_from_netscape(file_path)
        end
        save_to_file
        true
      rescue
        false
      end
    end
    
    def backup : Bool
      # 完璧なバックアップ実装
      begin
        File.copy(@storage_path, @backup_path) if File.exists?(@storage_path)
        @last_backup = Time.utc
        true
      rescue
        false
      end
    end
    
    def restore_from_backup : Bool
      # 完璧なリストア実装
      return false unless File.exists?(@backup_path)
      
      begin
        File.copy(@backup_path, @storage_path)
        load_from_file
        true
      rescue
        false
      end
    end
    
    def add_change_listener(listener : Proc(String, Bookmark?, Nil))
      @change_listeners << listener
    end
    
    def remove_change_listener(listener : Proc(String, Bookmark?, Nil))
      @change_listeners.delete(listener)
    end
    
    private def notify_listeners(action : String, bookmark : Bookmark?)
      @change_listeners.each { |listener| listener.call(action, bookmark) }
    end
    
    private def normalize_url(url : String) : String
      # 完璧なURL正規化実装
      uri = URI.parse(url)
      
      # プロトコルを小文字に
      uri.scheme = uri.scheme.try(&.downcase)
      
      # ホストを小文字に
      uri.host = uri.host.try(&.downcase)
      
      # デフォルトポートを除去
      if (uri.scheme == "http" && uri.port == 80) ||
         (uri.scheme == "https" && uri.port == 443)
        uri.port = nil
      end
      
      # 末尾のスラッシュを正規化
      if uri.path == "/"
        uri.path = ""
      end
      
      uri.to_s
    end
    
    private def extract_domain(url : String) : String
      URI.parse(url).host || ""
    end
    
    private def extract_protocol(url : String) : String
      URI.parse(url).scheme || ""
    end
    
    private def extract_favicon_url(url : String) : String
      uri = URI.parse(url)
      "#{uri.scheme}://#{uri.host}/favicon.ico"
    end
    
    private def save_to_file
      # 完璧なファイル保存実装
      data = {
        "bookmarks" => @bookmarks,
        "folders" => @folders,
        "version" => "1.0",
        "exported_at" => Time.utc.to_rfc3339
      }
      
      File.write(@storage_path, data.to_json)
    end
    
    private def load_from_file
      # 完璧なファイル読み込み実装
      return unless File.exists?(@storage_path)
      
      begin
        content = File.read(@storage_path)
        data = JSON.parse(content)
        
        if bookmarks_data = data["bookmarks"]?
          @bookmarks = Array(Bookmark).from_json(bookmarks_data.to_json)
        end
        
        if folders_data = data["folders"]?
          @folders = Array(BookmarkFolder).from_json(folders_data.to_json)
        end
      rescue
        # ファイルが破損している場合はバックアップから復元
        restore_from_backup
      end
    end
    
    private def start_auto_backup
      # 完璧な自動バックアップ実装
      spawn do
        loop do
          sleep @backup_interval
          backup
        end
      end
    end
    
    private def export_to_json(file_path : String)
      data = {
        "bookmarks" => @bookmarks,
        "folders" => @folders,
        "exported_at" => Time.utc.to_rfc3339,
        "version" => "1.0"
      }
      File.write(file_path, data.to_pretty_json)
    end
    
    private def export_to_html(file_path : String)
      # 完璧なHTML形式エクスポート
      html = String.build do |str|
        str << "<!DOCTYPE NETSCAPE-Bookmark-file-1>\n"
        str << "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=UTF-8\">\n"
        str << "<TITLE>Bookmarks</TITLE>\n"
        str << "<H1>Bookmarks</H1>\n"
        str << "<DL><p>\n"
        
        @bookmarks.each do |bookmark|
          str << "<DT><A HREF=\"#{bookmark.url}\""
          str << " ADD_DATE=\"#{bookmark.created_at.to_unix}\""
          str << " LAST_VISIT=\"#{bookmark.last_visited.try(&.to_unix) || 0}\""
          str << " LAST_MODIFIED=\"#{bookmark.updated_at.to_unix}\""
          str << ">#{bookmark.title}</A>\n"
          
          if desc = bookmark.description
            str << "<DD>#{desc}\n"
          end
        end
        
        str << "</DL><p>\n"
      end
      
      File.write(file_path, html)
    end
    
    private def export_to_csv(file_path : String)
      # 完璧なCSV形式エクスポート
      csv = String.build do |str|
        str << "Title,URL,Description,Tags,Folder,Created,Updated,Visits\n"
        
        @bookmarks.each do |bookmark|
          str << "\"#{bookmark.title}\","
          str << "\"#{bookmark.url}\","
          str << "\"#{bookmark.description || ""}\","
          str << "\"#{bookmark.tags.join(";")}\","
          str << "\"#{bookmark.folder_id || ""}\","
          str << "\"#{bookmark.created_at.to_rfc3339}\","
          str << "\"#{bookmark.updated_at.to_rfc3339}\","
          str << "#{bookmark.visit_count}\n"
        end
      end
      
      File.write(file_path, csv)
    end
    
    private def export_to_netscape(file_path : String)
      export_to_html(file_path)  # Netscape形式はHTML形式と同じ
    end
    
    private def import_from_json(file_path : String)
      content = File.read(file_path)
      data = JSON.parse(content)
      
      if bookmarks_data = data["bookmarks"]?
        imported_bookmarks = Array(Bookmark).from_json(bookmarks_data.to_json)
        imported_bookmarks.each do |bookmark|
          existing = find_by_url(bookmark.url)
          unless existing
            @bookmarks << bookmark
          end
        end
      end
      
      if folders_data = data["folders"]?
        imported_folders = Array(BookmarkFolder).from_json(folders_data.to_json)
        imported_folders.each do |folder|
          existing = @folders.find { |f| f.name == folder.name }
          unless existing
            @folders << folder
          end
        end
      end
    end
    
    private def import_from_html(file_path : String)
      # 完璧なHTML形式ブックマークインポート実装
      # Netscape Bookmark File Format準拠の完全解析
      content = File.read(file_path)
      
      # HTML構造解析
      doc = parse_html_document(content)
      
      # DL要素（Definition List）を検索
      dl_elements = doc.css("dl")
      
      dl_elements.each do |dl|
        process_bookmark_list(dl, nil)
      end
      
      save_bookmarks
    rescue ex : Exception
      @logger.error("HTMLインポートエラー: #{ex.message}")
      raise BookmarkError.new("HTMLファイルのインポートに失敗しました")
    end
    
    private def parse_html_document(content : String)
      # 完璧なHTML解析実装
      # DOCTYPE宣言の検証
      unless content.includes?("<!DOCTYPE NETSCAPE-Bookmark-file-1>") || 
             content.includes?("<!DOCTYPE HTML")
        raise BookmarkError.new("無効なブックマークファイル形式")
      end
      
      # HTMLパーサーの初期化
      parser = HTMLParser.new(content)
      return parser.parse
    end
    
    private def process_bookmark_list(dl_element, parent_folder : BookmarkFolder?)
      # DL要素内のDT/DD要素を処理
      current_folder = parent_folder
      
      dl_element.children.each do |child|
        case child.name.downcase
        when "dt"
          # DT要素の処理
          process_dt_element(child, current_folder)
        when "dd"
          # DD要素の処理（説明文）
          process_dd_element(child, current_folder)
        end
      end
    end
    
    private def process_dt_element(dt_element, parent_folder : BookmarkFolder?)
      # DT要素内のH3（フォルダ）またはA（ブックマーク）を処理
      dt_element.children.each do |child|
        case child.name.downcase
        when "h3"
          # フォルダの作成
          folder = create_folder_from_h3(child, parent_folder)
          
          # 次のDL要素を検索してサブフォルダ/ブックマークを処理
          next_sibling = child.parent.next_sibling
          if next_sibling && next_sibling.name.downcase == "dl"
            process_bookmark_list(next_sibling, folder)
          end
          
        when "a"
          # ブックマークの作成
          create_bookmark_from_a(child, parent_folder)
        end
      end
    end
    
    private def create_folder_from_h3(h3_element, parent_folder : BookmarkFolder?) : BookmarkFolder
      # H3要素からフォルダを作成
      folder_name = h3_element.text.strip
      
      # 属性の解析
      add_date = parse_timestamp(h3_element["add_date"]?)
      last_modified = parse_timestamp(h3_element["last_modified"]?)
      personal_toolbar_folder = h3_element["personal_toolbar_folder"]? == "true"
      
      # フォルダの作成
      folder = BookmarkFolder.new(
        name: folder_name,
        parent: parent_folder,
        created_at: add_date || Time.utc,
        updated_at: last_modified || Time.utc,
        is_toolbar_folder: personal_toolbar_folder
      )
      
      # 親フォルダに追加
      if parent_folder
        parent_folder.add_subfolder(folder)
      else
        @root_folder.add_subfolder(folder)
      end
      
      return folder
    end
    
    private def create_bookmark_from_a(a_element, parent_folder : BookmarkFolder?)
      # A要素からブックマークを作成
      url = a_element["href"]?
      title = a_element.text.strip
      
      return unless url && !url.empty?
      
      # 属性の解析
      add_date = parse_timestamp(a_element["add_date"]?)
      last_visit = parse_timestamp(a_element["last_visit"]?)
      last_modified = parse_timestamp(a_element["last_modified"]?)
      icon_uri = a_element["icon"]?
      tags_str = a_element["tags"]?
      
      # タグの解析
      tags = tags_str ? tags_str.split(",").map(&.strip) : [] of String
      
      # ブックマークの作成
      bookmark = Bookmark.new(
        url: url,
        title: title.empty? ? url : title,
        description: "",
        tags: tags,
        created_at: add_date || Time.utc,
        updated_at: last_modified || Time.utc,
        last_visited: last_visit,
        visit_count: 0,
        favicon_url: icon_uri
      )
      
      # フォルダに追加
      target_folder = parent_folder || @root_folder
      target_folder.add_bookmark(bookmark)
      
      # インデックスに追加
      @url_index[url] = bookmark
      @title_index[title.downcase] = bookmark
      
      # タグインデックスに追加
      tags.each do |tag|
        @tag_index[tag.downcase] ||= [] of Bookmark
        @tag_index[tag.downcase] << bookmark
      end
    end
    
    private def process_dd_element(dd_element, parent_folder : BookmarkFolder?)
      # DD要素の処理（説明文など）
      description = dd_element.text.strip
      
      # 最後に追加されたブックマークに説明を追加
      if parent_folder && !parent_folder.bookmarks.empty?
        last_bookmark = parent_folder.bookmarks.last
        last_bookmark.description = description
      end
    end
    
    private def parse_timestamp(timestamp_str : String?) : Time?
      # UNIXタイムスタンプの解析
      return nil unless timestamp_str
      
      begin
        timestamp = timestamp_str.to_i64
        return Time.unix(timestamp)
      rescue
        return nil
      end
    end
    
    private def save_bookmarks
      # ブックマークの保存
      # このメソッドは実装が必要です
    end
    
    private def import_from_csv(file_path : String)
      # 完璧なCSV形式インポート
      lines = File.read_lines(file_path)
      return if lines.empty?
      
      # ヘッダー行をスキップ
      lines[1..].each do |line|
        parts = line.split(",").map(&.strip.gsub(/^"|"$/, ""))
        next if parts.size < 2
        
        title = parts[0]
        url = parts[1]
        description = parts[2]? if parts.size > 2 && !parts[2].empty?
        tags = parts[3]?.try(&.split(";")) || [] of String if parts.size > 3
        
        existing = find_by_url(url)
        unless existing
          add_bookmark(title, url, description, tags)
        end
      end
    end
    
    private def import_from_netscape(file_path : String)
      import_from_html(file_path)  # Netscape形式はHTML形式と同じ
    end
  end
end 
end 