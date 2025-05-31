# JavaScriptファイルの静的解析を行うパーサークラス
#
# このクラスはJavaScriptファイルを解析し、リソースURLの抽出や依存関係を特定します。
# 完全なASTパースではなく、正規表現ベースの解析を中心に行います。

require "json"

module QuantumBrowser
  # JavaScriptオブジェクトをJSONに変換するパーサー
  class JavaScriptObjectParser
    # パースエラー
    class ParseError < Exception
    end
    
    # トークンタイプ
    enum TokenType
      String
      Number
      Boolean
      Null
      Identifier
      OpenBrace
      CloseBrace
      OpenBracket
      CloseBracket
      Colon
      Comma
      Dot
      EOF
    end
    
    # トークン
    class Token
      property type : TokenType
      property value : String
      property line : Int32
      property column : Int32
      
      def initialize(@type, @value, @line = 0, @column = 0)
      end
      
      def to_s
        "Token(#{@type}, '#{@value}', #{@line}:#{@column})"
      end
    end
    
    @source : String
    @tokens : Array(Token)
    @position : Int32 = 0
    @line : Int32 = 1
    @column : Int32 = 1
    
    def initialize(@source : String)
      @tokens = [] of Token
      tokenize
    end
    
    # ソースコードをトークン化する
    private def tokenize
      # 単純な字句解析器
      i = 0
      while i < @source.size
        char = @source[i]
        case char
        when ' ', '\t', '\r', '\n'
          # 空白文字をスキップ
          if char == '\n'
            @line += 1
            @column = 1
          else
            @column += 1
          end
          i += 1
        when '{'
          @tokens << Token.new(TokenType::OpenBrace, "{", @line, @column)
          @column += 1
          i += 1
        when '}'
          @tokens << Token.new(TokenType::CloseBrace, "}", @line, @column)
          @column += 1
          i += 1
        when '['
          @tokens << Token.new(TokenType::OpenBracket, "[", @line, @column)
          @column += 1
          i += 1
        when ']'
          @tokens << Token.new(TokenType::CloseBracket, "]", @line, @column)
          @column += 1
          i += 1
        when ':'
          @tokens << Token.new(TokenType::Colon, ":", @line, @column)
          @column += 1
          i += 1
        when ','
          @tokens << Token.new(TokenType::Comma, ",", @line, @column)
          @column += 1
          i += 1
        when '.'
          @tokens << Token.new(TokenType::Dot, ".", @line, @column)
          @column += 1
          i += 1
        when '"', '\''
          # 文字列リテラル
          start_column = @column
          quote = char
          string_value = ""
          i += 1  # 開始引用符をスキップ
          escaped = false
          
          while i < @source.size
            c = @source[i]
            @column += 1
            
            if escaped
              case c
              when 'n'
                string_value += '\n'
              when 't'
                string_value += '\t'
              when 'r'
                string_value += '\r'
              when 'b'
                string_value += '\b'
              when 'f'
                string_value += '\f'
              when '\\', '\'', '"'
                string_value += c
              else
                string_value += c  # その他のエスケープシーケンス
              end
              escaped = false
            elsif c == '\\'
              escaped = true
            elsif c == quote
              # 文字列の終了
              break
            else
              string_value += c
              if c == '\n'
                @line += 1
                @column = 1
              end
            end
            
            i += 1
          end
          
          if i >= @source.size && escaped
            raise ParseError.new("未終了の文字列リテラル")
          end
          
          @tokens << Token.new(TokenType::String, string_value, @line, start_column)
          i += 1  # 終了引用符をスキップ
        when '0'..'9', '-'
          # 数値リテラル
          start_column = @column
          number_value = ""
          number_value += char
          i += 1
          @column += 1
          
          while i < @source.size && @source[i].in?('0'..'9', '.', 'e', 'E', '+', '-')
            number_value += @source[i]
            i += 1
            @column += 1
          end
          
          @tokens << Token.new(TokenType::Number, number_value, @line, start_column)
        when '/'
          if i + 1 < @source.size
            next_char = @source[i + 1]
            if next_char == '/'
              # 行コメント
              i += 2
              @column += 2
              while i < @source.size && @source[i] != '\n'
                i += 1
                @column += 1
              end
            elsif next_char == '*'
              # ブロックコメント
              i += 2
              @column += 2
              while i + 1 < @source.size && !(@source[i] == '*' && @source[i + 1] == '/')
                if @source[i] == '\n'
                  @line += 1
                  @column = 1
                else
                  @column += 1
                end
                i += 1
              end
              
              if i + 1 < @source.size
                i += 2  # '*/'をスキップ
                @column += 2
              else
                raise ParseError.new("未終了のブロックコメント")
              end
            else
              # 除算演算子 (このパーサーでは処理しない)
              i += 1
              @column += 1
            end
          else
            i += 1
            @column += 1
          end
        when 'a'..'z', 'A'..'Z', '_', '$'
          # 識別子
          start_column = @column
          ident = ""
          
          while i < @source.size && @source[i].in?('a'..'z', 'A'..'Z', '0'..'9', '_', '$')
            ident += @source[i]
            i += 1
            @column += 1
          end
          
          # 予約語のチェック
          case ident
          when "true", "false"
            @tokens << Token.new(TokenType::Boolean, ident, @line, start_column)
          when "null", "undefined"
            @tokens << Token.new(TokenType::Null, "null", @line, start_column)
          else
            @tokens << Token.new(TokenType::Identifier, ident, @line, start_column)
          end
        else
          # その他の文字は無視
          i += 1
          @column += 1
        end
      end
      
      # EOFトークンを追加
      @tokens << Token.new(TokenType::EOF, "", @line, @column)
    end
    
    # 次のトークンを取得する
    private def peek : Token
      return @tokens.last if @position >= @tokens.size
      @tokens[@position]
    end
    
    # 現在のトークンを消費して次へ進む
    private def consume : Token
      token = peek
      @position += 1
      token
    end
    
    # 特定のタイプのトークンなら消費する
    private def expect(type : TokenType) : Token
      token = peek
      if token.type != type
        raise ParseError.new("#{type}トークンを期待しましたが、#{token.type}が見つかりました (値: #{token.value})")
      end
      
      consume
    end
    
    # JSONに変換する
    def to_json : String
      @position = 0
      result = IO::Memory.new
      parse_value(result)
      result.to_s
    end
    
    # 値を解析する
    private def parse_value(output : IO) : Nil
      token = peek
      
      case token.type
      when TokenType::OpenBrace
        parse_object(output)
      when TokenType::OpenBracket
        parse_array(output)
      when TokenType::String
        consume
        output << "\"#{escape_json_string(token.value)}\""
      when TokenType::Number
        consume
        output << token.value
      when TokenType::Boolean
        consume
        output << token.value
      when TokenType::Null
        consume
        output << "null"
      when TokenType::Identifier
        # オブジェクトプロパティを参照するときの識別子
        # JavaScriptのオブジェクト参照はJSON変換時に無視する
        consume
        
        # ドット演算子でのプロパティアクセスを処理
        if peek.type == TokenType::Dot
          while peek.type == TokenType::Dot
            consume  # ドットを消費
            if peek.type == TokenType::Identifier
              consume  # プロパティ名を消費
            end
          end
        end
        
        # 識別子をnullとして扱う (JSON互換性のため)
        output << "null"
      else
        raise ParseError.new("予期しない#{token.type}トークン: #{token.value}")
      end
    end
    
    # オブジェクトを解析する
    private def parse_object(output : IO) : Nil
      expect(TokenType::OpenBrace)
      output << "{"
      
      first = true
      while peek.type != TokenType::CloseBrace && peek.type != TokenType::EOF
        if !first
          expect(TokenType::Comma)
          output << ","
        end
        
        # キー (識別子または文字列)
        key_token = peek
        key = ""
        
        case key_token.type
        when TokenType::String
          consume
          key = key_token.value
        when TokenType::Identifier
          consume
          key = key_token.value
        else
          raise ParseError.new("オブジェクトキーとして文字列または識別子を期待しました")
        end
        
        output << "\"#{escape_json_string(key)}\":"
        
        # コロンを期待
        expect(TokenType::Colon)
        
        # 値
        parse_value(output)
        
        first = false
      end
      
      expect(TokenType::CloseBrace)
      output << "}"
    end
    
    # 配列を解析する
    private def parse_array(output : IO) : Nil
      expect(TokenType::OpenBracket)
      output << "["
      
      first = true
      while peek.type != TokenType::CloseBracket && peek.type != TokenType::EOF
        if !first
          expect(TokenType::Comma)
          output << ","
        end
        
        parse_value(output)
        first = false
      end
      
      expect(TokenType::CloseBracket)
      output << "]"
    end
    
    # JSON文字列のためにエスケープする
    private def escape_json_string(str : String) : String
      str.gsub(/[\\"\/\b\f\n\r\t]/) do |match|
        case match
        when "\\"
          "\\\\"
        when "\""
          "\\\""
        when "/"
          "\\/"
        when "\b"
          "\\b"
        when "\f"
          "\\f"
        when "\n"
          "\\n"
        when "\r"
          "\\r"
        when "\t"
          "\\t"
        else
          match
        end
      end
    end
  end
  
  # JavaScriptファイルの静的解析を行うパーサー
  class JavaScriptParser
    # JavaScript解析エラー
    class ParseError < Exception
    end
    
    @content : String
    @lines : Array(String)
    
    def initialize(@content : String)
      @lines = @content.split("\n")
    end
    
    # import文からモジュールURLを抽出
    def extract_imports : Array(String)
      imports = [] of String
      
      # 標準的なimport文
      # 例: import { foo } from './bar.js'
      @content.scan(/import\s+(?:(?:{[^}]*}|\*(?:\s+as\s+\w+)?|\w+)(?:\s*,\s*(?:{[^}]*}|\*(?:\s+as\s+\w+)?|\w+))*)?\s+from\s+['"]([^'"]+)['"]/i) do |match|
        if url = match[1]?
          imports << url
        end
      end
      
      # ダイナミックインポート
      # 例: import('./lazy-module.js')
      @content.scan(/import\s*\(\s*['"]([^'"]+)['"]\s*\)/i) do |match|
        if url = match[1]?
          imports << url
        end
      end
      
      # import文だけの形式
      # 例: import './polyfill.js'
      @content.scan(/import\s+['"]([^'"]+)['"]/i) do |match|
        if url = match[1]?
          imports << url
        end
      end
      
      # require関数
      # 例: require('./module.js')
      @content.scan(/require\s*\(\s*['"]([^'"]+)['"]\s*\)/i) do |match|
        if url = match[1]?
          imports << url
        end
      end
      
      # webpack用のダイナミックインポート
      # 例: require.ensure([], function(require) { require('./lazy-module') })
      @content.scan(/require\.ensure.*?require\s*\(\s*['"]([^'"]+)['"]\s*\)/i) do |match|
        if url = match[1]?
          imports << url
        end
      end
      
      # ESM用のimportmap参照
      # 例: import("lodash/map")
      # 注: これはimportmapを参照する場合があり、相対パスでないことがある
      @content.scan(/import\s*\(\s*['"]([^./][^'"]+)['"]\s*\)/i) do |match|
        if url = match[1]?
          imports << url
        end
      end
      
      imports.uniq
    end
    
    # fetch API呼び出しからURLを抽出
    def extract_fetch_calls : Array(String)
      urls = [] of String
      
      # 基本的なfetch呼び出し
      # 例: fetch('https://example.com/data.json')
      @content.scan(/fetch\s*\(\s*['"]([^'"]+)['"]/i) do |match|
        if url = match[1]?
          urls << url
        end
      end
      
      # 変数内のURLを検出するのは難しいですが、一部の単純なケースをカバー
      # 例: const url = '/api/data'; fetch(url)
      url_assignments = {} of String => String
      @content.scan(/(?:const|let|var)\s+(\w+)\s*=\s*['"]([^'"]+)['"]/) do |match|
        var_name = match[1]
        url = match[2]
        url_assignments[var_name] = url
      end
      
      # 変数を使ったfetch呼び出し
      @content.scan(/fetch\s*\(\s*(\w+)\s*\)/) do |match|
        var_name = match[1]
        if url = url_assignments[var_name]?
          urls << url
        end
      end
      
      # 設定オブジェクトを使ったfetch呼び出し
      # 例: fetch('/api/data', { method: 'POST' })
      @content.scan(/fetch\s*\(\s*['"]([^'"]+)['"]\s*,\s*{[^}]*}\s*\)/) do |match|
        if url = match[1]?
          urls << url
        end
      end
      
      urls.uniq
    end
    
    # XMLHttpRequest呼び出しからURLを抽出
    def extract_xhr_calls : Array(String)
      urls = [] of String
      
      # XMLHttpRequest作成パターン検出
      xhr_vars = [] of String
      @content.scan(/(?:const|let|var)\s+(\w+)\s*=\s*new\s+XMLHttpRequest\s*\(\s*\)/) do |match|
        xhr_vars << match[1]
      end
      
      # 匿名XMLHttpRequestオブジェクト
      @content.scan(/new\s+XMLHttpRequest\s*\(\s*\)/) do |_|
        xhr_vars << "_anonymous_xhr_" # 匿名XHRを特別な名前でマーク
      end
      
      # open呼び出し検出
      xhr_vars.each do |xhr_var|
        if xhr_var == "_anonymous_xhr_"
          # 匿名XMLHttpRequestのopen呼び出し
          @content.scan(/new\s+XMLHttpRequest\s*\(\s*\).*?\.open\s*\(\s*['"][^'"]+['"],\s*['"]([^'"]+)['"]/) do |match|
            if url = match[1]?
              urls << url
            end
          end
        else
          # 名前付きXMLHttpRequestのopen呼び出し
          @content.scan(/#{Regex.escape(xhr_var)}\.open\s*\(\s*['"][^'"]+['"],\s*['"]([^'"]+)['"]/) do |match|
            if url = match[1]?
              urls << url
            end
          end
        end
      end
      
      urls.uniq
    end
    
    # WebSocket接続からURLを抽出
    def extract_websocket_calls : Array(String)
      urls = [] of String
      
      # WebSocket作成パターン検出
      # 例: new WebSocket('wss://example.com/socket')
      @content.scan(/new\s+WebSocket\s*\(\s*['"]([^'"]+)['"]/) do |match|
        if url = match[1]?
          urls << url
        end
      end
      
      # 変数を使ったWebSocket作成
      ws_url_vars = {} of String => String
      @content.scan(/(?:const|let|var)\s+(\w+)\s*=\s*['"]([^'"]+)['"]/) do |match|
        var_name = match[1]
        url = match[2]
        if url.starts_with?("ws://") || url.starts_with?("wss://")
          ws_url_vars[var_name] = url
        end
      end
      
      # 変数を使ったWebSocket呼び出し
      @content.scan(/new\s+WebSocket\s*\(\s*(\w+)\s*\)/) do |match|
        var_name = match[1]
        if url = ws_url_vars[var_name]?
          urls << url
        end
      end
      
      urls.uniq
    end
    
    # 画像・メディアリソースの抽出
    def extract_media_urls : Hash(String, String)
      media_urls = {} of String => String
      
      # 画像の読み込み
      # 例: new Image().src = '/images/logo.png'
      @content.scan(/new\s+Image\s*\([^)]*\).*?\.src\s*=\s*['"]([^'"]+)['"]/) do |match|
        if url = match[1]?
          media_urls[url] = "image"
        end
      end
      
      # 画像のプリロード
      # 例: const img = new Image(); img.src = '/images/logo.png'
      img_vars = [] of String
      @content.scan(/(?:const|let|var)\s+(\w+)\s*=\s*new\s+Image\s*\([^)]*\)/) do |match|
        img_vars << match[1]
      end
      
      img_vars.each do |img_var|
        @content.scan(/#{Regex.escape(img_var)}\.src\s*=\s*['"]([^'"]+)['"]/) do |match|
          if url = match[1]?
            media_urls[url] = "image"
          end
        end
      end
      
      # backgroundImage設定
      # 例: element.style.backgroundImage = 'url(/images/bg.png)'
      @content.scan(/\.(?:style\.backgroundImage|background|backgroundImage)\s*=\s*(?:['"]url\(['"]?|['"]url\(['"]|url\(['"]?)([^'")]+)/) do |match|
        if url = match[1]?
          media_urls[url] = "image"
        end
      end
      
      # audio/video要素の作成
      # 例: new Audio('/sounds/beep.mp3')
      @content.scan(/new\s+Audio\s*\(\s*['"]([^'"]+)['"]/) do |match|
        if url = match[1]?
          media_urls[url] = "audio"
        end
      end
      
      # audio/video要素のsrc設定
      # 例: audioElement.src = '/sounds/music.mp3'
      @content.scan(/\.src\s*=\s*['"]([^'"]+\.(?:mp3|wav|ogg|m4a,aac))['"]/) do |match|
        if url = match[1]?
          media_urls[url] = "audio"
        end
      end
      
      # video要素のsrc設定
      @content.scan(/\.src\s*=\s*['"]([^'"]+\.(?:mp4|webm,ogv,mov))['"]/) do |match|
        if url = match[1]?
          media_urls[url] = "video"
        end
      end
      
      # source要素のsrc設定
      # 例: source.src = '/videos/clip.mp4'
      @content.scan(/\.src\s*=\s*['"]([^'"]+)['"].*?\.type\s*=\s*['"]video\//) do |match|
        if url = match[1]?
          media_urls[url] = "video"
        end
      end
      
      @content.scan(/\.src\s*=\s*['"]([^'"]+)['"].*?\.type\s*=\s*['"]audio\//) do |match|
        if url = match[1]?
          media_urls[url] = "audio"
        end
      end
      
      # URLヘルパー関数の抽出
      url_funcs = [] of String
      @content.scan(/function\s+(\w+)\s*\([^)]*\)\s*{\s*(?:return\s*)?['"]([^'"]+)['"]/) do |match|
        func_name = match[1]
        url = match[2]
        url_funcs << func_name
      end
      
      # URLヘルパー関数の使用検出
      url_funcs.each do |func|
        @content.scan(/\b#{Regex.escape(func)}\s*\(\s*\)/) do |_|
          # 関数の定義を再検索
          @content.scan(/function\s+#{Regex.escape(func)}\s*\([^)]*\)\s*{\s*(?:return\s*)?['"]([^'"]+)['"]/) do |match|
            if url = match[1]?
              # URLの種類を拡張子から推測
              ext = File.extname(url).downcase
              type = if ext.in?(".jpg", ".jpeg", ".png", ".gif", ".webp", ".svg", ".ico")
                       "image"
                     elsif ext.in?(".mp3", ".wav", ".ogg", ".m4a", ".aac")
                       "audio"
                     elsif ext.in?(".mp4", ".webm", ".ogv", ".mov")
                       "video"
                     else
                       "other"
                     end
              media_urls[url] = type
            end
          end
        end
      end
      
      media_urls
    end
    
    # WebWorker作成の検出
    def extract_web_workers : Array(String)
      workers = [] of String
      
      # Worker作成
      # 例: new Worker('/scripts/worker.js')
      @content.scan(/new\s+Worker\s*\(\s*['"]([^'"]+)['"]/) do |match|
        if url = match[1]?
          workers << url
        end
      end
      
      workers.uniq
    end
    
    # JSからオブジェクトURLの作成検出
    def extract_object_urls : Array(String)
      urls = [] of String
      
      # URL.createObjectURL呼び出し
      # 注: これは動的に生成されるURLなので、実際のURLは実行時にしかわからない
      @content.scan(/URL\.createObjectURL\s*\(\s*(\w+)\s*\)/) do |match|
        var_name = match[1]
        
        # ここで変数の型を推測する
        if @content.includes?("new Blob") && @content.includes?(var_name)
          urls << "blob:generated"
        elsif @content.includes?("new File") && @content.includes?(var_name)
          urls << "blob:file"
        end
      end
      
      urls.uniq
    end
    
    # モジュール設定からの依存関係抽出
    def extract_module_config : Hash(String, Array(String))
      config = {} of String => Array(String)
      
      # requirejs/AMD設定
      # 例: requirejs.config({ paths: { jquery: 'libs/jquery' } })
      @content.scan(/requirejs\.config\s*\(\s*{[^}]*paths\s*:\s*({[^}]+})/i) do |match|
        if paths_str = match[1]?
          begin
            # JavaScriptオブジェクト表記をJSON形式に変換する堅牢な実装
            
            # JavaScriptオブジェクトの構文解析クラス
            js_parser = JavaScriptObjectParser.new(paths_str)
            corrected_str = js_parser.to_json
            
            # JSONとして解析
            if corrected_str.is_a?(String) && corrected_str.strip.starts_with?("{") && corrected_str.strip.ends_with?("}")
              begin
                paths = JSON.parse(corrected_str)
                
                paths.as_h?.try do |paths_hash|
                  paths_hash.each do |key, value|
                    if value.as_s?
                      config[key.as_s] = [value.as_s]
                    elsif value.as_a?
                      config[key.as_s] = value.as_a.map(&.as_s)
                    end
                  end
                end
              rescue ex
                # より複雑なJavaScriptオブジェクト構文の場合はフォールバック解析を試みる
                Log.warn { "JSON解析エラー: #{ex.message}, フォールバック解析を試みます: #{corrected_str}" }
                
                # 非常に単純なキー/値抽出
                corrected_str.scan(/"([^"]+)":\s*"([^"]+)"/) do |key_value|
                  if key = key_value[1]? && value = key_value[2]?
                    config[key] = [value]
                  end
                end
              end
            end
          rescue ex
            Log.error { "パス設定の解析に失敗しました: #{ex.message}" }
          end
        end
      end
      
      config
    end
    
    # サービスワーカー登録の検出
    def extract_service_worker : Array(String)
      urls = [] of String
      
      # サービスワーカーの登録
      # 例: navigator.serviceWorker.register('/sw.js')
      @content.scan(/navigator\.serviceWorker\.register\s*\(\s*['"]([^'"]+)['"]/) do |match|
        if url = match[1]?
          urls << url
        end
      end
      
      urls.uniq
    end
    
    # APIエンドポイントの抽出
    def extract_api_endpoints : Array(String)
      endpoints = [] of String
      
      # URLが/api/で始まるものを抽出
      @content.scan(/['"]((\/api\/|https?:\/\/[^/'"]+\/api\/)[^'"]+)['"]/) do |match|
        if url = match[1]?
          endpoints << url
        end
      end
      
      endpoints.uniq
    end
  end
end 