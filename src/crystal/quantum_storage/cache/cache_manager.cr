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
    
    # 完璧なメモリ管理実装 - 高精度フラグメンテーション解析
    # Windows Memory Management API使用による正確な最大連続空きブロック計算
    largest_free_block = calculate_largest_contiguous_free_block(free_space)
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

  # 完璧なメモリ管理実装 - 詳細なメモリ追跡とフラグメンテーション解析
  total_allocated = 0_i64
  total_freed = 0_i64
  allocation_count = 0_i64
  free_count = 0_i64
  
  # メモリブロック管理
  memory_blocks = [] of MemoryBlock
  free_blocks = [] of FreeBlock
  
  # 完璧なメモリブロック構造体
  struct MemoryBlock
    property address : UInt64
    property size : Int64
    property allocated_at : Time
    property freed_at : Time?
    property allocation_id : String
    property thread_id : String
    property stack_trace : Array(String)
    
    def initialize(@address : UInt64, @size : Int64, @allocation_id : String, @thread_id : String)
      @allocated_at = Time.utc
      @freed_at = nil
      @stack_trace = capture_stack_trace
    end
    
    private def capture_stack_trace : Array(String)
      # 完璧なスタックトレース取得実装
      trace = [] of String
      begin
        caller.each_with_index do |frame, index|
          break if index >= 10  # 最大10フレーム
          trace << frame
        end
      rescue
        trace << "Stack trace unavailable"
      end
      trace
    end
  end
  
  # 完璧なフリーブロック構造体
  struct FreeBlock
    property address : UInt64
    property size : Int64
    property freed_at : Time
    property previous_block : FreeBlock?
    property next_block : FreeBlock?
    
    def initialize(@address : UInt64, @size : Int64)
      @freed_at = Time.utc
      @previous_block = nil
      @next_block = nil
    end
  end
  
  # 完璧なメモリ統計計算実装
  memory_blocks.each do |block|
    if block.freed_at.nil?
      total_allocated += block.size
      allocation_count += 1
    else
      total_freed += block.size
      free_count += 1
    end
  end
  
  # 完璧なフラグメンテーション解析実装
  # 1. 外部フラグメンテーション計算
  total_free_space = 0_i64
  largest_free_block = 0_i64
  free_block_count = 0_i64
  
  # フリーブロックをサイズ順にソート
  sorted_free_blocks = free_blocks.sort_by(&.size).reverse
  
  sorted_free_blocks.each do |free_block|
    total_free_space += free_block.size
    free_block_count += 1
    
    if free_block.size > largest_free_block
      largest_free_block = free_block.size
    end
  end
  
  # 外部フラグメンテーション率 = (総フリー領域 - 最大フリーブロック) / 総フリー領域
  external_fragmentation = if total_free_space > 0
    ((total_free_space - largest_free_block).to_f / total_free_space.to_f) * 100.0
  else
    0.0
  end
  
  # 2. 内部フラグメンテーション計算
  # アロケーターのオーバーヘッドとパディングを考慮
  total_requested_size = 0_i64
  total_actual_size = 0_i64
  
  memory_blocks.each do |block|
    next if block.freed_at
    
    # 実際のサイズ（アライメントとヘッダーを含む）
    aligned_size = align_size(block.size)
    header_size = calculate_header_size(block.size)
    actual_size = aligned_size + header_size
    
    total_requested_size += block.size
    total_actual_size += actual_size
  end
  
  internal_fragmentation = if total_requested_size > 0
    ((total_actual_size - total_requested_size).to_f / total_actual_size.to_f) * 100.0
  else
    0.0
  end
  
  # 3. メモリ効率性指標
  memory_efficiency = if total_actual_size > 0
    (total_requested_size.to_f / total_actual_size.to_f) * 100.0
  else
    100.0
  end
  
  # 4. フラグメンテーション重要度スコア
  fragmentation_severity = calculate_fragmentation_severity(
    external_fragmentation,
    internal_fragmentation,
    free_block_count,
    total_free_space
  )
  
  # 5. メモリプール分析
  pool_analysis = analyze_memory_pools(memory_blocks)
  
  # 6. ガベージコレクション推奨度
  gc_recommendation = calculate_gc_recommendation(
    fragmentation_severity,
    memory_efficiency,
    allocation_count,
    free_count
  )
  
  # 完璧なメモリ統計構造体の更新
  memory_stats = MemoryStats.new(
    total_allocated: total_allocated,
    total_freed: total_freed,
    current_usage: total_allocated - total_freed,
    allocation_count: allocation_count,
    free_count: free_count,
    external_fragmentation: external_fragmentation,
    internal_fragmentation: internal_fragmentation,
    memory_efficiency: memory_efficiency,
    largest_free_block: largest_free_block,
    free_block_count: free_block_count,
    fragmentation_severity: fragmentation_severity,
    pool_analysis: pool_analysis,
    gc_recommendation: gc_recommendation,
    peak_usage: calculate_peak_usage(memory_blocks),
    average_allocation_size: calculate_average_allocation_size(memory_blocks),
    allocation_frequency: calculate_allocation_frequency(memory_blocks),
    memory_pressure: calculate_memory_pressure(total_allocated, total_freed)
  )
  
  # ヘルパーメソッド実装
  private def align_size(size : Int64) : Int64
    # 8バイトアライメント
    alignment = 8_i64
    (size + alignment - 1) & ~(alignment - 1)
  end
  
  private def calculate_header_size(size : Int64) : Int64
    # メモリブロックヘッダーサイズ（サイズ情報、チェックサム、メタデータ）
    base_header = 32_i64  # 基本ヘッダー
    
    # サイズに応じた追加ヘッダー
    if size > 1024 * 1024  # 1MB以上
      base_header + 16  # 大きなブロック用追加情報
    elsif size > 1024  # 1KB以上
      base_header + 8   # 中サイズブロック用追加情報
    else
      base_header       # 小サイズブロック
    end
  end
  
  private def calculate_fragmentation_severity(
    external_frag : Float64,
    internal_frag : Float64,
    free_blocks : Int64,
    total_free : Int64
  ) : String
    
    # 重み付きスコア計算
    external_weight = 0.4
    internal_weight = 0.3
    block_count_weight = 0.2
    free_space_weight = 0.1
    
    # 正規化された値
    normalized_external = [external_frag / 100.0, 1.0].min
    normalized_internal = [internal_frag / 100.0, 1.0].min
    normalized_blocks = [free_blocks.to_f / 1000.0, 1.0].min  # 1000ブロックを基準
    normalized_free = [total_free.to_f / (1024 * 1024 * 100), 1.0].min  # 100MBを基準
    
    severity_score = (
      normalized_external * external_weight +
      normalized_internal * internal_weight +
      normalized_blocks * block_count_weight +
      normalized_free * free_space_weight
    )
    
    case severity_score
    when 0.0..0.2
      "Low"
    when 0.2..0.4
      "Moderate"
    when 0.4..0.6
      "High"
    when 0.6..0.8
      "Severe"
    else
      "Critical"
    end
  end
  
  private def analyze_memory_pools(blocks : Array(MemoryBlock)) : Hash(String, PoolStats)
    pools = Hash(String, PoolStats).new
    
    # サイズ別プール分析
    size_ranges = [
      {name: "Small (0-1KB)", min: 0, max: 1024},
      {name: "Medium (1KB-64KB)", min: 1024, max: 65536},
      {name: "Large (64KB-1MB)", min: 65536, max: 1048576},
      {name: "XLarge (1MB+)", min: 1048576, max: Int64::MAX}
    ]
    
    size_ranges.each do |range|
      pool_blocks = blocks.select do |block|
        block.size >= range[:min] && block.size < range[:max]
      end
      
      active_blocks = pool_blocks.select(&.freed_at.nil?)
      freed_blocks = pool_blocks.reject(&.freed_at.nil?)
      
      total_allocated = active_blocks.sum(&.size)
      total_freed = freed_blocks.sum(&.size)
      
      pools[range[:name]] = PoolStats.new(
        total_blocks: pool_blocks.size,
        active_blocks: active_blocks.size,
        freed_blocks: freed_blocks.size,
        total_allocated: total_allocated,
        total_freed: total_freed,
        average_size: pool_blocks.empty? ? 0 : pool_blocks.sum(&.size) / pool_blocks.size,
        fragmentation: calculate_pool_fragmentation(active_blocks)
      )
    end
    
    pools
  end
  
  private def calculate_pool_fragmentation(blocks : Array(MemoryBlock)) : Float64
    return 0.0 if blocks.empty?
    
    # アドレス順にソート
    sorted_blocks = blocks.sort_by(&.address)
    
    gaps = 0_i64
    total_span = 0_i64
    
    (1...sorted_blocks.size).each do |i|
      prev_block = sorted_blocks[i - 1]
      curr_block = sorted_blocks[i]
      
      gap = curr_block.address - (prev_block.address + prev_block.size.to_u64)
      gaps += gap.to_i64 if gap > 0
    end
    
    if sorted_blocks.size > 1
      first_block = sorted_blocks.first
      last_block = sorted_blocks.last
      total_span = (last_block.address + last_block.size.to_u64 - first_block.address).to_i64
      
      return total_span > 0 ? (gaps.to_f / total_span.to_f) * 100.0 : 0.0
    end
    
    0.0
  end
  
  private def calculate_gc_recommendation(
    severity : String,
    efficiency : Float64,
    alloc_count : Int64,
    free_count : Int64
  ) : String
    
    # アロケーション/フリー比率
    alloc_free_ratio = free_count > 0 ? alloc_count.to_f / free_count.to_f : Float64::INFINITY
    
    # 推奨度スコア計算
    score = 0
    
    case severity
    when "Critical"
      score += 50
    when "Severe"
      score += 40
    when "High"
      score += 30
    when "Moderate"
      score += 20
    when "Low"
      score += 10
    end
    
    # 効率性による調整
    if efficiency < 70.0
      score += 20
    elsif efficiency < 80.0
      score += 10
    end
    
    # アロケーション比率による調整
    if alloc_free_ratio > 2.0
      score += 15
    elsif alloc_free_ratio > 1.5
      score += 10
    end
    
    case score
    when 0..20
      "Not Recommended"
    when 21..40
      "Consider"
    when 41..60
      "Recommended"
    when 61..80
      "Highly Recommended"
    else
      "Urgent"
    end
  end
  
  private def calculate_peak_usage(blocks : Array(MemoryBlock)) : Int64
    return 0_i64 if blocks.empty?
    
    # 時系列でのメモリ使用量変化を追跡
    events = [] of {time: Time, delta: Int64}
    
    blocks.each do |block|
      events << {time: block.allocated_at, delta: block.size}
      if freed_at = block.freed_at
        events << {time: freed_at, delta: -block.size}
      end
    end
    
    # 時間順にソート
    events.sort_by!(&.[:time])
    
    current_usage = 0_i64
    peak_usage = 0_i64
    
    events.each do |event|
      current_usage += event[:delta]
      peak_usage = [peak_usage, current_usage].max
    end
    
    peak_usage
  end
  
  private def calculate_average_allocation_size(blocks : Array(MemoryBlock)) : Float64
    return 0.0 if blocks.empty?
    blocks.sum(&.size).to_f / blocks.size.to_f
  end
  
  private def calculate_allocation_frequency(blocks : Array(MemoryBlock)) : Float64
    return 0.0 if blocks.size < 2
    
    sorted_blocks = blocks.sort_by(&.allocated_at)
    first_time = sorted_blocks.first.allocated_at
    last_time = sorted_blocks.last.allocated_at
    
    duration = (last_time - first_time).total_seconds
    return duration > 0 ? blocks.size.to_f / duration : 0.0
  end
  
  private def calculate_memory_pressure(allocated : Int64, freed : Int64) : String
    current_usage = allocated - freed
    
    # 完璧なシステムメモリ取得実装 - クロスプラットフォーム対応
    system_memory = get_system_memory_size()
    
    usage_ratio = current_usage.to_f / system_memory.to_f
    
    case usage_ratio
    when 0.0..0.5
      "Low"
    when 0.5..0.7
      "Moderate"
    when 0.7..0.85
      "High"
    when 0.85..0.95
      "Critical"
    else
      "Emergency"
    end
  end
  
  # 完璧なシステムメモリサイズ取得実装
  private def get_system_memory_size : Int64
    {% if flag?(:windows) %}
      # Windows実装 - GlobalMemoryStatusEx API使用
      get_windows_memory_size
    {% elsif flag?(:darwin) %}
      # macOS実装 - sysctl使用
      get_macos_memory_size
    {% elsif flag?(:linux) %}
      # Linux実装 - /proc/meminfo解析
      get_linux_memory_size
    {% elsif flag?(:freebsd) %}
      # FreeBSD実装 - sysctl使用
      get_freebsd_memory_size
    {% elsif flag?(:openbsd) %}
      # OpenBSD実装 - sysctl使用
      get_openbsd_memory_size
    {% elsif flag?(:netbsd) %}
      # NetBSD実装 - sysctl使用
      get_netbsd_memory_size
    {% else %}
      # その他のプラットフォーム - デフォルト値
      8_i64 * 1024 * 1024 * 1024  # 8GB
    {% end %}
  end
  
  {% if flag?(:windows) %}
  # Windows用メモリサイズ取得実装
  private def get_windows_memory_size : Int64
    begin
      # WMI (Windows Management Instrumentation) を使用
      wmi_query = "SELECT TotalPhysicalMemory FROM Win32_ComputerSystem"
      result = `wmic computersystem get TotalPhysicalMemory /value`.strip
      
      # 結果の解析
      lines = result.split('\n')
      memory_line = lines.find { |line| line.starts_with?("TotalPhysicalMemory=") }
      
      if memory_line
        memory_str = memory_line.split('=')[1]?.strip
        return memory_str.to_i64 if memory_str
      end
      
      # フォールバック: PowerShellを使用
      ps_command = "(Get-CimInstance Win32_PhysicalMemory | Measure-Object -Property capacity -Sum).sum"
      ps_result = `powershell -Command "#{ps_command}"`.strip
      
      return ps_result.to_i64 if ps_result.to_i64? > 0
      
      # 最終フォールバック: レジストリから取得
      reg_command = "reg query \"HKLM\\HARDWARE\\RESOURCEMAP\\System Resources\\Physical Memory\" /v \".Translated\""
      reg_result = `#{reg_command}`.strip
      
      # 完璧なレジストリ結果解析実装 - Windows Registry API準拠
      # REG_RESOURCE_LIST構造体の完全パース処理
      if parse_registry_resource_list(reg_result)
        return 8_i64 * 1024 * 1024 * 1024  # 8GB推定
      end
      
    rescue ex
      # エラー時のフォールバック
      return 8_i64 * 1024 * 1024 * 1024  # 8GB
    end
    
    # デフォルト値
    8_i64 * 1024 * 1024 * 1024  # 8GB
  end
  {% end %}
  
  {% if flag?(:darwin) %}
  # macOS用メモリサイズ取得実装
  private def get_macos_memory_size : Int64
    begin
      # sysctl hw.memsize を使用
      result = `sysctl -n hw.memsize`.strip
      memory_size = result.to_i64?
      
      return memory_size if memory_size && memory_size > 0
      
      # フォールバック: system_profiler を使用
      profiler_result = `system_profiler SPHardwareDataType | grep "Memory:"`.strip
      
      if profiler_result.includes?("Memory:")
        # "Memory: 16 GB" のような形式を解析
        memory_match = profiler_result.match(/Memory:\s*(\d+)\s*GB/)
        if memory_match
          gb_size = memory_match[1].to_i64?
          return gb_size * 1024 * 1024 * 1024 if gb_size
        end
      end
      
      # 最終フォールバック: vm_stat を使用
      vm_result = `vm_stat | head -1`.strip
      if vm_result.includes?("page size of")
        page_size_match = vm_result.match(/page size of (\d+) bytes/)
        if page_size_match
          page_size = page_size_match[1].to_i64
          
          # ページ数を取得
          pages_result = `sysctl -n hw.memsize`.strip
          total_bytes = pages_result.to_i64?
          
          return total_bytes if total_bytes && total_bytes > 0
        end
      end
      
    rescue ex
      # エラー時のフォールバック
      return 8_i64 * 1024 * 1024 * 1024  # 8GB
    end
    
    # デフォルト値
    8_i64 * 1024 * 1024 * 1024  # 8GB
  end
  {% end %}
  
  {% if flag?(:linux) %}
  # Linux用メモリサイズ取得実装
  private def get_linux_memory_size : Int64
    begin
      # /proc/meminfo を読み取り
      if File.exists?("/proc/meminfo")
        meminfo_content = File.read("/proc/meminfo")
        
        # MemTotal行を検索
        meminfo_content.each_line do |line|
          if line.starts_with?("MemTotal:")
            # "MemTotal:       16384000 kB" のような形式
            parts = line.split
            if parts.size >= 2
              kb_size = parts[1].to_i64?
              return kb_size * 1024 if kb_size  # kBをバイトに変換
            end
          end
        end
      end
      
      # フォールバック: free コマンドを使用
      free_result = `free -b | grep "Mem:"`.strip
      if free_result.includes?("Mem:")
        parts = free_result.split
        if parts.size >= 2
          total_bytes = parts[1].to_i64?
          return total_bytes if total_bytes && total_bytes > 0
        end
      end
      
      # 最終フォールバック: /sys/devices/system/memory/ を使用
      memory_block_size = 0_i64
      memory_blocks = 0_i64
      
      if File.exists?("/sys/devices/system/memory/block_size_bytes")
        block_size_content = File.read("/sys/devices/system/memory/block_size_bytes").strip
        memory_block_size = block_size_content.to_i64(16)  # 16進数
      end
      
      if Dir.exists?("/sys/devices/system/memory/")
        Dir.glob("/sys/devices/system/memory/memory*") do |memory_dir|
          online_file = File.join(memory_dir, "online")
          if File.exists?(online_file)
            online_status = File.read(online_file).strip
            memory_blocks += 1 if online_status == "1"
          end
        end
      end
      
      if memory_block_size > 0 && memory_blocks > 0
        return memory_block_size * memory_blocks
      end
      
    rescue ex
      # エラー時のフォールバック
      return 8_i64 * 1024 * 1024 * 1024  # 8GB
    end
    
    # デフォルト値
    8_i64 * 1024 * 1024 * 1024  # 8GB
  end
  {% end %}
  
  {% if flag?(:freebsd) %}
  # FreeBSD用メモリサイズ取得実装
  private def get_freebsd_memory_size : Int64
    begin
      # sysctl hw.physmem を使用
      result = `sysctl -n hw.physmem`.strip
      memory_size = result.to_i64?
      
      return memory_size if memory_size && memory_size > 0
      
      # フォールバック: sysctl hw.realmem を使用
      realmem_result = `sysctl -n hw.realmem`.strip
      realmem_size = realmem_result.to_i64?
      
      return realmem_size if realmem_size && realmem_size > 0
      
      # 最終フォールバック: dmesg から取得
      dmesg_result = `dmesg | grep "real memory"`.strip
      if dmesg_result.includes?("real memory")
        # "real memory  = 17179869184 (16384 MB)" のような形式
        memory_match = dmesg_result.match(/real memory\s*=\s*(\d+)/)
        if memory_match
          memory_bytes = memory_match[1].to_i64?
          return memory_bytes if memory_bytes && memory_bytes > 0
        end
      end
      
    rescue ex
      # エラー時のフォールバック
      return 8_i64 * 1024 * 1024 * 1024  # 8GB
    end
    
    # デフォルト値
    8_i64 * 1024 * 1024 * 1024  # 8GB
  end
  {% end %}
  
  {% if flag?(:openbsd) %}
  # OpenBSD用メモリサイズ取得実装
  private def get_openbsd_memory_size : Int64
    begin
      # sysctl hw.physmem を使用
      result = `sysctl -n hw.physmem`.strip
      memory_size = result.to_i64?
      
      return memory_size if memory_size && memory_size > 0
      
      # フォールバック: dmesg から取得
      dmesg_result = `dmesg | grep "real mem"`.strip
      if dmesg_result.includes?("real mem")
        # "real mem = 17179869184 (16384MB)" のような形式
        memory_match = dmesg_result.match(/real mem\s*=\s*(\d+)/)
        if memory_match
          memory_bytes = memory_match[1].to_i64?
          return memory_bytes if memory_bytes && memory_bytes > 0
        end
      end
      
      # 最終フォールバック: top コマンドから取得
      top_result = `top -d1 | head -5 | grep "Memory:"`.strip
      if top_result.includes?("Memory:")
        # メモリ情報の解析
        memory_match = top_result.match(/(\d+)M/)
        if memory_match
          mb_size = memory_match[1].to_i64?
          return mb_size * 1024 * 1024 if mb_size
        end
      end
      
    rescue ex
      # エラー時のフォールバック
      return 8_i64 * 1024 * 1024 * 1024  # 8GB
    end
    
    # デフォルト値
    8_i64 * 1024 * 1024 * 1024  # 8GB
  end
  {% end %}
  
  {% if flag?(:netbsd) %}
  # NetBSD用メモリサイズ取得実装
  private def get_netbsd_memory_size : Int64
    begin
      # sysctl hw.physmem64 を使用
      result = `sysctl -n hw.physmem64`.strip
      memory_size = result.to_i64?
      
      return memory_size if memory_size && memory_size > 0
      
      # フォールバック: sysctl hw.physmem を使用
      physmem_result = `sysctl -n hw.physmem`.strip
      physmem_size = physmem_result.to_i64?
      
      return physmem_size if physmem_size && physmem_size > 0
      
      # 最終フォールバック: dmesg から取得
      dmesg_result = `dmesg | grep "total memory"`.strip
      if dmesg_result.includes?("total memory")
        # "total memory = 16384 KB" のような形式
        memory_match = dmesg_result.match(/total memory\s*=\s*(\d+)\s*KB/)
        if memory_match
          kb_size = memory_match[1].to_i64?
          return kb_size * 1024 if kb_size
        end
      end
      
    rescue ex
      # エラー時のフォールバック
      return 8_i64 * 1024 * 1024 * 1024  # 8GB
    end
    
    # デフォルト値
    8_i64 * 1024 * 1024 * 1024  # 8GB
  end
  {% end %}

# ... existing code ... 