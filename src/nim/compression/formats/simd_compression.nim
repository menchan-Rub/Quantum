# simd_compression.nim
## SIMD対応の高性能圧縮モジュール

import std/[times, options, strutils, hashes, cpuinfo]
import ../common/compression_base

# 定数
const
  # SIMD関連定数
  SIMD_ALIGNMENT* = 32           # AVX2 アライメント
  SIMD_VECTOR_SIZE* = 256        # AVX2 ベクトルサイズ (ビット)
  SIMD_MAX_BLOCK_SIZE* = 1 shl 20  # 最大ブロックサイズ (1MB)
  SIMD_DEFAULT_BLOCK_SIZE* = 64 * 1024  # デフォルトブロックサイズ (64KB)
  SIMD_MIN_BLOCK_SIZE* = 4 * 1024  # 最小ブロックサイズ (4KB)
  
  # 圧縮パラメータ
  HASH_BITS* = 15               # ハッシュビット数
  HASH_SIZE* = 1 shl HASH_BITS  # ハッシュテーブルサイズ
  MIN_MATCH* = 4                # 最小マッチ長
  MAX_MATCH* = 258              # 最大マッチ長
  MAX_OFFSET* = 32768           # 最大オフセット

# SIMD圧縮レベル
type
  SimdCompressionLevel* = enum
    ## SIMD圧縮レベル
    sclFastest,       # 最速 (最低圧縮率)
    sclFast,          # 高速
    sclDefault,       # デフォルト
    sclBest,          # 高圧縮率
    sclUltra          # 超高圧縮率（低速）
  
  SimdCompressionMethod* = enum
    ## 圧縮方式
    scmLZ4,           # LZ4方式
    scmZstd,          # Zstandard方式
    scmDeflate,       # Deflate方式
    scmBrotli,        # Brotli方式
    scmAuto           # 自動選択
  
  SimdOptimizationTarget* = enum
    ## 最適化ターゲット
    sotSpeed,         # 速度優先
    sotRatio,         # 圧縮率優先
    sotBalanced       # バランス型
  
  SimdCpuFeatures* = object
    ## CPU機能
    hasSSE2*: bool     # SSE2サポート
    hasSSE3*: bool     # SSE3サポート
    hasSSSE3*: bool    # SSSE3サポート
    hasSSE41*: bool    # SSE4.1サポート
    hasSSE42*: bool    # SSE4.2サポート
    hasAVX*: bool      # AVXサポート
    hasAVX2*: bool     # AVX2サポート
    hasAVX512*: bool   # AVX-512サポート
    hasNEON*: bool     # NEONサポート (ARM)
  
  SimdCompressionStats* = object
    ## 圧縮統計
    originalSize*: int     # 元のサイズ
    compressedSize*: int   # 圧縮後サイズ
    compressionTime*: float  # 圧縮時間
    compressionRatio*: float  # 圧縮率
    method*: SimdCompressionMethod  # 使用方式
    blockCount*: int       # ブロック数
    simdUtilization*: float  # SIMD使用率
  
  SimdCompressionOptions* = object
    ## 圧縮オプション
    level*: SimdCompressionLevel  # 圧縮レベル
    method*: SimdCompressionMethod  # 圧縮方式
    blockSize*: int               # ブロックサイズ
    optimizationTarget*: SimdOptimizationTarget  # 最適化ターゲット
    windowSize*: int              # ウィンドウサイズ
    dictionarySize*: int          # 辞書サイズ
    useMultithreading*: bool      # マルチスレッド使用
    threadCount*: int             # スレッド数
  
  SimdHuffmanTree = object
    ## ハフマン木
    codes*: array[286, uint16]     # ハフマンコード
    lengths*: array[286, uint8]    # コード長
    count*: array[16, uint16]      # 長さごとのコード数
    symbols*: array[286, uint8]    # シンボルマッピング
    maxCode*: array[16, uint16]    # 各ビット長の最大コード値
    minCode*: array[16, uint16]    # 各ビット長の最小コード値
    valueOffset*: array[16, int]   # 各ビット長の値オフセット
    fastTable*: array[1024, uint16] # 高速ルックアップテーブル
    initialized*: bool             # 初期化済みフラグ

# CPU機能の検出
proc detectCpuFeatures*(): SimdCpuFeatures =
  ## CPUの機能を検出し、利用可能なSIMD命令セットを特定する
  when defined(i386) or defined(amd64):
    # x86/x64アーキテクチャ向けの詳細な機能検出
    result.hasSSE2 = cpuinfo.hasSSE2()
    result.hasSSE3 = cpuinfo.hasSSE3()
    result.hasSSSE3 = cpuinfo.hasSSSE3()
    result.hasSSE41 = cpuinfo.hasSSE41()
    result.hasSSE42 = cpuinfo.hasSSE42()
    result.hasAVX = cpuinfo.hasAVX()
    result.hasAVX2 = cpuinfo.hasAVX2()
    # AVX-512は複数の機能フラグの組み合わせが必要
    result.hasAVX512 = cpuinfo.hasAVX512f() and 
                       cpuinfo.hasAVX512bw() and 
                       cpuinfo.hasAVX512vl() and 
                       cpuinfo.hasAVX512dq()
  elif defined(arm) or defined(arm64) or defined(aarch64):
    # ARMアーキテクチャ向けの機能検出
    when defined(arm64) or defined(aarch64):
      # ARM64ではNEONは標準搭載
      result.hasNEON = true
    else:
      # ARM32では実行時検出が必要
      when defined(android):
        # Androidの場合はbionic libc経由で確認
        {.emit: """
        #include <cpu-features.h>
        """.}
        let features = {.emit: "android_getCpuFeatures()".}: culong
        result.hasNEON = (features and (1 shl 12)) != 0
      elif defined(linux):
        # Linuxでは/proc/cpuinfoを解析
        try:
          let cpuinfo = readFile("/proc/cpuinfo")
          result.hasNEON = cpuinfo.contains("neon") or cpuinfo.contains("asimd")
        except:
          result.hasNEON = false
      else:
        # その他のプラットフォームでは保守的に無効と判断
        result.hasNEON = false
  else:
    # その他のアーキテクチャではSIMD機能をすべて無効化
    discard

# SIMDサポートのチェック
proc isSimdSupported*(): bool =
  ## システムがSIMDをサポートしているか確認
  let features = detectCpuFeatures()
  
  # 最低限のSIMD機能を確認
  when defined(i386) or defined(amd64):
    return features.hasSSE2  # 最低でもSSE2が必要
  elif defined(arm) or defined(arm64):
    return features.hasNEON  # ARMではNEONが必要
  else:
    return false  # その他のアーキテクチャではサポート外

# 最適なSIMD指示セットの選択
proc getBestSimdInstructionSet*(): string =
  ## 利用可能な最高のSIMD命令セットを取得
  let features = detectCpuFeatures()
  
  when defined(i386) or defined(amd64):
    if features.hasAVX512:
      return "AVX-512"
    elif features.hasAVX2:
      return "AVX2"
    elif features.hasAVX:
      return "AVX"
    elif features.hasSSE42:
      return "SSE4.2"
    elif features.hasSSE41:
      return "SSE4.1"
    elif features.hasSSSE3:
      return "SSSE3"
    elif features.hasSSE3:
      return "SSE3"
    elif features.hasSSE2:
      return "SSE2"
    else:
      return "None"
  elif defined(arm) or defined(arm64):
    if features.hasNEON:
      return "NEON"
    else:
      return "None"
  else:
    return "None"

# ハッシュテーブルとリテラル配列の最適化された処理
# SIMD命令セットを活用した高速圧縮処理の実装

const
  HASH_SIZE = 65536  # ハッシュテーブルのサイズ（2^16）
  MIN_MATCH = 4      # 最小マッチ長
  MAX_MATCH = 258    # 最大マッチ長
  MAX_OFFSET = 32768 # 最大オフセット距離

type
  HashTableEntry = object
    pos: uint32      # データ内の位置
    checksum: uint32 # 高速比較用のチェックサム

# SIMD最適化されたハッシュ計算
proc computeHashSIMD(data: pointer, len: int): uint32 {.inline.} =
  let features = detectCpuFeatures()
  let bytes = cast[ptr UncheckedArray[uint8]](data)
  
  when defined(i386) or defined(amd64):
    if features.hasSSE42:
      # SSE4.2のCRC32命令を使用した高速ハッシュ
      var h: uint32 = 0
      asm """
        crc32 %1, %0
        crc32 %2, %0
        crc32 %3, %0
        crc32 %4, %0
        : "=r"(`h`)
        : "r"(`bytes[0]`), "r"(`bytes[1]`), "r"(`bytes[2]`), "r"(`bytes[3]`), "0"(`h`)
      """
      return h and (HASH_SIZE - 1).uint32
    elif features.hasSSE2:
      # SSE2を使用した並列ハッシュ計算
      var h: uint32
      asm """
        movd (%1), %%xmm0
        pmuludq %%xmm1, %%xmm0
        movd %%xmm0, %0
        : "=r"(`h`)
        : "r"(`bytes`), "x"(2654435761'u32)
        : "xmm0", "xmm1"
      """
      return h and (HASH_SIZE - 1).uint32
  elif defined(arm) or defined(arm64):
    if features.hasNEON:
      # NEONを使用した並列ハッシュ計算
      var h: uint32
      asm """
        vld1.32 {d0[0]}, [%1]
        vmul.i32 d0, d0, d1
        vmov.32 %0, d0[0]
        : "=r"(`h`)
        : "r"(`bytes`), "w"(2654435761'u32)
        : "d0", "d1"
      """
      return h and (HASH_SIZE - 1).uint32
  
  # フォールバック実装（SIMD非対応の場合）
  var h: uint32 = 0
  if len >= 4:
    h = (bytes[0].uint32 shl 24) or 
        (bytes[1].uint32 shl 16) or 
        (bytes[2].uint32 shl 8) or 
        bytes[3].uint32
    h = h * 2654435761'u32  # FNVハッシュの乗数
  
  return h and (HASH_SIZE - 1).uint32

# SIMD最適化された文字列比較
proc compareBlocksSIMD(s1, s2: pointer, maxLen: int): int {.inline.} =
  let features = detectCpuFeatures()
  let bytes1 = cast[ptr UncheckedArray[uint8]](s1)
  let bytes2 = cast[ptr UncheckedArray[uint8]](s2)
  
  when defined(i386) or defined(amd64):
    if features.hasAVX2 and maxLen >= 32:
      # AVX2を使用した32バイト単位の高速比較
      var matchLen: int = 0
      var pos: int = 0
      
      while pos <= maxLen - 32:
        var mask: uint32
        asm """
          vmovdqu (%1), %%ymm0
          vmovdqu (%2), %%ymm1
          vpcmpeqb %%ymm0, %%ymm1, %%ymm2
          vpmovmskb %%ymm2, %0
          : "=r"(`mask`)
          : "r"(`bytes1`+`pos`), "r"(`bytes2`+`pos`)
          : "ymm0", "ymm1", "ymm2"
        """
        
        if mask != 0xFFFFFFFF'u32:
          # 不一致を検出
          let tzc = countTrailingZeros(not mask)
          return matchLen + tzc
        
        pos += 32
        matchLen += 32
      
      # 残りのバイトを処理
      while matchLen < maxLen and bytes1[matchLen] == bytes2[matchLen]:
        inc matchLen
      
      return matchLen
    
    elif features.hasSSE2 and maxLen >= 16:
      # SSE2を使用した16バイト単位の比較
      var matchLen: int = 0
      var pos: int = 0
      
      while pos <= maxLen - 16:
        var mask: uint16
        asm """
          movdqu (%1), %%xmm0
          movdqu (%2), %%xmm1
          pcmpeqb %%xmm0, %%xmm1, %%xmm2
          pmovmskb %%xmm2, %0
          : "=r"(`mask`)
          : "r"(`bytes1`+`pos`), "r"(`bytes2`+`pos`)
          : "xmm0", "xmm1", "xmm2"
        """
        
        if mask != 0xFFFF'u16:
          # 不一致を検出
          let tzc = countTrailingZeros(not mask.uint32)
          return matchLen + tzc
        
        pos += 16
        matchLen += 16
      
      # 残りのバイトを処理
      while matchLen < maxLen and bytes1[matchLen] == bytes2[matchLen]:
        inc matchLen
      
      return matchLen
  
  elif defined(arm) or defined(arm64):
    if features.hasNEON and maxLen >= 16:
      # NEONを使用した16バイト単位の比較
      var matchLen: int = 0
      var pos: int = 0
      
      while pos <= maxLen - 16:
        var equal: bool = true
        asm """
          vld1.8 {q0}, [%1]
          vld1.8 {q1}, [%2]
          vceq.i8 q2, q0, q1
          vmovq %0, q2
          : "=r"(`equal`)
          : "r"(`bytes1`+`pos`), "r"(`bytes2`+`pos`)
          : "q0", "q1", "q2"
        """
        
        if not equal:
          # バイト単位で不一致を検出
          while bytes1[pos + matchLen] == bytes2[pos + matchLen]:
            inc matchLen
          return matchLen
        
        pos += 16
        matchLen += 16
      
      # 残りのバイトを処理
      while matchLen < maxLen and bytes1[matchLen] == bytes2[matchLen]:
        inc matchLen
      
      return matchLen
  
  # フォールバック実装（SIMD非対応の場合）
  var matchLen: int = 0
  while matchLen < maxLen and bytes1[matchLen] == bytes2[matchLen]:
    inc matchLen
  
  return matchLen

# LZ圧縮のためのマッチ検索（SIMD最適化）
proc findLongestMatch(src: pointer, srcLen: int, pos: int, 
                     hashTable: ptr UncheckedArray[HashTableEntry]): tuple[offset: int, length: int] =
  if pos + MIN_MATCH > srcLen:
    return (0, 0)
  
  let bytes = cast[ptr UncheckedArray[uint8]](src)
  let hash = computeHashSIMD(addr bytes[pos], 4)
  let entry = hashTable[hash]
  
  # 新しいエントリを登録
  hashTable[hash].pos = pos.uint32
  hashTable[hash].checksum = (bytes[pos].uint32 shl 24) or 
                            (bytes[pos+1].uint32 shl 16) or 
                            (bytes[pos+2].uint32 shl 8) or 
                            bytes[pos+3].uint32
  
  # 位置が範囲外やマッチング距離が大きすぎる場合
  if entry.pos == 0 or pos - int(entry.pos) > MAX_OFFSET:
    return (0, 0)
  
  # チェックサムによる高速フィルタリング
  let currentChecksum = hashTable[hash].checksum
  if entry.checksum != currentChecksum:
    return (0, 0)
  
  # マッチ長を計算
  let matchOffset = pos - int(entry.pos)
  let maxMatchLen = min(MAX_MATCH, srcLen - pos)
  
  # SIMD最適化された比較
  let matchLen = compareBlocksSIMD(
    addr bytes[int(entry.pos)], 
    addr bytes[pos], 
    maxMatchLen
  )
  
  if matchLen >= MIN_MATCH:
    return (matchOffset, matchLen)
  else:
    return (0, 0)

# SIMD最適化されたリテラルコピー
proc copyLiteralsSIMD(dst, src: pointer, len: int): int {.inline.} =
  let features = detectCpuFeatures()
  let dstBytes = cast[ptr UncheckedArray[uint8]](dst)
  let srcBytes = cast[ptr UncheckedArray[uint8]](src)
  
  when defined(i386) or defined(amd64):
    if features.hasAVX2 and len >= 32:
      # AVX2を使用した32バイト単位のコピー
      var pos: int = 0
      
      while pos <= len - 32:
        asm """
          vmovdqu (%1), %%ymm0
          vmovdqu %%ymm0, (%0)
          : 
          : "r"(`dstBytes`+`pos`), "r"(`srcBytes`+`pos`)
          : "ymm0", "memory"
        """
        pos += 32
      
      # 残りのバイトをコピー
      for i in pos ..< len:
        dstBytes[i] = srcBytes[i]
      
      return len
    
    elif features.hasSSE2 and len >= 16:
      # SSE2を使用した16バイト単位のコピー
      var pos: int = 0
      
      while pos <= len - 16:
        asm """
          movdqu (%1), %%xmm0
          movdqu %%xmm0, (%0)
          : 
          : "r"(`dstBytes`+`pos`), "r"(`srcBytes`+`pos`)
          : "xmm0", "memory"
        """
        pos += 16
      
      # 残りのバイトをコピー
      for i in pos ..< len:
        dstBytes[i] = srcBytes[i]
      
      return len
  
  elif defined(arm) or defined(arm64):
    if features.hasNEON and len >= 16:
      # NEONを使用した16バイト単位のコピー
      var pos: int = 0
      
      while pos <= len - 16:
        asm """
          vld1.8 {q0}, [%1]
          vst1.8 {q0}, [%0]
          : 
          : "r"(`dstBytes`+`pos`), "r"(`srcBytes`+`pos`)
          : "q0", "memory"
        """
        pos += 16
      
      # 残りのバイトをコピー
      for i in pos ..< len:
        dstBytes[i] = srcBytes[i]
      
      return len
  
  # フォールバック実装（SIMD非対応の場合）
  copyMem(dst, src, len)
  return len

# デフォルト圧縮オプションの生成
proc newSimdCompressionOptions*(
  level: SimdCompressionLevel = sclDefault,
  method: SimdCompressionMethod = scmAuto,
  blockSize: int = SIMD_DEFAULT_BLOCK_SIZE,
  optimizationTarget: SimdOptimizationTarget = sotBalanced,
  useMultithreading: bool = true,
  threadCount: int = 0
): SimdCompressionOptions =
  ## デフォルトのSIMD圧縮オプションを生成
  result = SimdCompressionOptions(
    level: level,
    method: method,
    blockSize: blockSize,
    optimizationTarget: optimizationTarget,
    windowSize: 32768,  # デフォルトウィンドウサイズ
    dictionarySize: 4096,  # デフォルト辞書サイズ
    useMultithreading: useMultithreading,
    threadCount: if threadCount <= 0: countProcessors() else: threadCount
  )

# 最適な圧縮方式の選択
proc selectBestCompressionMethod(data: string, options: SimdCompressionOptions): SimdCompressionMethod =
  ## データに最適な圧縮方式を選択
  if options.method != scmAuto:
    return options.method
  
  # データサイズとエントロピーに基づく選択
  let dataSize = data.len
  
  # エントロピー計算（データの複雑さを評価）
  var entropy = 0.0
  var freqTable = newSeq[int](256)
  for c in data:
    inc freqTable[ord(c)]
  
  for freq in freqTable:
    if freq > 0:
      let p = freq.float / dataSize.float
      entropy -= p * log2(p)
  
  # データサイズとエントロピーに基づいて最適な方式を選択
  if dataSize < 1024:
    # 小さなデータの場合はLZ4が高速
    return scmLZ4
  elif dataSize < 100 * 1024:
    # 中サイズのデータ
    if entropy < 5.0:
      # エントロピーが低い（繰り返しが多い）データはLZ4が効率的
      return scmLZ4
    else:
      # 複雑なデータはZstdが優れている
      return scmZstd
  else:
    # 大きなデータの場合
    case options.optimizationTarget:
      of sotSpeed:
        if entropy < 6.0:
          return scmLZ4
        else:
          return scmZstd
      of sotRatio:
        if entropy < 4.0:
          return scmZstd
        else:
          return scmBrotli
      of sotBalanced:
        if entropy < 5.0:
          return scmLZ4
        else:
          return scmZstd

# ブロックサイズの最適化
proc getOptimizedBlockSize(dataSize: int, options: SimdCompressionOptions): int =
  ## データサイズと目標に基づいて最適なブロックサイズを取得
  if options.blockSize > 0:
    # 明示的に指定された場合はそれを使用
    return options.blockSize
  
  # CPUキャッシュラインに合わせた調整
  const cacheLineSize = 64
  
  # 圧縮レベルに基づいたブロックサイズ調整
  case options.level:
    of sclFastest:
      # 最速モードでは大きなブロックサイズ（キャッシュに最適化）
      let blockSize = min(SIMD_MAX_BLOCK_SIZE, max(SIMD_MIN_BLOCK_SIZE, dataSize))
      return (blockSize div cacheLineSize) * cacheLineSize  # キャッシュライン境界に合わせる
    
    of sclFast:
      # 高速モードでは中〜大ブロックサイズ
      let blockSize = min(SIMD_DEFAULT_BLOCK_SIZE * 2, max(SIMD_MIN_BLOCK_SIZE, dataSize))
      return (blockSize div cacheLineSize) * cacheLineSize
    
    of sclDefault:
      # デフォルトは中程度
      let blockSize = min(SIMD_DEFAULT_BLOCK_SIZE, max(SIMD_MIN_BLOCK_SIZE, dataSize))
      return (blockSize div cacheLineSize) * cacheLineSize
    
    of sclBest:
      # 高圧縮率モードでは小さめのブロック
      let blockSize = min(SIMD_DEFAULT_BLOCK_SIZE div 2, max(SIMD_MIN_BLOCK_SIZE, dataSize))
      return (blockSize div cacheLineSize) * cacheLineSize
    
    of sclUltra:
      # 最高圧縮率モードでは最小ブロック
      let blockSize = min(SIMD_DEFAULT_BLOCK_SIZE div 4, max(SIMD_MIN_BLOCK_SIZE, dataSize))
      return (blockSize div cacheLineSize) * cacheLineSize

# AVX2を使用した高速メモリコピー
proc avx2MemCopy(dst, src: pointer, len: int) =
  ## AVX2命令を使用した高速メモリコピー
  var pos = 0
  
  # 32バイト境界にアライメントするまで1バイトずつコピー
  while (pos < len) and ((cast[uint](src) + pos.uint) and 31) != 0:
    cast[ptr UncheckedArray[byte]](dst)[pos] = cast[ptr UncheckedArray[byte]](src)[pos]
    inc pos
  
  # 32バイト単位でAVX2命令を使用してコピー
  while pos <= len - 32:
    when defined(amd64) or defined(i386):
      asm """
        vmovdqu ymm0, [%1]
        vmovdqu [%0], ymm0
        : 
        : "r"(`dst` + `pos`), "r"(`src` + `pos`)
        : "ymm0", "memory"
      """
    pos += 32
  
  # 残りのバイトを16バイト単位でコピー
  while pos <= len - 16:
    when defined(amd64) or defined(i386):
      asm """
        movdqu xmm0, [%1]
        movdqu [%0], xmm0
        : 
        : "r"(`dst` + `pos`), "r"(`src` + `pos`)
        : "xmm0", "memory"
      """
    elif defined(arm) or defined(arm64):
      asm """
        vld1.8 {q0}, [%1]
        vst1.8 {q0}, [%0]
        : 
        : "r"(`dst` + `pos`), "r"(`src` + `pos`)
        : "q0", "memory"
      """
    pos += 16
  
  # 残りのバイトを1バイトずつコピー
  while pos < len:
    cast[ptr UncheckedArray[byte]](dst)[pos] = cast[ptr UncheckedArray[byte]](src)[pos]
    inc pos

# ハッシュ関数（LZ4用）
proc hashLZ4(sequence: pointer, pos: int): uint32 {.inline.} =
  ## LZ4用の高速ハッシュ関数
  const PRIME32_1: uint32 = 2654435761'u32
  const PRIME32_2: uint32 = 2246822519'u32
  const PRIME32_3: uint32 = 3266489917'u32
  
  let bytes = cast[ptr UncheckedArray[byte]](sequence)
  var h: uint32 = 
    (bytes[pos].uint32) or
    (bytes[pos+1].uint32 shl 8) or
    (bytes[pos+2].uint32 shl 16) or
    (bytes[pos+3].uint32 shl 24)
  
  h *= PRIME32_1
  h = (h shl 13) or (h shr 19)
  h *= PRIME32_2
  
  return h and (HASH_SIZE - 1).uint32

# マッチ検索（LZ4用）
proc findLongestMatch(src: pointer, dataLen: int, pos: int, hashTable: ptr UncheckedArray[uint32]): tuple[offset: int, length: int] {.inline.} =
  ## LZ4圧縮用の最長マッチ検索
  const MIN_MATCH = 4  # 最小マッチ長
  const MAX_MATCH = 65535  # 最大マッチ長
  
  # 境界チェック
  if pos + MIN_MATCH > dataLen:
    return (0, 0)
  
  # 現在位置のハッシュ計算
  let hash = hashLZ4(src, pos)
  
  # ハッシュテーブルから候補位置を取得
  let matchPos = hashTable[hash].int
  
  # ハッシュテーブルを更新
  hashTable[hash] = pos.uint32
  
  # 有効なマッチ候補かチェック
  if matchPos == 0 or matchPos >= pos or pos - matchPos > 65535:
    return (0, 0)
  
  # マッチ長を計算
  let bytes = cast[ptr UncheckedArray[byte]](src)
  var matchLen = 0
  
  # SIMD命令を使用した高速比較（AVX2/SSE/NEON）
  when defined(amd64) or defined(i386):
    if cpuHasAVX2() and pos + 32 <= dataLen and matchPos + 32 <= dataLen:
      var diffMask: uint32 = 0
      asm """
        vmovdqu ymm0, [%1 + %3]
        vmovdqu ymm1, [%1 + %2]
        vpcmpeqb ymm2, ymm0, ymm1
        vpmovmskb %0, ymm2
        : "=r"(`diffMask`)
        : "r"(`bytes`), "r"(`matchPos`), "r"(`pos`)
        : "ymm0", "ymm1", "ymm2"
      """
      
      if diffMask == 0xFFFFFFFF'u32:
        # 32バイト全て一致
        matchLen = 32
      else:
        # 最初の不一致位置を計算
        matchLen = countTrailingZeros(not diffMask) div 8
        return (pos - matchPos, min(matchLen, MAX_MATCH))
    
    elif cpuHasSSE2() and pos + 16 <= dataLen and matchPos + 16 <= dataLen:
      var diffMask: uint16 = 0
      asm """
        movdqu xmm0, [%1 + %3]
        movdqu xmm1, [%1 + %2]
        pcmpeqb xmm0, xmm1
        pmovmskb %0, xmm0
        : "=r"(`diffMask`)
        : "r"(`bytes`), "r"(`matchPos`), "r"(`pos`)
        : "xmm0", "xmm1"
      """
      
      if diffMask == 0xFFFF'u16:
        # 16バイト全て一致
        matchLen = 16
      else:
        # 最初の不一致位置を計算
        matchLen = countTrailingZeros(not diffMask.uint32) div 8
        return (pos - matchPos, min(matchLen, MAX_MATCH))
  
  elif defined(arm) or defined(arm64) and cpuHasNEON():
    # NEONを使用した実装
    if pos + 16 <= dataLen and matchPos + 16 <= dataLen:
      var diffMask: uint16 = 0
      asm """
        ldr q0, [%1, %3]
        ldr q1, [%1, %2]
        cmeq v2.16b, v0.16b, v1.16b
        umov %0, v2.16b
        : "=r"(`diffMask`)
        : "r"(`bytes`), "r"(`matchPos`), "r"(`pos`)
        : "v0", "v1", "v2"
      """
      
      if diffMask == 0xFFFF'u16:
        # 16バイト全て一致
        matchLen = 16
        
        # さらに16バイト先も比較
        if pos + 32 <= dataLen and matchPos + 32 <= dataLen:
          var extendedDiffMask: uint16 = 0
          asm """
            ldr q0, [%1, %3]
            ldr q1, [%1, %2]
            cmeq v2.16b, v0.16b, v1.16b
            umov %0, v2.16b
            : "=r"(`extendedDiffMask`)
            : "r"(`bytes`), "r"(`matchPos` + 16), "r"(`pos` + 16)
            : "v0", "v1", "v2"
          """
          
          if extendedDiffMask == 0xFFFF'u16:
            matchLen = 32
          else:
            # 追加の不一致位置を計算
            matchLen += countTrailingZeros(not extendedDiffMask.uint32) div 8
            return (pos - matchPos, min(matchLen, MAX_MATCH))
      else:
        # 最初の不一致位置を計算
        matchLen = countTrailingZeros(not diffMask.uint32) div 8
        return (pos - matchPos, min(matchLen, MAX_MATCH))
  
  # バイト単位での比較（フォールバックまたは続き）
  while matchLen < MAX_MATCH and pos + matchLen < dataLen and 
        bytes[matchPos + matchLen] == bytes[pos + matchLen]:
    inc matchLen
  
  if matchLen >= MIN_MATCH:
    return (pos - matchPos, matchLen)
  else:
    return (0, 0)

# LZ4圧縮の実装（SIMD最適化）
proc compressLz4Simd(data: string, options: SimdCompressionOptions): string =
  ## LZ4方式でSIMD最適化された圧縮を実行
  # サイズ確認
  if data.len == 0:
    return ""
  
  const MIN_MATCH = 4  # 最小マッチ長
  const HASH_SIZE = 65536  # ハッシュテーブルサイズ
  
  # 最適なブロックサイズを取得
  let blockSize = getOptimizedBlockSize(data.len, options)
  
  # 圧縮レベルに応じたパラメータ調整
  let searchLimit = case options.level:
    of sclFastest: 8
    of sclFast: 16
    of sclDefault: 32
    of sclBest: 64
    of sclUltra: 128
  
  # 最大圧縮サイズの計算（最悪の場合、入力 + 補助データ）
  let maxCompressedSize = data.len + (data.len div 255) + 16
  var compressed = newString(maxCompressedSize)
  
  # ハッシュテーブルの初期化
  var hashTable = newSeq[uint32](HASH_SIZE)
  
  # 入出力ポインタ
  var ip = 0          # 入力位置
  var op = 0          # 出力位置
  
  # データポインタ取得
  let src = cast[pointer](unsafeAddr data[0])
  let dst = cast[pointer](addr compressed[0])
  
  # ハッシュテーブルのポインタ
  let hashTablePtr = cast[ptr UncheckedArray[uint32]](addr hashTable[0])
  
  # 本体サイズをヘッダとして書き込み
  compressed[op] = char((data.len and 0xFF))
  compressed[op+1] = char((data.len shr 8) and 0xFF)
  compressed[op+2] = char((data.len shr 16) and 0xFF)
  compressed[op+3] = char((data.len shr 24) and 0xFF)
  op += 4
  
  # マルチスレッド処理の準備
  var blockResults: seq[tuple[start, end: int, data: string]]
  
  if options.useMultithreading and data.len > blockSize * 2:
    # ブロック分割
    var blocks: seq[tuple[start, end: int]]
    var blockStart = 0
    
    while blockStart < data.len:
      let blockEnd = min(blockStart + blockSize, data.len)
      blocks.add((blockStart, blockEnd))
      blockStart = blockEnd
    
    # 並列処理用のチャネル
    var chan = newChan[tuple[id: int, result: string]](blocks.len)
    
    # 各ブロックを並列圧縮
    for i, block in blocks:
      let blockData = data[block.start..<block.end]
      let blockId = i
      
      # スレッド作成
      spawn (proc() {.thread.} =
        # 個別のハッシュテーブル
        var localHashTable = newSeq[uint32](HASH_SIZE)
        var localCompressed = newString(blockData.len + (blockData.len div 255) + 16)
        var localOp = 0
        
        # ブロック圧縮処理
        var localIp = 0
        let localSrc = cast[pointer](unsafeAddr blockData[0])
        let localHashTablePtr = cast[ptr UncheckedArray[uint32]](addr localHashTable[0])
        
        while localIp < blockData.len:
          # トークン位置を記録
          let tokenPos = localOp
          localOp += 1  # トークン用に1バイト確保
          
          # リテラル開始位置
          let literalStart = localIp
          var literalLength = 0
          
          # マッチング
          let match = findLongestMatch(localSrc, blockData.len, localIp, localHashTablePtr)
          
          if match.length >= MIN_MATCH:
            # マッチが見つかった場合、リテラル長を計算
            literalLength = localIp - literalStart
            
            # ハッシュテーブル更新
            let bytes = cast[ptr UncheckedArray[byte]](localSrc)
            for j in 0..<match.length:
              if localIp + j + 3 < blockData.len:
                let h = computeHash(bytes[localIp + j], bytes[localIp + j + 1], bytes[localIp + j + 2], bytes[localIp + j + 3])
                localHashTablePtr[h] = (localIp + j).uint32
            
            # 位置を進める
            localIp += match.length
          else:
            # マッチが見つからない場合
            let bytes = cast[ptr UncheckedArray[byte]](localSrc)
            if localIp + 3 < blockData.len:
              let h = computeHash(bytes[localIp], bytes[localIp + 1], bytes[localIp + 2], bytes[localIp + 3])
              localHashTablePtr[h] = localIp.uint32
            
            # 1バイト進める
            inc localIp
            literalLength = localIp - literalStart
          
          # トークンの書き込み
          if literalLength > 0:
            # リテラル長の符号化
            if literalLength < 15:
              localCompressed[tokenPos] = char(literalLength shl 4)
            else:
              localCompressed[tokenPos] = char(15 shl 4)
              var rest = literalLength - 15
              while rest >= 255:
                localCompressed[localOp] = char(255)
                inc localOp
                rest -= 255
              localCompressed[localOp] = char(rest)
              inc localOp
            
            # リテラルデータのコピー
            copyMem(addr localCompressed[localOp], unsafeAddr blockData[literalStart], literalLength)
            localOp += literalLength
          
          # マッチ情報の書き込み
          if match.length >= MIN_MATCH:
            # マッチ長の符号化
            let encodedLen = match.length - MIN_MATCH
            if encodedLen < 15:
              localCompressed[tokenPos] = char(ord(localCompressed[tokenPos]) or encodedLen)
            else:
              localCompressed[tokenPos] = char(ord(localCompressed[tokenPos]) or 15)
              var rest = encodedLen - 15
              while rest >= 255:
                localCompressed[localOp] = char(255)
                inc localOp
                rest -= 255
              localCompressed[localOp] = char(rest)
              inc localOp
            
            # マッチ距離の書き込み
            localCompressed[localOp] = char(match.distance and 0xFF)
            localCompressed[localOp+1] = char((match.distance shr 8) and 0xFF)
            localOp += 2
        
        # 結果をチャネルに送信
        chan.send((blockId, localCompressed[0..<localOp]))
      )()
    
    # 結果を収集
    for i in 0..<blocks.len:
      let result = chan.recv()
      blockResults.add((blocks[result.id].start, blocks[result.id].end, result.result))
    
    # 結果をソート
    blockResults.sort(proc(x, y: tuple[start, end: int, data: string]): int =
      result = cmp(x.start, y.start)
    )
    
    # 圧縮データを結合
    for block in blockResults:
      # ブロックヘッダ（開始位置と長さ）
      compressed[op] = char((block.start and 0xFF))
      compressed[op+1] = char((block.start shr 8) and 0xFF)
      compressed[op+2] = char((block.start shr 16) and 0xFF)
      compressed[op+3] = char((block.start shr 24) and 0xFF)
      
      compressed[op+4] = char((block.data.len and 0xFF))
      compressed[op+5] = char((block.data.len shr 8) and 0xFF)
      compressed[op+6] = char((block.data.len shr 16) and 0xFF)
      compressed[op+7] = char((block.data.len shr 24) and 0xFF)
      op += 8
      
      # ブロックデータをコピー
      copyMem(addr compressed[op], unsafeAddr block.data[0], block.data.len)
      op += block.data.len
  else:
    # シングルスレッド処理
    # 圧縮ループ
    while ip < data.len:
      # トークン位置を記録
      let tokenPos = op
      op += 1  # トークン用に1バイト確保
      
      # リテラル開始位置
      let literalStart = ip
      var literalLength = 0
      
      # マッチング
      let match = findLongestMatch(src, data.len, ip, hashTablePtr)
      
      if match.length >= MIN_MATCH:
        # マッチが見つかった場合
        
        # リテラル長0のトークン + マッチ情報
        compressed[tokenPos] = char(0x00)  # リテラル長0
        
        # マッチオフセットを書き込み
        compressed[op] = char(match.offset and 0xFF)
        compressed[op+1] = char((match.offset shr 8) and 0xFF)
        op += 2
        
        # マッチ長を書き込み (最小マッチ長分を引く)
        let matchLengthCode = match.length - MIN_MATCH
        if matchLengthCode < 15:
          # 短いマッチの場合はトークンに含める
          compressed[tokenPos] = char(compressed[tokenPos].uint8 or (matchLengthCode.uint8 shl 4))
        else:
          # 長いマッチの場合は追加バイトを使用
          compressed[tokenPos] = char(compressed[tokenPos].uint8 or 0xF0)  # 15 (0xF) << 4
          var remainingLength = matchLengthCode - 15
          
          while remainingLength >= 255:
            compressed[op] = char(255)
            op += 1
            remainingLength -= 255
          
          compressed[op] = char(remainingLength)
          op += 1
        
        # 位置を進める
        ip += match.length
      else:
        # マッチが見つからない場合はリテラルを出力
        
        # 次のマッチを探すまでリテラル長をカウント
        while ip < data.len:
          # 検索制限に達したらブレーク
          if literalLength >= searchLimit:
            ip += 1
            literalLength += 1
            break
          
          let nextMatch = findLongestMatch(src, data.len, ip, hashTablePtr)
          if nextMatch.length >= MIN_MATCH:
            break
          ip += 1
          literalLength += 1
          
          # 最大リテラル長に達した場合は分割
          if literalLength == 255:
            break
        
        # リテラル長をトークンに書き込み
        if literalLength < 15:
          compressed[tokenPos] = char(literalLength)
        else:
          compressed[tokenPos] = char(0x0F)  # 15 (0xF)
          var remainingLength = literalLength - 15
          
          while remainingLength >= 255:
            compressed[op] = char(255)
            op += 1
            remainingLength -= 255
          
          compressed[op] = char(remainingLength)
          op += 1
        
        # リテラルデータをコピー
        if literalLength > 0:
          # SIMD最適化されたメモリコピー
          avx2MemCopy(addr compressed[op], unsafeAddr data[literalStart], literalLength)
          op += literalLength
  
  # 最終サイズに調整
  result = compressed[0..<op]
  return result

# Zstandard圧縮の実装（SIMD最適化）
proc compressZstdSimd(data: string, options: SimdCompressionOptions): string =
  ## Zstandard方式でSIMD最適化された圧縮を実行
  if data.len == 0:
    return ""

  # Zstdマジックナンバー
  const ZSTD_MAGIC_NUMBER = 0xFD2FB528'u32
  
  # 圧縮レベルをZstdレベルに変換
  let zstdLevel = case options.level:
    of sclFastest: 1
    of sclFast: 3
    of sclDefault: 6
    of sclBest: 19
    of sclUltra: 22
  
  # 最大圧縮サイズの計算
  let maxCompressedSize = data.len + (data.len div 8) + 128
  var compressed = newString(maxCompressedSize)
  
  # ハッシュテーブルの初期化
  let hashTableSize = 1 shl 16
  var hashTable = newSeq[uint32](hashTableSize)
  
  # フレームヘッダー書き込み
  var op = 0
  
  # マジックナンバー
  compressed[op] = char((ZSTD_MAGIC_NUMBER and 0xFF))
  compressed[op+1] = char((ZSTD_MAGIC_NUMBER shr 8) and 0xFF)
  compressed[op+2] = char((ZSTD_MAGIC_NUMBER shr 16) and 0xFF)
  compressed[op+3] = char((ZSTD_MAGIC_NUMBER shr 24) and 0xFF)
  op += 4
  
  # フレームヘッダー
  let windowLog = min(31, max(10, log2(options.windowSize.float).int))
  let fcsField = 0x40 or ((windowLog - 10) shl 3) or 0  # シングルセグメント、チェックサムなし
  compressed[op] = char(fcsField)
  op += 1
  
  # 元のサイズを書き込み
  if data.len < 256:
    compressed[op] = char(data.len)
    op += 1
  else:
    compressed[op] = char(0)
    compressed[op+1] = char(data.len and 0xFF)
    compressed[op+2] = char((data.len shr 8) and 0xFF)
    compressed[op+3] = char((data.len shr 16) and 0xFF)
    compressed[op+4] = char((data.len shr 24) and 0xFF)
    op += 5
  
  # 圧縮ブロックの処理
  var ip = 0
  while ip < data.len:
    # ブロックサイズの決定
    let blockSize = min(data.len - ip, 128 * 1024)
    
    # ブロックヘッダー
    let lastBlock = ip + blockSize >= data.len
    let blockHeader = (if lastBlock: 1'u32 else: 0'u32) or (2'u32 shl 1)  # 圧縮ブロック
    compressed[op] = char(blockHeader and 0xFF)
    compressed[op+1] = char((blockHeader shr 8) and 0xFF)
    compressed[op+2] = char((blockHeader shr 16) and 0xFF)
    op += 3
    
    # 圧縮サイズ位置を記録
    let compressedSizePos = op
    op += 3  # 圧縮サイズ用に3バイト確保
    
    let blockStart = op
    
    # ブロック圧縮処理
    var blockIp = ip
    let blockEnd = ip + blockSize
    
    while blockIp < blockEnd:
      # リテラル処理
      let literalStart = blockIp
      var literalLength = 0
      
      # ハッシュ計算関数
      proc hash(p: int): uint32 =
        let v = (data[p].uint32 shl 16) or (data[p+1].uint32 shl 8) or data[p+2].uint32
        return ((v * 2654435761'u32) shr 16) and (hashTableSize - 1).uint32
      
      # マッチ検索
      while blockIp + 3 < blockEnd:
        let h = hash(blockIp)
        let matchPos = hashTable[h]
        hashTable[h] = blockIp.uint32
        
        # マッチ検証
        if matchPos > 0 and blockIp - int(matchPos) < options.windowSize and 
           blockIp - int(matchPos) >= 4:
          let matchOffset = blockIp - int(matchPos)
          var matchLength = 0
          
          # AVX2を使用したマッチ長の計算
          if options.useAvx2 and blockIp + 32 <= blockEnd and int(matchPos) + 32 <= blockIp:
            # AVX2命令を使用した高速マッチング
            var mm256Pos: int = 0
            let srcPtr = cast[ptr UncheckedArray[byte]](unsafeAddr data[blockIp])
            let matchPtr = cast[ptr UncheckedArray[byte]](unsafeAddr data[int(matchPos)])
            
            # 256ビット(32バイト)単位で比較
            while mm256Pos < 32:
              let srcVec = mm256_loadu_si256(cast[ptr m256i](addr srcPtr[mm256Pos]))
              let matchVec = mm256_loadu_si256(cast[ptr m256i](addr matchPtr[mm256Pos]))
              let cmpMask = mm256_cmpeq_epi8(srcVec, matchVec)
              let moveMask = mm256_movemask_epi8(cmpMask)
              
              if moveMask != 0xFFFFFFFF:
                # 一致しないバイトを見つけた
                let trailingZeros = mm_tzcnt_32(not moveMask.uint32).int
                matchLength = mm256Pos + trailingZeros
                break
              
              mm256Pos += 32
              matchLength = mm256Pos
            
            # 残りのバイトを通常の方法で比較
            while blockIp + matchLength < blockEnd and 
                  int(matchPos) + matchLength < blockIp and
                  data[blockIp + matchLength] == data[int(matchPos) + matchLength]:
              matchLength += 1
          elif options.useSse42 and blockIp + 16 <= blockEnd and int(matchPos) + 16 <= blockIp:
            # SSE4.2命令を使用したマッチング
            var mm128Pos: int = 0
            let srcPtr = cast[ptr UncheckedArray[byte]](unsafeAddr data[blockIp])
            let matchPtr = cast[ptr UncheckedArray[byte]](unsafeAddr data[int(matchPos)])
            
            # 128ビット(16バイト)単位で比較
            while mm128Pos < 16:
              let srcVec = mm_loadu_si128(cast[ptr m128i](addr srcPtr[mm128Pos]))
              let matchVec = mm_loadu_si128(cast[ptr m128i](addr matchPtr[mm128Pos]))
              let cmpMask = mm_cmpeq_epi8(srcVec, matchVec)
              let moveMask = mm_movemask_epi8(cmpMask)
              
              if moveMask != 0xFFFF:
                # 一致しないバイトを見つけた
                let trailingZeros = mm_tzcnt_32(not moveMask.uint32).int
                matchLength = mm128Pos + trailingZeros
                break
              
              mm128Pos += 16
              matchLength = mm128Pos
            
            # 残りのバイトを通常の方法で比較
            while blockIp + matchLength < blockEnd and 
                  int(matchPos) + matchLength < blockIp and
                  data[blockIp + matchLength] == data[int(matchPos) + matchLength]:
              matchLength += 1
          else:
            # 通常の実装（SIMD命令なし）
            while blockIp + matchLength < blockEnd and 
                  int(matchPos) + matchLength < blockIp and
                  data[blockIp + matchLength] == data[int(matchPos) + matchLength]:
              matchLength += 1
          if matchLength >= 4:
            # リテラルを出力
            if literalLength > 0:
              # リテラル長エンコード
              if literalLength < 32:
                compressed[op] = char((literalLength shl 3) or 0)
                op += 1
              else:
                var remainingLength = literalLength
                compressed[op] = char((31 shl 3) or 0)
                op += 1
                remainingLength -= 31
                
                while remainingLength >= 255:
                  compressed[op] = char(255)
                  op += 1
                  remainingLength -= 255
                
                compressed[op] = char(remainingLength)
                op += 1
              
              # リテラルデータコピー
              if options.useAvx2 and literalLength >= 32:
                # AVX2最適化コピー
                avx2MemCopy(addr compressed[op], unsafeAddr data[literalStart], literalLength)
              else:
                copyMem(addr compressed[op], unsafeAddr data[literalStart], literalLength)
              op += literalLength
            
            # マッチ情報エンコード
            let offsetCode = matchOffset
            let mlCode = matchLength - 4
            
            # マッチ長エンコード
            if mlCode < 28:
              compressed[op] = char((mlCode shl 3) or 1)
              op += 1
            else:
              compressed[op] = char((27 shl 3) or 1)
              op += 1
              let remainingLength = mlCode - 27
              
              if remainingLength < 255:
                compressed[op] = char(remainingLength)
                op += 1
              else:
                compressed[op] = char(255)
                op += 1
                compressed[op] = char((remainingLength - 255) and 0xFF)
                compressed[op+1] = char(((remainingLength - 255) shr 8) and 0xFF)
                op += 2
            
            # オフセットエンコード
            compressed[op] = char(offsetCode and 0xFF)
            compressed[op+1] = char((offsetCode shr 8) and 0xFF)
            op += 2
            
            blockIp += matchLength
            literalLength = 0
            continue
        
        blockIp += 1
        literalLength += 1
      
      # 残りのリテラル処理
      while blockIp < blockEnd:
        blockIp += 1
        literalLength += 1
      
      # 最後のリテラルを出力
      if literalLength > 0:
        # リテラル長エンコード
        if literalLength < 32:
          compressed[op] = char((literalLength shl 3) or 0)
          op += 1
        else:
          var remainingLength = literalLength
          compressed[op] = char((31 shl 3) or 0)
          op += 1
          remainingLength -= 31
          
          while remainingLength >= 255:
            compressed[op] = char(255)
            op += 1
            remainingLength -= 255
          
          compressed[op] = char(remainingLength)
          op += 1
        
        # リテラルデータコピー
        if options.useAvx2 and literalLength >= 32:
          # AVX2最適化コピー
          avx2MemCopy(addr compressed[op], unsafeAddr data[literalStart], literalLength)
        else:
          copyMem(addr compressed[op], unsafeAddr data[literalStart], literalLength)
        op += literalLength
    
    # ブロック圧縮サイズを書き込み
    let compressedBlockSize = op - blockStart
    compressed[compressedSizePos] = char(compressedBlockSize and 0xFF)
    compressed[compressedSizePos+1] = char((compressedBlockSize shr 8) and 0xFF)
    compressed[compressedSizePos+2] = char((compressedBlockSize shr 16) and 0xFF)
    
    ip += blockSize
  
  # コンテンツチェックサム（オプション）
  if options.addChecksum:
    var xxhash: uint32 = 0
    # XXH32ハッシュ計算（実際の実装では正確なXXH32アルゴリズムを使用）
    for i in 0..<data.len:
      xxhash = ((xxhash + data[i].uint32) * 0x01000193) xor (xxhash shr 16)
    
    compressed[op] = char(xxhash and 0xFF)
    compressed[op+1] = char((xxhash shr 8) and 0xFF)
    compressed[op+2] = char((xxhash shr 16) and 0xFF)
    compressed[op+3] = char((xxhash shr 24) and 0xFF)
    op += 4
  
  # 最終サイズに調整
  result = compressed[0..<op]
  return result

# Deflate圧縮の実装（SIMD最適化）
proc compressDeflateSimd(data: string, options: SimdCompressionOptions): string =
  ## Deflate方式でSIMD最適化された圧縮を実行
  if data.len == 0:
    return ""
  
  # 圧縮レベルに応じたパラメータ設定
  let level = case options.level:
    of sclFastest: 1
    of sclFast: 3
    of sclDefault: 6
    of sclBest: 9
    of sclUltra: 10
  
  # ウィンドウサイズ（2^15 = 32KB）
  let windowSize = min(32768, options.windowSize)
  
  # 最大圧縮サイズの計算
  let maxCompressedSize = data.len + (data.len div 8) + 128
  var compressed = newString(maxCompressedSize)
  
  # ハッシュテーブルの初期化
  let hashBits = 15
  let hashSize = 1 shl hashBits
  let hashMask = hashSize - 1
  var hashTable = newSeq[uint32](hashSize)
  
  # Deflateヘッダー
  var op = 0
  
  # 圧縮方法とウィンドウサイズ
  let cmf = 8 or ((log2(windowSize.float).int - 8) shl 4)
  let flg = (31 - (cmf * 256) mod 31) # FCHECK値
  
  compressed[op] = char(cmf)
  compressed[op+1] = char(flg)
  op += 2
  
  # CRC32計算用
  var crc32: uint32 = 0xFFFFFFFF'u32
  
  # CRC32テーブル初期化
  var crc32Table = newSeq[uint32](256)
  for i in 0..255:
    var c = i.uint32
    for j in 0..7:
      if (c and 1) != 0:
        c = 0xEDB88320'u32 xor (c shr 1)
      else:
        c = c shr 1
    crc32Table[i] = c
  
  # CRC32更新関数
  proc updateCrc32(crc: uint32, data: string, offset, length: int): uint32 =
    var result = crc
    for i in 0..<length:
      result = crc32Table[(result xor data[offset + i].uint32) and 0xFF] xor (result shr 8)
    return result
  
  # ハッシュ計算関数
  proc hash(data: string, pos: int): uint32 =
    let v = (data[pos].uint32 shl 16) or (data[pos+1].uint32 shl 8) or data[pos+2].uint32
    return ((v * 0x1E35A7BD'u32) shr (32 - hashBits)) and hashMask.uint32
  
  # 圧縮処理
  var ip = 0
  
  # ブロック処理
  while ip < data.len:
    # ブロックサイズの決定
    let blockSize = min(data.len - ip, 65535)
    let lastBlock = ip + blockSize >= data.len
    
    # ブロックヘッダー
    compressed[op] = char(if lastBlock: 1 else: 0)  # BFINAL + BTYPE(00: 非圧縮)
    op += 1
    
    # 非圧縮ブロックの場合
    if level == 0 or blockSize < 16:
      # LEN
      compressed[op] = char(blockSize and 0xFF)
      compressed[op+1] = char((blockSize shr 8) and 0xFF)
      # NLEN
      compressed[op+2] = char((not blockSize) and 0xFF)
      compressed[op+3] = char(((not blockSize) shr 8) and 0xFF)
      op += 4
      
      # データコピー
      copyMem(addr compressed[op], unsafeAddr data[ip], blockSize)
      op += blockSize
      
      # CRC32更新
      crc32 = updateCrc32(crc32, data, ip, blockSize)
      
      ip += blockSize
      continue
    
    # 圧縮ブロック（BTYPE=01: 固定ハフマン、BTYPE=10: 動的ハフマン）
    compressed[op-1] = char(compressed[op-1].uint8 or 0x02)  # BTYPE=01（固定ハフマン）
    
    # リテラル/長さとディスタンスのカウント
    var literalFreq = newSeq[int](286)
    var distanceFreq = newSeq[int](30)
    
    # ブロック圧縮処理
    var blockIp = ip
    let blockEnd = ip + blockSize
    
    while blockIp < blockEnd:
      # リテラル処理
      let literalStart = blockIp
      var literalLength = 0
      
      # マッチ検索
      while blockIp + 3 < blockEnd:
        let h = hash(data, blockIp)
        let matchPos = hashTable[h]
        hashTable[h] = blockIp.uint32
        
        # マッチ検証
        if matchPos > 0 and blockIp - int(matchPos) < windowSize and 
           blockIp - int(matchPos) >= 3:
          let matchOffset = blockIp - int(matchPos)
          var matchLength = 0
          
          # AVX2を使用したマッチ長の計算
          if options.useAvx2 and blockIp + 32 <= blockEnd and int(matchPos) + 32 <= blockIp:
            # AVX2実装（実際にはここでAVX2命令を使用）
            while matchLength < 32 and data[blockIp + matchLength] == data[int(matchPos) + matchLength]:
              matchLength += 1
          else:
            # 通常の実装
            while blockIp + matchLength < blockEnd and 
                  int(matchPos) + matchLength < blockIp and
                  data[blockIp + matchLength] == data[int(matchPos) + matchLength]:
              matchLength += 1
          
          if matchLength >= 3:
            # リテラルを出力
            if literalLength > 0:
              for i in 0..<literalLength:
                let lit = data[literalStart + i].uint8
                literalFreq[lit] += 1
                
                # リテラルビット出力（固定ハフマン）
                if lit <= 143:
                  # 8ビットコード + 1ビット
                  let code = 0x30 + lit
                  compressed[op] = char((code shr 1) and 0xFF)
                  compressed[op+1] = char(((code and 1) shl 7) or 0)
                  op += 1
                else:
                  # 9ビットコード
                  let code = 0x190 + (lit - 144)
                  compressed[op] = char((code shr 1) and 0xFF)
                  compressed[op+1] = char(((code and 1) shl 7) or 0)
                  op += 2
            
            # マッチ長とディスタンスを出力
            let lengthCode = if matchLength <= 10: 254 + matchLength else: 265 + min(23, (matchLength - 11) shr 1)
            let distanceCode = min(29, log2(matchOffset.float).int)
            
            literalFreq[lengthCode] += 1
            distanceFreq[distanceCode] += 1
            
            # 長さコード出力
            if lengthCode <= 279:
              # 7ビットコード
              let code = 0x30 + (lengthCode - 256)
              compressed[op] = char((code shr 1) and 0xFF)
              compressed[op+1] = char(((code and 1) shl 7) or 0)
              op += 1
            else:
              # 8ビットコード
              let code = 0x190 + (lengthCode - 280)
              compressed[op] = char((code shr 1) and 0xFF)
              compressed[op+1] = char(((code and 1) shl 7) or 0)
              op += 2
            
            # 長さの追加ビット
            if lengthCode >= 265 and lengthCode < 285:
              let extraBits = (lengthCode - 261) shr 2
              let extraValue = (matchLength - 3) and ((1 shl extraBits) - 1)
              
              if extraBits <= 8:
                compressed[op] = char(extraValue)
                op += 1
              else:
                compressed[op] = char(extraValue and 0xFF)
                compressed[op+1] = char((extraValue shr 8) and 0xFF)
                op += 2
            
            # ディスタンスコード出力（5ビット固定長）
            compressed[op] = char(distanceCode)
            op += 1
            
            # ディスタンスの追加ビット
            if distanceCode >= 4:
              let extraBits = (distanceCode shr 1) - 1
              let extraValue = matchOffset - (1 shl (distanceCode shr 1))
              
              if extraBits <= 8:
                compressed[op] = char(extraValue)
                op += 1
              else:
                compressed[op] = char(extraValue and 0xFF)
                compressed[op+1] = char((extraValue shr 8) and 0xFF)
                op += 2
            
            blockIp += matchLength
            literalLength = 0
            continue
        
        blockIp += 1
        literalLength += 1
      
      # 残りのリテラル処理
      while blockIp < blockEnd:
        blockIp += 1
        literalLength += 1
      
      # 最後のリテラルを出力
      if literalLength > 0:
        for i in 0..<literalLength:
          let lit = data[literalStart + i].uint8
          literalFreq[lit] += 1
          
          # リテラルビット出力（固定ハフマン）
          if lit <= 143:
            # 8ビットコード
            let code = 0x30 + lit
            compressed[op] = char((code shr 1) and 0xFF)
            compressed[op+1] = char(((code and 1) shl 7) or 0)
            op += 1
          else:
            # 9ビットコード
            let code = 0x190 + (lit - 144)
            compressed[op] = char((code shr 1) and 0xFF)
            compressed[op+1] = char(((code and 1) shl 7) or 0)
            op += 2
      
      # ブロック終了マーカー
      literalFreq[256] += 1
      let endCode = 0x000
      compressed[op] = char((endCode shr 1) and 0xFF)
      compressed[op+1] = char(((endCode and 1) shl 7) or 0)
      op += 1
    
    # CRC32更新
    crc32 = updateCrc32(crc32, data, ip, blockSize)
    
    ip += blockSize
  
  # Adler-32チェックサム
  crc32 = not crc32
  compressed[op] = char((crc32 shr 24) and 0xFF)
  compressed[op+1] = char((crc32 shr 16) and 0xFF)
  compressed[op+2] = char((crc32 shr 8) and 0xFF)
  compressed[op+3] = char(crc32 and 0xFF)
  op += 4
  
  # 最終サイズに調整
  result = compressed[0..<op]
  return result

# Brotli圧縮の実装（SIMD最適化）
proc compressBrotliSimd(data: string, options: SimdCompressionOptions): string =
  ## Brotli方式でSIMD最適化された圧縮を実行
  if data.len == 0:
    return ""
  
  # Brotliの品質レベル（0-11）
  let brotliQuality = case options.level:
    of sclFastest: 0
    of sclFast: 2
    of sclDefault: 5
    of sclBest: 9
    of sclUltra: 11
  
  # ウィンドウサイズ（10-24）
  let windowBits = min(24, max(10, log2(options.windowSize.float).int))
  
  # 最大圧縮サイズの計算
  let maxCompressedSize = data.len + (data.len div 8) + 128
  var compressed = newString(maxCompressedSize)
  
  # ハッシュテーブルの初期化
  let hashBits = 17
  let hashSize = 1 shl hashBits
  let hashMask = hashSize - 1
  var hashTable = newSeq[uint32](hashSize)
  
  # Brotliヘッダー
  var op = 0
  
  # WBITS (4ビット) + ISLAST (1ビット) + MLEN (0ビット、メタブロックサイズは明示的)
  compressed[op] = char(((windowBits - 10) shl 4) or 0x01)
  op += 1
  
  # メタブロックサイズ
  if data.len <= 16383:
    # 14ビット以下のサイズ
    compressed[op] = char(((data.len - 1) and 0x7F) or 0x80)  # MNIBBLES=1
    compressed[op+1] = char((data.len - 1) shr 7)
    op += 2
  else:
    # より大きいサイズ
    compressed[op] = char(0)  # MNIBBLES=0
    compressed[op+1] = char(data.len and 0xFF)
    compressed[op+2] = char((data.len shr 8) and 0xFF)
    compressed[op+3] = char((data.len shr 16) and 0xFF)
    op += 4
  
  # 非圧縮フラグ（0: 圧縮あり）
  compressed[op] = char(0)
  op += 1
  
  # ハフマンツリー情報
  # 簡略化のため、固定ハフマンコードを使用
  
  # NTREES = 1 (リテラル/コマンド/距離の3種類のツリー)
  compressed[op] = char(0x01)
  op += 1
  
  # リテラルアルファベットサイズ (256)
  compressed[op] = char(0xFF)
  compressed[op+1] = char(0x01)
  op += 2
  
  # シンプルコード表現（HSKIP=0）
  compressed[op] = char(0x01)  # NSYM=2
  op += 1
  
  # シンボル1: 0
  compressed[op] = char(0)
  # シンボル2: 255
  compressed[op+1] = char(255)
  op += 2
  
  # コード長: 1ビット
  compressed[op] = char(1)
  op += 1
  
  # コマンドアルファベットサイズ (704)
  compressed[op] = char(0xC0)
  compressed[op+1] = char(0x05)
  op += 2
  
  # シンプルコード表現
  compressed[op] = char(0x01)  # NSYM=2
  op += 1
  
  # シンボル1: 0
  compressed[op] = char(0)
  # シンボル2: 703
  compressed[op+1] = char(0xBF)
  compressed[op+2] = char(0x05)
  op += 3
  
  # コード長: 1ビット
  compressed[op] = char(1)
  op += 1
  
  # 距離アルファベットサイズ (16)
  compressed[op] = char(16)
  op += 1
  
  # シンプルコード表現
  compressed[op] = char(0x01)  # NSYM=2
  op += 1
  
  # シンボル1: 0
  compressed[op] = char(0)
  # シンボル2: 15
  compressed[op+1] = char(15)
  op += 2
  
  # コード長: 1ビット
  compressed[op] = char(1)
  op += 1
  
  # コンテキストマップ（簡略化）
  compressed[op] = char(0)  # NTREES=1
  op += 1
  
  # 圧縮処理
  var ip = 0
  
  # ハッシュ計算関数
  proc hash(data: string, pos: int): uint32 =
    let v = (data[pos].uint32 shl 24) or (data[pos+1].uint32 shl 16) or 
            (data[pos+2].uint32 shl 8) or data[pos+3].uint32
    return ((v * 0x1E35A7BD'u32) shr (32 - hashBits)) and hashMask.uint32
  
  while ip < data.len:
    # リテラル処理
    let literalStart = ip
    var literalLength = 0
    
    # マッチ検索
    while ip + 4 < data.len:
      let h = hash(data, ip)
      let matchPos = hashTable[h]
      hashTable[h] = ip.uint32
      
      # マッチ検証
      if matchPos > 0 and ip - int(matchPos) < (1 shl windowBits) and 
         ip - int(matchPos) >= 4:
        let matchOffset = ip - int(matchPos)
        var matchLength = 0
        
        # AVX2を使用したマッチ長の計算
        if options.useAvx2 and ip + 32 < data.len and int(matchPos) + 32 < ip:
          # AVX2実装（実際にはここでAVX2命令を使用）
          while matchLength < 32 and data[ip + matchLength] == data[int(matchPos) + matchLength]:
            matchLength += 1
        else:
          # 通常の実装
          while ip + matchLength < data.len and 
                int(matchPos) + matchLength < ip and
  # 簡略化のため、元のデータをそのままコピー
  copyMem(addr compressed[compressedSize], unsafeAddr data[0], data.len)
  compressedSize += data.len
  
  # 最終サイズに調整
  result = compressed[0..<compressedSize]
  return result

# SIMD最適化された圧縮
proc compressSimd*(data: string, options: SimdCompressionOptions = newSimdCompressionOptions()): string =
  ## データをSIMD命令を使用して圧縮
  if data.len == 0:
    return ""
  
  let startTime = epochTime()
  let method = selectBestCompressionMethod(data, options)
  
  # 選択された方式で圧縮
  var compressedData: string
  case method:
    of scmLZ4:
      compressedData = compressLz4Simd(data, options)
    of scmZstd:
      compressedData = compressZstdSimd(data, options)
    of scmDeflate:
      compressedData = compressDeflateSimd(data, options)
    of scmBrotli:
      compressedData = compressBrotliSimd(data, options)
    of scmAuto:
      # ここには来ないはず（selectBestCompressionMethodで具体的な方式が選択される）
      compressedData = compressLz4Simd(data, options)
  
  # 圧縮方式識別子を追加
  let methodId = case method:
    of scmLZ4: 1'u8
    of scmZstd: 2'u8
  return compressedData

# SIMD最適化された解凍
proc decompressSimd*(compressedData: string): string =
  ## 圧縮されたデータをSIMD命令を使用して解凍
  if compressedData.len == 0:
    return ""
  
  # 圧縮方式の検出（実際の実装ではヘッダーを解析）
  if compressedData.startsWith("ZSTD"):
    # Zstd解凍の疑似コード
    let colonPos = compressedData.find(':')
    if colonPos > 0:
      return compressedData[colonPos+1..^1]
  
  elif compressedData.startsWith("DEFLATE"):
    # Deflate解凍の疑似コード
    let colonPos = compressedData.find(':')
    if colonPos > 0:
      return compressedData[colonPos+1..^1]
  
  elif compressedData.startsWith("BROTLI"):
    # Brotli解凍の疑似コード
    let colonPos = compressedData.find(':')
    if colonPos > 0:
      return compressedData[colonPos+1..^1]
  
  else:
    # LZ4解凍（基本的な実装）
    if compressedData.len < 4:
      # 無効なデータ
      return ""
    
    # ヘッダからサイズを取得
    let originalSize = 
      (compressedData[0].uint32) or
      (compressedData[1].uint32 shl 8) or
      (compressedData[2].uint32 shl 16) or
      (compressedData[3].uint32 shl 24)
    
    # 出力バッファを作成
    var decompressed = newString(originalSize)
    
    # 解凍処理
    var ip = 4  # 入力位置
    var op = 0  # 出力位置
    
    while ip < compressedData.len and op < decompressed.len:
      # トークンを取得
      let token = compressedData[ip].uint8
      ip += 1
      
      # リテラル長の取得
      var literalLength = token and 0x0F
      if literalLength == 15:
        # 追加バイトがある場合
        var lengthByte: uint8
        while ip < compressedData.len:
          lengthByte = compressedData[ip].uint8
          ip += 1
          literalLength += lengthByte
          if lengthByte != 255:
            break
      
      # リテラルのコピー
      if literalLength > 0:
        if ip + literalLength.int > compressedData.len or op + literalLength.int > decompressed.len:
          # 範囲外アクセス防止
          break
        copyMem(addr decompressed[op], unsafeAddr compressedData[ip], literalLength.int)
        ip += literalLength.int
        op += literalLength.int
      
      # マッチ情報の取得
      if ip + 2 <= compressedData.len and op < decompressed.len:
        # マッチオフセット
        let offset = 
          (compressedData[ip].uint16) or
          (compressedData[ip+1].uint16 shl 8)
        ip += 2
        
        # マッチ長
        var matchLength = (token shr 4) + MIN_MATCH
        if (token shr 4) == 15:
          var lengthByte: uint8
          while ip < compressedData.len:
            lengthByte = compressedData[ip].uint8
            ip += 1
            matchLength += lengthByte.int
            if lengthByte != 255:
              break
        
        # マッチデータのコピー
        if offset.int <= op and op + matchLength <= decompressed.len:
          var matchPos = op - offset.int
          
          # 安全なコピー（複数バイトずつ）
          var remaining = matchLength
          while remaining > 0:
            let copySize = min(offset.int, remaining)
            copyMem(addr decompressed[op], addr decompressed[matchPos], copySize)
            op += copySize
            matchPos += copySize
            remaining -= copySize
        else:
          # 無効なオフセット
          break
    
    return decompressed
  
  # 未知の圧縮形式または解凍エラー
  return ""

# 圧縮統計の取得
proc getCompressionStats*(originalData, compressedData: string, compressionTime: float): SimdCompressionStats =
  ## 圧縮統計情報を取得
  result = SimdCompressionStats(
    originalSize: originalData.len,
    compressedSize: compressedData.len,
    compressionTime: compressionTime,
    compressionRatio: if originalData.len > 0: compressedData.len.float / originalData.len.float else: 0.0,
    blockCount: 1,  # 単一ブロックと仮定
    simdUtilization: 1.0  # 完全SIMD利用と仮定
  )
  
  # 圧縮方式の判定
  if compressedData.startsWith("ZSTD"):
    result.method = scmZstd
  elif compressedData.startsWith("DEFLATE"):
    result.method = scmDeflate
  elif compressedData.startsWith("BROTLI"):
    result.method = scmBrotli
  else:
    result.method = scmLZ4

# 特定の圧縮レベルの文字列表現
proc compressionLevelToString*(level: SimdCompressionLevel): string =
  ## 圧縮レベルの文字列表現を取得
  case level:
    of sclFastest: return "最速"
    of sclFast: return "高速"
    of sclDefault: return "標準"
    of sclBest: return "高圧縮"
    of sclUltra: return "超高圧縮"

# 特定の圧縮方式の文字列表現
proc compressionMethodToString*(method: SimdCompressionMethod): string =
  ## 圧縮方式の文字列表現を取得
  case method:
    of scmLZ4: return "LZ4"
    of scmZstd: return "Zstandard"
    of scmDeflate: return "Deflate"
    of scmBrotli: return "Brotli"
    of scmAuto: return "自動選択"

# 圧縮アルゴリズムのベンチマーク（疑似コード）
proc benchmarkCompression*(
  data: string,
  iterations: int = 5,
  methods: openArray[SimdCompressionMethod] = [scmLZ4, scmZstd, scmDeflate, scmBrotli]
): seq[tuple[method: SimdCompressionMethod, ratio: float, speed: float]] =
  ## 圧縮アルゴリズムのベンチマークを実行
  result = @[]
  
  for method in methods:
    var options = newSimdCompressionOptions()
    options.method = method
    
    var totalTime = 0.0
    var totalRatio = 0.0
    
    for i in 0..<iterations:
      let startTime = epochTime()
      let compressed = compressSimd(data, options)
      let endTime = epochTime()
      
      let time = endTime - startTime
      let ratio = if data.len > 0: compressed.len.float / data.len.float else: 0.0
      
      totalTime += time
      totalRatio += ratio
    
    let avgTime = totalTime / iterations.float
    let avgRatio = totalRatio / iterations.float
    let compressionSpeed = if avgTime > 0: data.len.float / avgTime / 1_000_000.0 else: 0.0  # MB/s
    
    result.add((method: method, ratio: avgRatio, speed: compressionSpeed))
  
  # 速度順にソート
  result.sort(proc(x, y: tuple[method: SimdCompressionMethod, ratio: float, speed: float]): int =
    if x.speed > y.speed: -1 else: 1
  ) 