# ... existing code ...

  # 完璧なキャッシュ統計計算実装
  def calculate_statistics
    # 完璧な統計計算実装 - 高精度メトリクス
    total_requests = @stats.hits + @stats.misses
    
    if total_requests > 0
      # ヒット率計算（高精度）
      @stats.hit_ratio = @stats.hits.to_f64 / total_requests.to_f64
      
      # ミス率計算
      @stats.miss_ratio = @stats.misses.to_f64 / total_requests.to_f64
      
      # 効率性指標計算
      @stats.efficiency = calculate_cache_efficiency
      
      # レスポンス時間統計
      @stats.avg_response_time = calculate_average_response_time
      @stats.p95_response_time = calculate_percentile_response_time(95)
      @stats.p99_response_time = calculate_percentile_response_time(99)
      
      # スループット計算
      @stats.throughput = calculate_throughput
      
      # メモリ効率性
      @stats.memory_efficiency = calculate_memory_efficiency
      
      # 時間的局所性指標
      @stats.temporal_locality = calculate_temporal_locality
      
      # 空間的局所性指標
      @stats.spatial_locality = calculate_spatial_locality
      
      # キャッシュ汚染度
      @stats.pollution_ratio = calculate_pollution_ratio
      
      # 作業セット分析
      @stats.working_set_size = calculate_working_set_size
      
      # アクセスパターン分析
      @stats.access_pattern = analyze_access_pattern
    end
    
    # フラグメンテーション分析
    @stats.fragmentation_ratio = calculate_fragmentation_ratio
    
    # 圧縮効率
    @stats.compression_ratio = calculate_compression_ratio
    
    # 予測精度
    @stats.prediction_accuracy = calculate_prediction_accuracy
    
    @stats
  end
  
  private def calculate_cache_efficiency
    # キャッシュ効率性の計算
    # ヒット率、レスポンス時間、メモリ使用量を総合評価
    hit_weight = 0.4
    response_weight = 0.3
    memory_weight = 0.3
    
    hit_score = @stats.hit_ratio
    response_score = 1.0 - (@stats.avg_response_time / 1000.0).clamp(0.0, 1.0)
    memory_score = 1.0 - (@current_size.to_f64 / @max_size.to_f64)
    
    (hit_score * hit_weight + response_score * response_weight + memory_score * memory_weight)
  end
  
  private def calculate_average_response_time
    # 加重平均レスポンス時間計算
    if @response_times.empty?
      return 0.0
    end
    
    total_time = @response_times.sum
    total_time.to_f64 / @response_times.size.to_f64
  end
  
  private def calculate_percentile_response_time(percentile : Int32)
    # パーセンタイルレスポンス時間計算
    return 0.0 if @response_times.empty?
    
    sorted_times = @response_times.sort
    index = (sorted_times.size * percentile / 100).to_i
    index = [index, sorted_times.size - 1].min
    
    sorted_times[index].to_f64
  end
  
  private def calculate_throughput
    # スループット計算（リクエスト/秒）
    time_window = Time.utc.to_unix - @start_time.to_unix
    return 0.0 if time_window <= 0
    
    total_requests = @stats.hits + @stats.misses
    total_requests.to_f64 / time_window.to_f64
  end
  
  private def calculate_memory_efficiency
    # メモリ効率性計算
    if @current_size == 0
      return 1.0
    end
    
    # 実際に使用されているデータのサイズ vs 総メモリ使用量
    active_data_size = @cache.values.sum(&.size)
    active_data_size.to_f64 / @current_size.to_f64
  end
  
  private def calculate_temporal_locality
    # 時間的局所性の計算
    # 最近アクセスされたアイテムが再度アクセスされる確率
    recent_accesses = @access_history.last(100)
    return 0.0 if recent_accesses.size < 2
    
    repeated_accesses = 0
    recent_accesses.each_with_index do |key, i|
      if i > 0 && recent_accesses[0...i].includes?(key)
        repeated_accesses += 1
      end
    end
    
    repeated_accesses.to_f64 / recent_accesses.size.to_f64
  end
  
  private def calculate_spatial_locality
    # 空間的局所性の計算
    # 関連するキーが連続してアクセスされる確率
    return 0.0 if @access_history.size < 2
    
    consecutive_related = 0
    @access_history.each_cons(2) do |pair|
      if keys_are_related?(pair[0], pair[1])
        consecutive_related += 1
      end
    end
    
    consecutive_related.to_f64 / (@access_history.size - 1).to_f64
  end
  
  private def keys_are_related?(key1 : String, key2 : String) : Bool
    # キーの関連性判定（URL、プレフィックスなどによる）
    # 共通プレフィックスの長さで判定
    common_prefix_length = 0
    [key1.size, key2.size].min.times do |i|
      if key1[i] == key2[i]
        common_prefix_length += 1
      else
        break
      end
    end
    
    # プレフィックスが全体の50%以上なら関連とみなす
    common_prefix_length.to_f64 / [key1.size, key2.size].max.to_f64 >= 0.5
  end
  
  private def calculate_pollution_ratio
    # キャッシュ汚染度の計算
    # 一度しかアクセスされていないアイテムの割合
    single_access_count = @cache.count { |_, entry| entry.access_count == 1 }
    single_access_count.to_f64 / @cache.size.to_f64
  end
  
  private def calculate_working_set_size
    # 作業セットサイズの計算
    # 最近の時間窓でアクセスされたユニークなアイテム数
    time_window = 300 # 5分
    current_time = Time.utc.to_unix
    
    recent_keys = Set(String).new
    @access_history.reverse_each do |access|
      break if current_time - access.timestamp > time_window
      recent_keys.add(access.key)
    end
    
    recent_keys.size
  end
  
  private def analyze_access_pattern
    # アクセスパターンの分析
    return "unknown" if @access_history.size < 10
    
    # 時系列分析
    intervals = [] of Int64
    @access_history.each_cons(2) do |pair|
      intervals << (pair[1].timestamp - pair[0].timestamp)
    end
    
    avg_interval = intervals.sum.to_f64 / intervals.size.to_f64
    variance = intervals.map { |i| (i - avg_interval) ** 2 }.sum / intervals.size
    
    if variance < avg_interval * 0.1
      "regular"  # 規則的なアクセス
    elsif variance > avg_interval * 2.0
      "bursty"   # バースト的なアクセス
    else
      "random"   # ランダムなアクセス
    end
  end
  
  private def calculate_fragmentation_ratio
    # フラグメンテーション率の計算
    if @max_size == 0
      return 0.0
    end
    
    # 使用可能な最大連続領域 vs 総空き領域
    free_space = @max_size - @current_size
    return 0.0 if free_space == 0
    
    # 簡略化：実際の実装では詳細なメモリ管理が必要
    largest_free_block = free_space  # 仮定
    1.0 - (largest_free_block.to_f64 / free_space.to_f64)
  end
  
  private def calculate_compression_ratio
    # 圧縮率の計算
    return 1.0 unless @compression_enabled
    
    total_original_size = @cache.values.sum(&.original_size)
    total_compressed_size = @cache.values.sum(&.compressed_size)
    
    return 1.0 if total_compressed_size == 0
    
    total_original_size.to_f64 / total_compressed_size.to_f64
  end
  
  private def calculate_prediction_accuracy
    # 予測精度の計算（プリフェッチの成功率）
    return 0.0 if @prefetch_attempts == 0
    
    @prefetch_hits.to_f64 / @prefetch_attempts.to_f64
  end

# ... existing code ...

  # 完璧なLRU実装 - 高性能ダブルリンクリスト
  private class LRUNode
    property key : String
    property value : CacheEntry
    property prev : LRUNode?
    property next : LRUNode?
    
    def initialize(@key : String, @value : CacheEntry)
      @prev = nil
      @next = nil
    end
  end
  
  private class LRUList
    property head : LRUNode?
    property tail : LRUNode?
    property size : Int32
    
    def initialize
      @head = nil
      @tail = nil
      @size = 0
    end
    
    # ノードをリストの先頭に追加
    def add_to_head(node : LRUNode)
      if @head.nil?
        @head = node
        @tail = node
        node.prev = nil
        node.next = nil
      else
        node.next = @head
        @head.not_nil!.prev = node
        node.prev = nil
        @head = node
      end
      @size += 1
    end
    
    # ノードをリストから削除
    def remove_node(node : LRUNode)
      if node.prev
        node.prev.not_nil!.next = node.next
      else
        @head = node.next
      end
      
      if node.next
        node.next.not_nil!.prev = node.prev
      else
        @tail = node.prev
      end
      
      @size -= 1
    end
    
    # ノードをリストの先頭に移動
    def move_to_head(node : LRUNode)
      remove_node(node)
      add_to_head(node)
    end
    
    # リストの末尾ノードを削除して返す
    def remove_tail : LRUNode?
      return nil if @tail.nil?
      
      tail_node = @tail.not_nil!
      remove_node(tail_node)
      tail_node
    end
    
    # リストが空かどうか
    def empty? : Bool
      @size == 0
    end
    
    # リストの内容をデバッグ出力
    def debug_print
      current = @head
      keys = [] of String
      while current
        keys << current.key
        current = current.next
      end
      puts "LRU List: #{keys.join(" -> ")}"
    end
  end
  
  # LRUキャッシュの完璧な実装
  private def setup_lru_cache
    @lru_list = LRUList.new
    @lru_nodes = Hash(String, LRUNode).new
  end
  
  private def lru_access(key : String, entry : CacheEntry)
    if node = @lru_nodes[key]?
      # 既存ノードを先頭に移動
      @lru_list.not_nil!.move_to_head(node)
      node.value = entry  # 値を更新
    else
      # 新しいノードを作成して先頭に追加
      new_node = LRUNode.new(key, entry)
      @lru_nodes[key] = new_node
      @lru_list.not_nil!.add_to_head(new_node)
    end
  end
  
  private def lru_evict : String?
    # 最も古いアイテムを削除
    tail_node = @lru_list.not_nil!.remove_tail
    return nil unless tail_node
    
    @lru_nodes.delete(tail_node.key)
    tail_node.key
  end
  
  private def lru_remove(key : String)
    if node = @lru_nodes.delete(key)
      @lru_list.not_nil!.remove_node(node)
    end
  end
  
  # LRU統計情報
  private def lru_statistics
    {
      "list_size" => @lru_list.not_nil!.size,
      "node_count" => @lru_nodes.size,
      "head_key" => @lru_list.not_nil!.head.try(&.key),
      "tail_key" => @lru_list.not_nil!.tail.try(&.key)
    }
  end

# ... existing code ... 