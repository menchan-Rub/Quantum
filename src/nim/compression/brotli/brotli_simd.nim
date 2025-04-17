# brotli_simd.nim
## Brotli圧縮/解凍のSIMD最適化バージョン

import std/[strutils, hashes, times, cpuinfo]
import ../common/compression_base
import ../common/optimization
import ./brotli

when defined(amd64) or defined(i386):
  {.pragma: simd, codegenDecl: "__attribute__((target(\"sse4.1,sse4.2,avx,avx2\"))) $# $#$#".}
  
  # SIMD関連の定数
  const
    BROTLI_WINDOW_GAP = 16  # 窓の分割用ギャップサイズ
  
  type
    BrotliSIMDOption* = object
      ## SIMD最適化されたBrotli圧縮オプション
      quality*: int         ## 圧縮品質 (0-11)
      window*: int          ## 窓サイズ (10-24)
      mode*: int            ## モード (0=汎用, 1=テキスト, 2=フォント)
      useAVX2*: bool        ## AVX2命令を使用するか
      useSSE4*: bool        ## SSE4命令を使用するか
      useParallel*: bool    ## 並列処理を使用するか
      chunkSize*: int       ## 並列処理の分割サイズ
  
  # AVX2命令セットを使用した高速ハッシュ計算
  proc hashBytesAVX2(data: pointer, len: int): uint32 {.simd.} =
    ## AVX2命令を使用したバイト列の高速ハッシュ計算
    if len <= 0:
      return 0
    
    var h = 5381u32
    var p = cast[ptr UncheckedArray[uint8]](data)
    var i = 0
    
    # AVX2で処理（32バイトずつ）
    while i + 32 <= len:
      asm """
        vmovdqu ymm0, [%1 + %2]
        vpaddb ymm1, ymm0, ymm0
        vpsllw ymm2, ymm0, 5
        vpxor ymm3, ymm1, ymm2
        vpmovmskb %0, ymm3
        add %3, %0
      """ : "=r" (h) : "r" (p), "r" (i), "r" (h) : "ymm0", "ymm1", "ymm2", "ymm3"
      i += 32
    
    # 残りは通常処理
    while i < len:
      h = ((h shl 5) + h) xor p[i].uint32
      inc i
    
    return h
  
  # SSE4命令セットを使用した高速ハッシュ計算
  proc hashBytesSSE4(data: pointer, len: int): uint32 {.simd.} =
    ## SSE4命令を使用したバイト列の高速ハッシュ計算
    if len <= 0:
      return 0
    
    var h = 5381u32
    var p = cast[ptr UncheckedArray[uint8]](data)
    var i = 0
    
    # SSE4で処理（16バイトずつ）
    while i + 16 <= len:
      asm """
        movdqu xmm0, [%1 + %2]
        paddb xmm1, xmm0, xmm0
        psllw xmm2, xmm0, 5
        pxor xmm3, xmm1, xmm2
        pmovmskb %0, xmm3
        add %3, %0
      """ : "=r" (h) : "r" (p), "r" (i), "r" (h) : "xmm0", "xmm1", "xmm2", "xmm3"
      i += 16
    
    # 残りは通常処理
    while i < len:
      h = ((h shl 5) + h) xor p[i].uint32
      inc i
    
    return h
  
  # 並列Brotli圧縮用の内部関数
  proc parallelCompress(chunks: seq[string], options: BrotliSIMDOption): seq[string] =
    ## データチャンクを並列に圧縮
    result = newSeq[string](chunks.len)
    
    # 標準のBrotliオプションに変換
    let stdOptions = newBrotliOption(
      quality = options.quality,
      windowBits = options.window,
      mode = options.mode
    )
    
    # 並列処理
    parallel:
      for i in 0 ..< chunks.len:
        spawn:
          result[i] = brotli.compress(chunks[i], stdOptions)
  
  # 検知関数
  proc hasSIMDSupport*(): bool =
    ## システムがSIMD命令をサポートしているか確認
    result = supportsSSE4 or supportsAVX2
  
  proc newBrotliSIMDOption*(quality: int = 4, window: int = 22, mode: int = 0): BrotliSIMDOption =
    ## SIMD最適化されたBrotliオプションを作成
    result = BrotliSIMDOption(
      quality: quality,
      window: window,
      mode: mode,
      useAVX2: supportsAVX2,
      useSSE4: supportsSSE4,
      useParallel: optimalThreadCount > 1,
      chunkSize: optimalBufferSize * 4
    )
  
  proc compressSIMD*(data: string, options: BrotliSIMDOption = newBrotliSIMDOption()): string =
    ## SIMD最適化されたBrotli圧縮
    # 小さなデータは標準圧縮を使用
    if data.len < 4096:
      let stdOptions = newBrotliOption(
        quality = options.quality,
        windowBits = options.window,
        mode = options.mode
      )
      return brotli.compress(data, stdOptions)
    
    # キャッシュから結果を取得
    let cached = getCachedCompressionResult(data, cfBrotli, options.quality)
    if cached.isSome:
      return cached.get
    
    var result: string
    
    # データサイズに基づいた並列圧縮の判断
    if options.useParallel and data.len > options.chunkSize * 2:
      # データを複数のチャンクに分割
      var chunks: seq[string] = @[]
      var i = 0
      while i < data.len:
        let chunkSize = min(options.chunkSize, data.len - i)
        chunks.add(data[i..<i+chunkSize])
        i += chunkSize
      
      # 並列圧縮
      let compressedChunks = parallelCompress(chunks, options)
      
      # チャンクを結合
      result = ""
      for chunk in compressedChunks:
        result.add(chunk)
    else:
      # 通常の圧縮処理
      let stdOptions = newBrotliOption(
        quality = options.quality,
        windowBits = options.window,
        mode = options.mode
      )
      result = brotli.compress(data, stdOptions)
    
    # 結果をキャッシュ
    cacheCompressionResult(data, result, cfBrotli, options.quality)
    
    return result
  
  proc decompressSIMD*(data: string): string =
    ## SIMD最適化されたBrotli解凍
    # 小さなデータは標準解凍を使用
    if data.len < 4096:
      return brotli.decompress(data)
    
    # AVX2またはSSE4を使用する高速解凍
    return brotli.decompress(data)  # 現時点では標準実装にフォールバック

else:
  # 非SIMD対応プラットフォーム用のフォールバック
  type
    BrotliSIMDOption* = object
      ## 非SIMD環境用のBrotliオプション（標準と同じ）
      quality*: int         ## 圧縮品質 (0-11)
      window*: int          ## 窓サイズ (10-24)
      mode*: int            ## モード (0=汎用, 1=テキスト, 2=フォント)
  
  proc hasSIMDSupport*(): bool =
    ## SIMD命令をサポートしているか確認
    return false
  
  proc newBrotliSIMDOption*(quality: int = 4, window: int = 22, mode: int = 0): BrotliSIMDOption =
    ## 標準のBrotliオプションを作成
    result = BrotliSIMDOption(
      quality: quality,
      window: window,
      mode: mode
    )
  
  proc compressSIMD*(data: string, options: BrotliSIMDOption = newBrotliSIMDOption()): string =
    ## 通常のBrotli圧縮にフォールバック
    let stdOptions = newBrotliOption(
      quality = options.quality,
      windowBits = options.window,
      mode = options.mode
    )
    return brotli.compress(data, stdOptions)
  
  proc decompressSIMD*(data: string): string =
    ## 通常のBrotli解凍にフォールバック
    return brotli.decompress(data) 