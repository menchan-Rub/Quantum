# zstd.nim
## zstandard圧縮・解凍機能を提供するモジュール
## Facebook開発の高速・高圧縮率アルゴリズム

import std/[streams, strutils, os, dynlib, times]
import ../common/compression_base

type
  ZstdCompressionLevel* = range[-22..22]
    ## Zstd圧縮レベル（-22～22、負の値は高速低圧縮、正の値は高圧縮）
  
  ZstdDict* = distinct pointer
    ## Zstd辞書オブジェクト
  
  ZstdCCtx = distinct pointer
    ## 圧縮コンテキスト
  
  ZstdDCtx = distinct pointer
    ## 解凍コンテキスト
  
  ZstdOption* = object
    level*: ZstdCompressionLevel  ## 圧縮レベル
    dict*: string                ## 辞書データ（オプション）
    checksumFlag*: bool          ## チェックサムを含めるか
    nbWorkers*: int              ## マルチスレッド処理のワーカー数（0=シングルスレッド）
  
  ZstdError* = object of CompressionError
    ## Zstd処理中のエラー

const
  DEFAULT_LEVEL = 3             ## デフォルト圧縮レベル
  DEFAULT_BUFFER_SIZE = 131072  ## デフォルトバッファサイズ（128KB）
  ZSTD_ERROR_PREFIX = -1        ## Zstdエラー値の接頭辞

var
  # 動的ライブラリのハンドル
  libZstd: LibHandle = nil
  
  # 関数ポインタ
  ZSTD_compressBound: proc(srcSize: csize_t): csize_t {.cdecl.}
  ZSTD_compress: proc(dst: pointer, dstCapacity: csize_t, src: pointer, srcSize: csize_t, 
                     compressionLevel: cint): csize_t {.cdecl.}
  ZSTD_decompress: proc(dst: pointer, dstCapacity: csize_t, src: pointer, compressedSize: csize_t): csize_t {.cdecl.}
  
  # コンテキスト関数
  ZSTD_createCCtx: proc(): ZstdCCtx {.cdecl.}
  ZSTD_freeCCtx: proc(cctx: ZstdCCtx): csize_t {.cdecl.}
  ZSTD_compressStream2: proc(cctx: ZstdCCtx, output: pointer, outCapacity: ptr csize_t, 
                           input: pointer, inCapacity: ptr csize_t, endOp: cint): csize_t {.cdecl.}
  ZSTD_CCtx_setParameter: proc(cctx: ZstdCCtx, param: cint, value: cint): csize_t {.cdecl.}
  
  ZSTD_createDCtx: proc(): ZstdDCtx {.cdecl.}
  ZSTD_freeDCtx: proc(dctx: ZstdDCtx): csize_t {.cdecl.}
  ZSTD_decompressStream: proc(dctx: ZstdDCtx, output: pointer, outCapacity: ptr csize_t,
                            input: pointer, inCapacity: ptr csize_t): csize_t {.cdecl.}
  
  # エラー関数
  ZSTD_isError: proc(code: csize_t): cuint {.cdecl.}
  ZSTD_getErrorName: proc(code: csize_t): cstring {.cdecl.}
  ZSTD_getErrorCode: proc(code: csize_t): cint {.cdecl.}

# Zstdパラメータ定数
const
  ZSTD_c_compressionLevel = 100
  ZSTD_c_checksumFlag = 201
  ZSTD_c_nbWorkers = 400
  
  # エンドオペレーション
  ZSTD_e_continue = 0
  ZSTD_e_flush = 1
  ZSTD_e_end = 2

proc loadZstdLib() =
  ## Zstd動的ライブラリをロードする
  if libZstd != nil:
    return
  
  const
    # プラットフォームごとのライブラリ名
    libNames = when defined(windows):
                ["zstd.dll", "libzstd.dll"]
              elif defined(macosx):
                ["libzstd.dylib", "libzstd.1.dylib"]
              else:
                ["libzstd.so", "libzstd.so.1"]
  
  # ライブラリを探して読み込み
  for libName in libNames:
    libZstd = loadLib(libName)
    if libZstd != nil:
      break
  
  if libZstd == nil:
    # 内蔵バージョンを試す
    let internalLibPath = getAppDir() / "libs" / 
                         when defined(windows): "zstd.dll"
                         elif defined(macosx): "libzstd.dylib" 
                         else: "libzstd.so"
    
    if fileExists(internalLibPath):
      libZstd = loadLib(internalLibPath)
  
  if libZstd == nil:
    raise newException(ZstdError, "Zstdライブラリをロードできませんでした")
  
  # 基本関数を取得
  ZSTD_compressBound = cast[proc(srcSize: csize_t): csize_t {.cdecl.}](
    symAddr(libZstd, "ZSTD_compressBound"))
  
  ZSTD_compress = cast[proc(dst: pointer, dstCapacity: csize_t, src: pointer, srcSize: csize_t, 
                          compressionLevel: cint): csize_t {.cdecl.}](
                          symAddr(libZstd, "ZSTD_compress"))
  
  ZSTD_decompress = cast[proc(dst: pointer, dstCapacity: csize_t, src: pointer, compressedSize: csize_t): csize_t {.cdecl.}](
    symAddr(libZstd, "ZSTD_decompress"))
  
  # コンテキスト関数を取得
  ZSTD_createCCtx = cast[proc(): ZstdCCtx {.cdecl.}](
    symAddr(libZstd, "ZSTD_createCCtx"))
  
  ZSTD_freeCCtx = cast[proc(cctx: ZstdCCtx): csize_t {.cdecl.}](
    symAddr(libZstd, "ZSTD_freeCCtx"))
  
  ZSTD_compressStream2 = cast[proc(cctx: ZstdCCtx, output: pointer, outCapacity: ptr csize_t, 
                                 input: pointer, inCapacity: ptr csize_t, endOp: cint): csize_t {.cdecl.}](
                                 symAddr(libZstd, "ZSTD_compressStream2"))
  
  ZSTD_CCtx_setParameter = cast[proc(cctx: ZstdCCtx, param: cint, value: cint): csize_t {.cdecl.}](
    symAddr(libZstd, "ZSTD_CCtx_setParameter"))
  
  ZSTD_createDCtx = cast[proc(): ZstdDCtx {.cdecl.}](
    symAddr(libZstd, "ZSTD_createDCtx"))
  
  ZSTD_freeDCtx = cast[proc(dctx: ZstdDCtx): csize_t {.cdecl.}](
    symAddr(libZstd, "ZSTD_freeDCtx"))
  
  ZSTD_decompressStream = cast[proc(dctx: ZstdDCtx, output: pointer, outCapacity: ptr csize_t,
                                  input: pointer, inCapacity: ptr csize_t): csize_t {.cdecl.}](
                                  symAddr(libZstd, "ZSTD_decompressStream"))
  
  # エラー関数を取得
  ZSTD_isError = cast[proc(code: csize_t): cuint {.cdecl.}](
    symAddr(libZstd, "ZSTD_isError"))
  
  ZSTD_getErrorName = cast[proc(code: csize_t): cstring {.cdecl.}](
    symAddr(libZstd, "ZSTD_getErrorName"))
  
  ZSTD_getErrorCode = cast[proc(code: csize_t): cint {.cdecl.}](
    symAddr(libZstd, "ZSTD_getErrorCode"))
  
  # 必須の関数が取得できなかった場合はエラー
  if ZSTD_compress == nil or ZSTD_decompress == nil or
     ZSTD_createCCtx == nil or ZSTD_freeCCtx == nil or
     ZSTD_compressStream2 == nil or ZSTD_createDCtx == nil or
     ZSTD_freeDCtx == nil or ZSTD_decompressStream == nil:
    when not defined(release):
      echo "Failed to load required Zstd functions"
    raise newException(ZstdError, "Zstdライブラリから必要な関数を取得できませんでした")

proc newZstdOption*(level: ZstdCompressionLevel = DEFAULT_LEVEL, 
                  dict: string = "", 
                  checksumFlag: bool = false,
                  nbWorkers: int = 0): ZstdOption =
  ## 新しいZstd圧縮オプションを作成する
  ## - level: 圧縮レベル (-22から22)
  ## - dict: 辞書データ（オプション）
  ## - checksumFlag: チェックサムを含めるか
  ## - nbWorkers: マルチスレッド処理のワーカー数（0=シングルスレッド）
  result = ZstdOption(
    level: level,
    dict: dict,
    checksumFlag: checksumFlag,
    nbWorkers: nbWorkers
  )

proc isZstdError(code: csize_t): bool {.inline.} =
  ## Zstdエラーコードをチェック
  if ZSTD_isError == nil:
    return code == 0 or (code and (ZSTD_ERROR_PREFIX shl 24)) != 0
  return ZSTD_isError(code) != 0

proc getZstdErrorMsg(code: csize_t): string =
  ## Zstdエラーメッセージを取得
  if ZSTD_getErrorName == nil:
    return "Zstdエラー（コード: " & $code & "）"
  return $ZSTD_getErrorName(code)

proc compress*(input: string, options: ZstdOption = newZstdOption()): string =
  ## 文字列をZstd形式で圧縮する
  loadZstdLib()
  
  # 入力が空の場合は空文字列を返す
  if input.len == 0:
    return ""
  
  # 圧縮後の最大サイズを計算
  let maxCompressedSize = ZSTD_compressBound(input.len.csize_t)
  
  # 圧縮コンテキストを作成
  var cctx = ZSTD_createCCtx()
  if cctx == nil:
    raise newException(ZstdError, "圧縮コンテキストの作成に失敗しました")
  
  defer: discard ZSTD_freeCCtx(cctx)
  
  # パラメータを設定
  discard ZSTD_CCtx_setParameter(cctx, ZSTD_c_compressionLevel, options.level.cint)
  discard ZSTD_CCtx_setParameter(cctx, ZSTD_c_checksumFlag, options.checksumFlag.cint)
  
  if options.nbWorkers > 0:
    discard ZSTD_CCtx_setParameter(cctx, ZSTD_c_nbWorkers, options.nbWorkers.cint)
  
  # 出力バッファを確保
  var output = newString(maxCompressedSize)
  
  # 入力/出力バッファの設定
  var inBuf = input
  var inSize = input.len.csize_t
  var outSize = maxCompressedSize
  
  # ワンショット圧縮
  let compressedSize = ZSTD_compressStream2(
    cctx,
    output[0].addr, outSize.addr,
    inBuf[0].addr, inSize.addr,
    ZSTD_e_end
  )
  
  if isZstdError(compressedSize):
    raise newException(ZstdError, "圧縮に失敗しました: " & getZstdErrorMsg(compressedSize))
  
  # 圧縮されたデータのみを返す
  result = output[0..<compressedSize]

proc decompress*(input: string): string =
  ## Zstd圧縮された文字列を解凍する
  loadZstdLib()
  
  # 入力が空の場合は空文字列を返す
  if input.len == 0:
    return ""
  
  # 解凍コンテキストを作成
  var dctx = ZSTD_createDCtx()
  if dctx == nil:
    raise newException(ZstdError, "解凍コンテキストの作成に失敗しました")
  
  defer: discard ZSTD_freeDCtx(dctx)
  
  var outputSize = 0.csize_t
  var output = ""
  var inBuf = input
  var inSize = input.len.csize_t
  
  # 解凍した結果を格納するバッファ
  var outBuf = newString(DEFAULT_BUFFER_SIZE)
  
  # ストリーム解凍
  while inSize > 0:
    var outSize = DEFAULT_BUFFER_SIZE.csize_t
    
    let remaining = ZSTD_decompressStream(
      dctx,
      outBuf[0].addr, outSize.addr,
      inBuf[0].addr, inSize.addr
    )
    
    if isZstdError(remaining):
      raise newException(ZstdError, "解凍に失敗しました: " & getZstdErrorMsg(remaining))
    
    # 解凍されたデータを追加
    if outSize > 0:
      output.add(outBuf[0..<outSize])
    
    # 入力バッファを更新
    inBuf = inBuf[input.len - inSize.int..^1]
    
    # 入力をすべて消費したか終了フラグが立った場合
    if inSize == 0 or remaining == 0:
      break
  
  return output

proc compressFile*(inputFile, outputFile: string, options: ZstdOption = newZstdOption()) =
  ## ファイルをZstd形式で圧縮する
  let inData = readFile(inputFile)
  let compressedData = compress(inData, options)
  writeFile(outputFile, compressedData)

proc decompressFile*(inputFile, outputFile: string) =
  ## Zstd圧縮されたファイルを解凍する
  let compressedData = readFile(inputFile)
  let decompressedData = decompress(compressedData)
  writeFile(outputFile, decompressedData)

proc compressStream*(input, output: Stream, options: ZstdOption = newZstdOption(), bufferSize: int = DEFAULT_BUFFER_SIZE) =
  ## ストリームをZstd形式で圧縮する（大きなデータ向け）
  loadZstdLib()
  
  # 圧縮コンテキストを作成
  var cctx = ZSTD_createCCtx()
  if cctx == nil:
    raise newException(ZstdError, "圧縮コンテキストの作成に失敗しました")
  
  defer: discard ZSTD_freeCCtx(cctx)
  
  # パラメータを設定
  discard ZSTD_CCtx_setParameter(cctx, ZSTD_c_compressionLevel, options.level.cint)
  discard ZSTD_CCtx_setParameter(cctx, ZSTD_c_checksumFlag, options.checksumFlag.cint)
  
  if options.nbWorkers > 0:
    discard ZSTD_CCtx_setParameter(cctx, ZSTD_c_nbWorkers, options.nbWorkers.cint)
  
  # バッファを確保
  var inBuf = newString(bufferSize)
  var outBuf = newString(bufferSize)
  
  # データを読み込みながら圧縮
  var endOfFile = false
  while not endOfFile:
    # 入力データを読み込む
    let bytesRead = input.readData(inBuf[0].addr, bufferSize)
    endOfFile = bytesRead < bufferSize
    
    # エンドオペレーションを決定
    let endOp = if endOfFile: ZSTD_e_end else: ZSTD_e_continue
    
    # 読み込んだデータを圧縮
    var inSize = bytesRead.csize_t
    var inPtr = inBuf[0].addr
    
    # このチャンクのすべてのデータを圧縮
    while inSize > 0 or (endOfFile and endOp == ZSTD_e_end):
      var outSize = bufferSize.csize_t
      
      let remaining = ZSTD_compressStream2(
        cctx,
        outBuf[0].addr, outSize.addr,
        inPtr, inSize.addr,
        endOp
      )
      
      if isZstdError(remaining):
        raise newException(ZstdError, "圧縮に失敗しました: " & getZstdErrorMsg(remaining))
      
      # 圧縮されたデータを書き込む
      if outSize > 0:
        output.writeData(outBuf[0].addr, outSize)
      
      # 入力ポインタを更新
      inPtr = cast[pointer](cast[int](inPtr) + (bytesRead - inSize.int))
      
      # すべての入力を消費し、終了フラグが立った場合
      if inSize == 0 and (endOp != ZSTD_e_end or remaining == 0):
        break

proc decompressStream*(input, output: Stream, bufferSize: int = DEFAULT_BUFFER_SIZE) =
  ## Zstd圧縮されたストリームを解凍する（大きなデータ向け）
  loadZstdLib()
  
  # 解凍コンテキストを作成
  var dctx = ZSTD_createDCtx()
  if dctx == nil:
    raise newException(ZstdError, "解凍コンテキストの作成に失敗しました")
  
  defer: discard ZSTD_freeDCtx(dctx)
  
  # バッファを確保
  var inBuf = newString(bufferSize)
  var outBuf = newString(bufferSize)
  var lastOutput = 0.csize_t
  
  # データを読み込みながら解凍
  while not input.atEnd:
    # 入力データを読み込む
    let bytesRead = input.readData(inBuf[0].addr, bufferSize)
    if bytesRead == 0:
      break
    
    # 読み込んだデータを解凍
    var inSize = bytesRead.csize_t
    var inPtr = inBuf[0].addr
    
    # このチャンクのすべてのデータを解凍
    while inSize > 0 or lastOutput > 0:
      var outSize = bufferSize.csize_t
      
      lastOutput = ZSTD_decompressStream(
        dctx,
        outBuf[0].addr, outSize.addr,
        inPtr, inSize.addr
      )
      
      if isZstdError(lastOutput):
        raise newException(ZstdError, "解凍に失敗しました: " & getZstdErrorMsg(lastOutput))
      
      # 解凍されたデータを書き込む
      if outSize > 0:
        output.writeData(outBuf[0].addr, outSize)
      
      # 入力ポインタを更新
      inPtr = cast[pointer](cast[int](inPtr) + (bytesRead - inSize.int))
      
      # すべての入力を消費し、出力がない場合
      if inSize == 0 and outSize == 0:
        break
``` 