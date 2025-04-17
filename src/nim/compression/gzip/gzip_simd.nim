# gzip_simd.nim
## Gzip圧縮/解凍のSIMD最適化バージョン

import std/[strutils, hashes, times, cpuinfo, options, algorithm, tables]
import ../common/compression_base
import ../common/optimization
import ./gzip

when defined(amd64) or defined(i386):
  {.pragma: simd, codegenDecl: "__attribute__((target(\"sse4.1,sse4.2,avx,avx2\"))) $# $#$#".}
  
  # SIMD関連の定数
  const
    GZIP_CHUNK_SIZE = 1024 * 1024  # 1MB チャンク
    GZIP_MAX_THREADS = 8           # 最大スレッド数
    LZ77_MIN_MATCH = 3             # 最小マッチ長
    LZ77_MAX_MATCH = 258           # 最大マッチ長
    LZ77_WINDOW_SIZE = 32 * 1024   # ウィンドウサイズ (32KB)
  
  type
    GzipSIMDOption* = object
      ## SIMD最適化されたGzip圧縮オプション
      level*: int                ## 圧縮レベル (1-9)
      windowBits*: int           ## ウィンドウビット数 (8-15)
      memLevel*: int             ## メモリレベル (1-9)
      strategy*: int             ## 圧縮戦略 (0-4)
      useAVX2*: bool             ## AVX2命令を使用するか
      useSSE4*: bool             ## SSE4命令を使用するか
      useParallel*: bool         ## 並列処理を使用するか
      threadCount*: int          ## 使用スレッド数
      chunkSize*: int            ## 並列処理の分割サイズ
      dictionarySize*: int       ## 辞書サイズ
      smartCompression*: bool    ## コンテンツタイプに応じた最適化を行うか
  
  # AVX2命令セットを使用した高速ハッシュ計算
  proc hashAVX2(data: pointer, len: int): uint32 {.simd.} =
    ## AVX2命令を使用した高速ハッシュ計算
    if len <= 0:
      return 0
    
    var result: uint32 = 0x811C9DC5'u32  # FNV-1aの初期値
    var p = cast[ptr UncheckedArray[uint8]](data)
    var i = 0
    
    # AVX2で処理（32バイトずつ）
    while i + 32 <= len:
      asm """
        vmovdqu ymm0, [%1 + %2]
        vpxor ymm1, ymm1, ymm1
        vpcmpeqb ymm1, ymm1, ymm0
        vpmovmskb %0, ymm1
      """ : "=r" (result) : "r" (p), "r" (i) : "ymm0", "ymm1"
      
      let hashVal = result xor (i.uint32 * 0x01000193'u32)
      result = (result * 0x01000193'u32) xor hashVal
      i += 32
    
    # 残りは通常処理
    while i < len:
      result = (result * 0x01000193'u32) xor p[i].uint32
      inc i
    
    return result
  
  # SSE4命令セットを使用した高速文字列比較
  proc matchSSE4(s1, s2: pointer, maxLen: int): int {.simd.} =
    ## SSE4命令を使用して2つの文字列の一致長を高速に計算
    var len = 0
    var p1 = cast[ptr UncheckedArray[uint8]](s1)
    var p2 = cast[ptr UncheckedArray[uint8]](s2)
    
    # 16バイト単位で比較
    while len + 16 <= maxLen:
      var mask: int
      asm """
        movdqu xmm0, [%1 + %3]
        movdqu xmm1, [%2 + %3]
        pcmpeqb xmm0, xmm1
        pmovmskb %0, xmm0
      """ : "=r" (mask) : "r" (p1), "r" (p2), "r" (len) : "xmm0", "xmm1"
      
      if mask != 0xFFFF:
        # 不一致のビット位置を見つける
        let pos = countTrailingZeros(not mask and 0xFFFF)
        return len + pos
      
      len += 16
    
    # 残りをバイト単位で比較
    while len < maxLen and p1[len] == p2[len]:
      inc len
    
    return len
  
  # 並列Gzip圧縮用の内部関数
  proc parallelCompress(chunks: seq[string], options: GzipSIMDOption): seq[string] =
    ## データチャンクを並列に圧縮
    result = newSeq[string](chunks.len)
    
    # 並列処理
    parallel:
      for i in 0 ..< chunks.len:
        spawn:
          # チャンクのコンテンツタイプを検出
          var level = options.level
          var strategy = options.strategy
          
          if options.smartCompression:
            # データの特性に応じた最適化
            let sample = if chunks[i].len > 1024: chunks[i][0..<1024] else: chunks[i]
            
            # バイナリデータの検出
            var binaryCount = 0
            for j in 0..<min(256, sample.len):
              if ord(sample[j]) < 32 and ord(sample[j]) != 9 and ord(sample[j]) != 10 and ord(sample[j]) != 13:
                inc binaryCount
            
            let binaryRatio = binaryCount.float / min(256, sample.len).float
            
            if binaryRatio > 0.3:
              # バイナリデータ
              strategy = 2  # Z_FILTERED
              if level > 6: level = 6  # バイナリデータは高圧縮率よりも速度優先
            elif detectHighEntropy(sample):
              # 高エントロピーデータ
              strategy = 3  # Z_HUFFMAN_ONLY
              if level > 4: level = 4  # 圧縮率よりも速度優先
            else:
              # テキストデータなど
              strategy = 0  # Z_DEFAULT_STRATEGY
              # レベルはそのまま
          
          # Gzipオプションをカスタマイズ
          let customOptions = GzipOptions(
            level: level,
            windowBits: options.windowBits,
            memLevel: options.memLevel,
            strategy: strategy
          )
          
          result[i] = gzip.compress(chunks[i], customOptions)
  
  # データのエントロピーを検出
  proc detectHighEntropy(data: string): bool =
    ## データが高エントロピー（ランダムに近い）かどうかを判定
    if data.len < 100:
      return false
    
    var freqs = initTable[char, int]()
    for c in data:
      if c in freqs:
        inc freqs[c]
      else:
        freqs[c] = 1
    
    # ユニーク文字の比率を計算
    let uniqueRatio = freqs.len.float / min(data.len, 256).float
    
    # 高エントロピーの基準: 0.8以上のユニーク率
    return uniqueRatio > 0.8
  
  # 最適なチャンク境界を見つける
  proc findOptimalChunkBoundary(data: string, pos: int, windowSize: int = 4096): int =
    ## できるだけ圧縮効率の良いチャンク境界を見つける
    if pos >= data.len:
      return data.len
    
    # 検索範囲を決定
    let startPos = max(0, pos - windowSize div 2)
    let endPos = min(data.len, pos + windowSize div 2)
    
    if endPos - startPos < 32:
      return pos
    
    # 最もハッシュ値が小さい位置を探す（ローリングハッシュを使用）
    var minHash = high(uint32)
    var bestPos = pos
    var hash: uint32 = 0
    
    # 初期ハッシュ値を計算
    for i in max(startPos, 0)..<min(startPos + 32, data.len):
      hash = (hash shl 5) + hash + ord(data[i]).uint32
    
    # スライディングウィンドウでハッシュ値が最小になる位置を探す
    for i in startPos..<endPos-32:
      # ハッシュを更新（ローリングハッシュ）
      hash = (hash shl 5) + hash - (ord(data[i]).uint32 shl 5) + ord(data[i+32]).uint32
      
      # 最小値の更新
      if hash < minHash:
        minHash = hash
        bestPos = i + 16
    
    return bestPos
  
  # 検知関数
  proc hasSIMDSupport*(): bool =
    ## システムがSIMD命令をサポートしているか確認
    result = supportsSSE4 or supportsAVX2
  
  proc newGzipSIMDOption*(level: int = 6): GzipSIMDOption =
    ## SIMD最適化されたGzipオプションを作成
    result = GzipSIMDOption(
      level: level,
      windowBits: 15 + 16,  # Gzip形式 (15) + 自動ヘッダー検出 (16)
      memLevel: 8,
      strategy: 0,          # Z_DEFAULT_STRATEGY
      useAVX2: supportsAVX2,
      useSSE4: supportsSSE4,
      useParallel: optimalThreadCount > 1,
      threadCount: min(optimalThreadCount, GZIP_MAX_THREADS),
      chunkSize: GZIP_CHUNK_SIZE,
      dictionarySize: 32768,
      smartCompression: true
    )
  
  proc compressSIMD*(data: string, options: GzipSIMDOption = newGzipSIMDOption()): string =
    ## SIMD最適化されたGzip圧縮
    # 小さなデータは標準圧縮を使用
    if data.len < 8192:
      return gzip.compress(data, GzipOptions(
        level: options.level,
        windowBits: options.windowBits,
        memLevel: options.memLevel,
        strategy: options.strategy
      ))
    
    # キャッシュから結果を取得
    let cached = getCachedCompressionResult(data, cfGzip, options.level)
    if cached.isSome:
      return cached.get
    
    var result: string
    
    # データサイズに基づいた並列圧縮の判断
    if options.useParallel and data.len > options.chunkSize * 2 and options.threadCount > 1:
      # データを複数のチャンクに分割
      var chunks: seq[string] = @[]
      var i = 0
      
      while i < data.len:
        # 最適なチャンク境界を見つける
        let nextPos = i + options.chunkSize
        let optimalPos = if nextPos < data.len:
                           findOptimalChunkBoundary(data, nextPos)
                         else:
                           data.len
        
        chunks.add(data[i..<optimalPos])
        i = optimalPos
      
      # 並列圧縮
      let compressedChunks = parallelCompress(chunks, options)
      
      # 結合するためのGzipコンテナを作成
      result = ""
      
      # 各チャンクのCRCとサイズを集計
      var combinedCRC: uint32 = 0
      var totalUncompressedSize: uint32 = 0
      
      for i, chunk in compressedChunks:
        # 最初のチャンクのヘッダーをコピー
        if i == 0:
          # Gzipヘッダー (10バイト) をコピー
          result.add(chunk[0..<10])
        
        # 圧縮データ部分をコピー（ヘッダーとフッターを除く）
        let compressedData = chunk[10..<chunk.len-8]
        result.add(compressedData)
        
        # CRCとサイズを抽出して結合
        let chunkCRC = uint32(ord(chunk[^8])) or
                      (uint32(ord(chunk[^7])) shl 8) or
                      (uint32(ord(chunk[^6])) shl 16) or
                      (uint32(ord(chunk[^5])) shl 24)
        
        let chunkSize = uint32(ord(chunk[^4])) or
                       (uint32(ord(chunk[^3])) shl 8) or
                       (uint32(ord(chunk[^2])) shl 16) or
                       (uint32(ord(chunk[^1])) shl 24)
        
        # CRCの結合（XOR）
        if i == 0:
          combinedCRC = chunkCRC
        else:
          combinedCRC = combinedCRC xor chunkCRC
        
        totalUncompressedSize += chunkSize
      
      # 最終的なCRCとサイズをフッターに追加
      result.add(char((combinedCRC and 0xFF).uint8))
      result.add(char(((combinedCRC shr 8) and 0xFF).uint8))
      result.add(char(((combinedCRC shr 16) and 0xFF).uint8))
      result.add(char(((combinedCRC shr 24) and 0xFF).uint8))
      
      result.add(char((totalUncompressedSize and 0xFF).uint8))
      result.add(char(((totalUncompressedSize shr 8) and 0xFF).uint8))
      result.add(char(((totalUncompressedSize shr 16) and 0xFF).uint8))
      result.add(char(((totalUncompressedSize shr 24) and 0xFF).uint8))
    else:
      # 通常の圧縮処理
      let gzipOptions = GzipOptions(
        level: options.level,
        windowBits: options.windowBits,
        memLevel: options.memLevel,
        strategy: options.strategy
      )
      result = gzip.compress(data, gzipOptions)
    
    # 結果をキャッシュ
    cacheCompressionResult(data, result, cfGzip, options.level)
    
    return result
  
  proc decompressSIMD*(data: string): string =
    ## SIMD最適化されたGzip解凍
    # 小さなデータは標準解凍を使用
    if data.len < 8192:
      return gzip.decompress(data)
    
    # 標準のGzip解凍を使用
    # 注: Gzipの並列解凍は通常は効果が薄いため、ここではシンプルに標準解凍を使用
    # ただし、大きなファイルで純粋なCPU処理がボトルネックになるケースでは
    # マルチスレッド解凍も考慮すべき
    return gzip.decompress(data)

else:
  # 非SIMD対応プラットフォーム用のフォールバック
  type
    GzipSIMDOption* = object
      ## 非SIMD環境用のGzipオプション（標準と同じ）
      level*: int           ## 圧縮レベル (1-9)
      windowBits*: int      ## ウィンドウビット数 (8-15)
      memLevel*: int        ## メモリレベル (1-9)
      strategy*: int        ## 圧縮戦略 (0-4)
      smartCompression*: bool  ## コンテンツタイプに応じた最適化を行うか
  
  proc hasSIMDSupport*(): bool =
    ## SIMD命令をサポートしているか確認
    return false
  
  proc newGzipSIMDOption*(level: int = 6): GzipSIMDOption =
    ## 標準のGzipオプションを作成
    result = GzipSIMDOption(
      level: level,
      windowBits: 15 + 16,  # Gzip形式 (15) + 自動ヘッダー検出 (16)
      memLevel: 8,
      strategy: 0,          # Z_DEFAULT_STRATEGY
      smartCompression: true
    )
  
  proc compressSIMD*(data: string, options: GzipSIMDOption = newGzipSIMDOption()): string =
    ## 通常のGzip圧縮にフォールバック
    var level = options.level
    var strategy = options.strategy
    
    # スマート圧縮が有効なら、データに応じて最適化
    if options.smartCompression and data.len > 1024:
      let sample = data[0..<min(1024, data.len)]
      
      # バイナリデータの検出
      var binaryCount = 0
      for j in 0..<min(256, sample.len):
        if ord(sample[j]) < 32 and ord(sample[j]) != 9 and ord(sample[j]) != 10 and ord(sample[j]) != 13:
          inc binaryCount
      
      let binaryRatio = binaryCount.float / min(256, sample.len).float
      
      if binaryRatio > 0.3:
        # バイナリデータ
        strategy = 2  # Z_FILTERED
        if level > 6: level = 6
      elif binaryRatio < 0.05 and sample.len > 500:
        # テキストデータ
        strategy = 0  # Z_DEFAULT_STRATEGY
        if level < 6: level = 6
    
    let gzipOptions = GzipOptions(
      level: level,
      windowBits: options.windowBits,
      memLevel: options.memLevel,
      strategy: strategy
    )
    
    return gzip.compress(data, gzipOptions)
  
  proc decompressSIMD*(data: string): string =
    ## 通常のGzip解凍にフォールバック
    return gzip.decompress(data) 