# zstd_simd.nim
## Zstandard圧縮/解凍のSIMD最適化バージョン

import std/[strutils, hashes, times, cpuinfo, options, algorithm]
import ../common/compression_base
import ../common/optimization
import ./zstd

when defined(amd64) or defined(i386):
  {.pragma: simd, codegenDecl: "__attribute__((target(\"sse4.1,sse4.2,avx,avx2\"))) $# $#$#".}
  
  # SIMD関連の定数
  const
    ZSTD_CHUNK_SIZE = 1024 * 1024  # 1MB チャンク
    ZSTD_MAX_THREADS = 8           # 最大スレッド数
  
  type
    ZstdSIMDOption* = object
      ## SIMD最適化されたZstd圧縮オプション
      level*: int              ## 圧縮レベル (1-22)
      useAVX2*: bool           ## AVX2命令を使用するか
      useSSE4*: bool           ## SSE4命令を使用するか
      useParallel*: bool       ## 並列処理を使用するか
      threadCount*: int        ## 使用スレッド数
      chunkSize*: int          ## 並列処理の分割サイズ
      adaptiveMode*: bool      ## データに応じて圧縮レベルを調整するか
  
  # AVX2命令セットを使用した高速CRC32計算
  proc crc32AVX2(data: pointer, len: int, crc: uint32 = 0): uint32 {.simd.} =
    ## AVX2命令を使用した高速CRC32計算
    if len <= 0:
      return crc
    
    var result = crc xor 0xFFFFFFFF'u32
    var p = cast[ptr UncheckedArray[uint8]](data)
    var i = 0
    
    # AVX2で処理（32バイトずつ）
    while i + 32 <= len:
      asm """
        vmovdqu ymm0, [%1 + %2]
        crc32 %0, %0, ymm0
      """ : "+r" (result) : "r" (p), "r" (i) : "ymm0"
      i += 32
    
    # 残りは通常処理
    while i < len:
      result = (result shr 8) xor crc32Table[(result and 0xFF) xor p[i].uint32]
      inc i
    
    return result xor 0xFFFFFFFF'u32
  
  # CRC32テーブル
  var crc32Table: array[256, uint32]
  
  # CRC32テーブルの初期化
  proc initCRC32Table() =
    ## CRC32テーブルを初期化
    for i in 0..255:
      var c = i.uint32
      for j in 0..7:
        if (c and 1) != 0:
          c = 0xEDB88320'u32 xor (c shr 1)
        else:
          c = c shr 1
      crc32Table[i] = c
  
  # テーブル初期化を実行
  initCRC32Table()
  
  # 並列Zstd圧縮用の内部関数
  proc parallelCompress(chunks: seq[string], options: ZstdSIMDOption): seq[string] =
    ## データチャンクを並列に圧縮
    result = newSeq[string](chunks.len)
    
    # 並列処理
    parallel:
      for i in 0 ..< chunks.len:
        spawn:
          # チャンクごとに最適なレベルを適用
          var level = options.level
          if options.adaptiveMode:
            # データパターンに応じてレベルを調整
            let entropy = calculateEntropy(chunks[i])
            if entropy < 0.5:  # 低エントロピー（繰り返しが多い）
              level = min(level + 3, 22)
            elif entropy > 7.5:  # 高エントロピー（ランダムに近い）
              level = max(level - 2, 1)
          
          result[i] = zstd.compress(chunks[i], level)
  
  # エントロピー計算（Shannon情報量）
  proc calculateEntropy(data: string): float =
    ## データのエントロピーを計算（Shannon情報量）
    if data.len == 0:
      return 0.0
    
    var freqs = newSeq[int](256)
    for c in data:
      inc freqs[ord(c)]
    
    var entropy = 0.0
    let total = data.len.float
    
    for freq in freqs:
      if freq > 0:
        let p = freq.float / total
        entropy -= p * log2(p)
    
    return entropy
  
  # データの圧縮可能性を評価
  proc evaluateCompressibility(data: string): float =
    ## データの圧縮可能性を0.0〜1.0の範囲で評価（高いほど圧縮しやすい）
    let entropy = calculateEntropy(data)
    # 8ビットのデータの理論最大エントロピーは8
    return 1.0 - (entropy / 8.0)
  
  # 検知関数
  proc hasSIMDSupport*(): bool =
    ## システムがSIMD命令をサポートしているか確認
    result = supportsSSE4 or supportsAVX2
  
  proc newZstdSIMDOption*(level: int = 3): ZstdSIMDOption =
    ## SIMD最適化されたZstdオプションを作成
    result = ZstdSIMDOption(
      level: level,
      useAVX2: supportsAVX2,
      useSSE4: supportsSSE4,
      useParallel: optimalThreadCount > 1,
      threadCount: min(optimalThreadCount, ZSTD_MAX_THREADS),
      chunkSize: ZSTD_CHUNK_SIZE,
      adaptiveMode: true
    )
  
  proc compressSIMD*(data: string, options: ZstdSIMDOption = newZstdSIMDOption()): string =
    ## SIMD最適化されたZstd圧縮
    # 小さなデータは標準圧縮を使用
    if data.len < 8192:
      return zstd.compress(data, options.level)
    
    # キャッシュから結果を取得
    let cached = getCachedCompressionResult(data, cfZstd, options.level)
    if cached.isSome:
      return cached.get
    
    var result: string
    
    # データサイズに基づいた並列圧縮の判断
    if options.useParallel and data.len > options.chunkSize * 2 and options.threadCount > 1:
      # データを複数のチャンクに分割
      var chunks: seq[string] = @[]
      var i = 0
      
      # 圧縮性の高いデータは大きめのチャンクに、低いものは小さめのチャンクに
      let compressibility = evaluateCompressibility(data)
      let adjustedChunkSize = 
        if compressibility > 0.7: options.chunkSize * 2
        elif compressibility < 0.3: options.chunkSize div 2
        else: options.chunkSize
      
      while i < data.len:
        let chunkSize = min(adjustedChunkSize, data.len - i)
        chunks.add(data[i..<i+chunkSize])
        i += chunkSize
      
      # 並列圧縮
      let compressedChunks = parallelCompress(chunks, options)
      
      # フレームヘッダとチャンクデータのサイズをシリアライズ
      result = ""
      for chunk in compressedChunks:
        # チャンクサイズをエンコード（4バイト）
        let size = chunk.len.uint32
        result.add(char((size and 0xFF).uint8))
        result.add(char(((size shr 8) and 0xFF).uint8))
        result.add(char(((size shr 16) and 0xFF).uint8))
        result.add(char(((size shr 24) and 0xFF).uint8))
        # 圧縮データを追加
        result.add(chunk)
    else:
      # 通常の圧縮処理
      result = zstd.compress(data, options.level)
    
    # 結果をキャッシュ
    cacheCompressionResult(data, result, cfZstd, options.level)
    
    return result
  
  proc decompressSIMD*(data: string): string =
    ## SIMD最適化されたZstd解凍
    # 小さなデータは標準解凍を使用
    if data.len < 8192:
      return zstd.decompress(data)
    
    # チャンクヘッダ形式かをチェック
    if data.len >= 8:
      let magicBytes = cast[ptr uint32](unsafeAddr data[0])[]
      if magicBytes != 0xFD2FB528'u32:  # Zstandard標準マジックナンバー
        # カスタムフォーマットの可能性があるので解析
        var i = 0
        var result = ""
        
        while i < data.len:
          if i + 4 > data.len:
            # 不正なフォーマット
            return zstd.decompress(data)
          
          # チャンクサイズを取得
          let size = uint32(ord(data[i])) or
                    (uint32(ord(data[i+1])) shl 8) or
                    (uint32(ord(data[i+2])) shl 16) or
                    (uint32(ord(data[i+3])) shl 24)
          
          i += 4
          
          if i + size.int > data.len:
            # 不正なフォーマット
            return zstd.decompress(data)
          
          # チャンクを解凍
          let chunkData = data[i..<i+size.int]
          result.add(zstd.decompress(chunkData))
          
          i += size.int
        
        return result
    
    # 通常のZstd形式なら標準解凍を使用
    return zstd.decompress(data)

else:
  # 非SIMD対応プラットフォーム用のフォールバック
  type
    ZstdSIMDOption* = object
      ## 非SIMD環境用のZstdオプション（標準と同じ）
      level*: int           ## 圧縮レベル (1-22)
      adaptiveMode*: bool   ## データに応じて圧縮レベルを調整するか
  
  proc hasSIMDSupport*(): bool =
    ## SIMD命令をサポートしているか確認
    return false
  
  proc newZstdSIMDOption*(level: int = 3): ZstdSIMDOption =
    ## 標準のZstdオプションを作成
    result = ZstdSIMDOption(
      level: level,
      adaptiveMode: true
    )
  
  proc compressSIMD*(data: string, options: ZstdSIMDOption = newZstdSIMDOption()): string =
    ## 通常のZstd圧縮にフォールバック
    var level = options.level
    
    # 適応モードが有効なら、データに応じてレベルを調整
    if options.adaptiveMode and data.len > 1024:
      let sample = data[0..<min(1024, data.len)]
      var freqs = newSeq[int](256)
      for c in sample:
        inc freqs[ord(c)]
      
      var entropy = 0.0
      let total = sample.len.float
      
      for freq in freqs:
        if freq > 0:
          let p = freq.float / total
          entropy -= p * log2(p)
      
      # エントロピーに基づいてレベルを調整
      if entropy < 3.0:
        level = min(level + 2, 22)
      elif entropy > 7.0:
        level = max(level - 1, 1)
    
    return zstd.compress(data, level)
  
  proc decompressSIMD*(data: string): string =
    ## 通常のZstd解凍にフォールバック
    return zstd.decompress(data) 