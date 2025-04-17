# brotli.nim
## brotli圧縮・解凍機能を提供するモジュール
## Brotliは高圧縮率を持つGoogleが開発した圧縮アルゴリズム
## RFC 7932 (Brotli Compressed Data Format)に準拠した実装

import std/[streams, strutils, os, dynlib]
import ../common/compression_base

type
  BrotliCompressionLevel* = range[0..11]
    ## Brotli圧縮レベル（0が非圧縮、11が最高圧縮率）
  
  BrotliCompressionMode* = enum
    bmGeneric = 0,      ## 汎用データ向け
    bmText = 1,         ## UTF-8テキスト向け
    bmFont = 2          ## Webフォント向け
  
  BrotliEncoderState = distinct pointer
    ## Brotliエンコーダーの内部状態（opaque）
  
  BrotliDecoderState = distinct pointer
    ## Brotliデコーダーの内部状態（opaque）
  
  BrotliEncoderOperation = enum
    BROTLI_OPERATION_PROCESS = 0,
    BROTLI_OPERATION_FLUSH = 1,
    BROTLI_OPERATION_FINISH = 2,
    BROTLI_OPERATION_EMIT_METADATA = 3
  
  BrotliDecoderResult = enum
    BROTLI_DECODER_RESULT_ERROR = 0,
    BROTLI_DECODER_RESULT_SUCCESS = 1,
    BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT = 2,
    BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT = 3
  
  BrotliOption* = object
    quality*: BrotliCompressionLevel  ## 圧縮品質 0-11
    mode*: BrotliCompressionMode      ## 圧縮モード
    lgwin*: int                       ## ウィンドウサイズ (10-24)
    lgblock*: int                     ## ブロックサイズ (16-24)
  
  BrotliError* = object of CompressionError
    ## Brotli処理中のエラー

const
  DEFAULT_QUALITY = 4            ## デフォルト品質レベル（4は高速・中圧縮）
  DEFAULT_WINDOW = 22            ## デフォルトウィンドウサイズ（約4MB）
  DEFAULT_BLOCK = 0              ## デフォルトブロックサイズ（自動）
  DEFAULT_MODE = bmGeneric       ## デフォルトモード
  DEFAULT_BUFFER_SIZE = 65536    ## デフォルトバッファサイズ（64KB）

var
  # 動的ライブラリのハンドル
  libBrotli: LibHandle = nil
  
  # エンコーダー関数ポインタ
  BrotliEncoderCreateProc: proc(): BrotliEncoderState {.cdecl.}
  BrotliEncoderSetParameterProc: proc(state: BrotliEncoderState, param: cint, value: cuint): cint {.cdecl.}
  BrotliEncoderCompressStreamProc: proc(state: BrotliEncoderState, op: BrotliEncoderOperation, 
                                    available_in: ptr csize_t, next_in: ptr cuchar,
                                    available_out: ptr csize_t, next_out: ptr cuchar,
                                    total_out: ptr csize_t): cint {.cdecl.}
  BrotliEncoderHasMoreOutputProc: proc(state: BrotliEncoderState): cint {.cdecl.}
  BrotliEncoderIsFinishedProc: proc(state: BrotliEncoderState): cint {.cdecl.}
  BrotliEncoderDestroyProc: proc(state: BrotliEncoderState) {.cdecl.}
  
  # デコーダー関数ポインタ
  BrotliDecoderCreateProc: proc(): BrotliDecoderState {.cdecl.}
  BrotliDecoderDecompressStreamProc: proc(state: BrotliDecoderState,
                                      available_in: ptr csize_t, next_in: ptr cuchar,
                                      available_out: ptr csize_t, next_out: ptr cuchar,
                                      total_out: ptr csize_t): BrotliDecoderResult {.cdecl.}
  BrotliDecoderIsFinishedProc: proc(state: BrotliDecoderState): cint {.cdecl.}
  BrotliDecoderDestroyProc: proc(state: BrotliDecoderState) {.cdecl.}
  BrotliDecoderGetErrorCodeProc: proc(state: BrotliDecoderState): cint {.cdecl.}
  BrotliDecoderErrorStringProc: proc(code: cint): cstring {.cdecl.}

# Brotliライブラリのパラメータ定数
const
  BROTLI_PARAM_MODE = 0
  BROTLI_PARAM_QUALITY = 1
  BROTLI_PARAM_LGWIN = 2
  BROTLI_PARAM_LGBLOCK = 3

proc loadBrotliLib() =
  ## Brotli動的ライブラリをロードする
  if libBrotli != nil:
    return
  
  const
    # プラットフォームごとのライブラリ名
    libNames = when defined(windows):
                ["brotli.dll", "libbrotli.dll"]
              elif defined(macosx):
                ["libbrotli.dylib", "libbrotli.1.dylib"]
              else:
                ["libbrotli.so", "libbrotli.so.1"]
  
  # ライブラリを探して読み込み
  for libName in libNames:
    libBrotli = loadLib(libName)
    if libBrotli != nil:
      break
  
  if libBrotli == nil:
    # 内蔵バージョンを試す (システム依存)
    let internalLibPath = getAppDir() / "libs" / 
                         when defined(windows): "brotli.dll"
                         elif defined(macosx): "libbrotli.dylib" 
                         else: "libbrotli.so"
    
    if fileExists(internalLibPath):
      libBrotli = loadLib(internalLibPath)
  
  if libBrotli == nil:
    raise newException(BrotliError, "Brotliライブラリをロードできませんでした")
  
  # エンコーダー関数を取得
  BrotliEncoderCreateProc = cast[proc(): BrotliEncoderState {.cdecl.}](symAddr(libBrotli, "BrotliEncoderCreateInstance"))
  if BrotliEncoderCreateProc == nil:
    BrotliEncoderCreateProc = cast[proc(): BrotliEncoderState {.cdecl.}](symAddr(libBrotli, "BrotliEncoderCreate"))
  
  BrotliEncoderSetParameterProc = cast[proc(state: BrotliEncoderState, param: cint, value: cuint): cint {.cdecl.}](
    symAddr(libBrotli, "BrotliEncoderSetParameter"))
  
  BrotliEncoderCompressStreamProc = cast[proc(state: BrotliEncoderState, op: BrotliEncoderOperation, 
                                          available_in: ptr csize_t, next_in: ptr cuchar,
                                          available_out: ptr csize_t, next_out: ptr cuchar,
                                          total_out: ptr csize_t): cint {.cdecl.}](
                                          symAddr(libBrotli, "BrotliEncoderCompressStream"))
  
  BrotliEncoderIsFinishedProc = cast[proc(state: BrotliEncoderState): cint {.cdecl.}](
    symAddr(libBrotli, "BrotliEncoderIsFinished"))
  
  BrotliEncoderHasMoreOutputProc = cast[proc(state: BrotliEncoderState): cint {.cdecl.}](
    symAddr(libBrotli, "BrotliEncoderHasMoreOutput"))
  
  BrotliEncoderDestroyProc = cast[proc(state: BrotliEncoderState) {.cdecl.}](
    symAddr(libBrotli, "BrotliEncoderDestroyInstance"))
  
  if BrotliEncoderDestroyProc == nil:
    BrotliEncoderDestroyProc = cast[proc(state: BrotliEncoderState) {.cdecl.}](
      symAddr(libBrotli, "BrotliEncoderDestroy"))
  
  # デコーダー関数を取得
  BrotliDecoderCreateProc = cast[proc(): BrotliDecoderState {.cdecl.}](
    symAddr(libBrotli, "BrotliDecoderCreateInstance"))
  
  if BrotliDecoderCreateProc == nil:
    BrotliDecoderCreateProc = cast[proc(): BrotliDecoderState {.cdecl.}](
      symAddr(libBrotli, "BrotliDecoderCreate"))
  
  BrotliDecoderDecompressStreamProc = cast[proc(state: BrotliDecoderState,
                                            available_in: ptr csize_t, next_in: ptr cuchar,
                                            available_out: ptr csize_t, next_out: ptr cuchar,
                                            total_out: ptr csize_t): BrotliDecoderResult {.cdecl.}](
                                            symAddr(libBrotli, "BrotliDecoderDecompressStream"))
  
  BrotliDecoderIsFinishedProc = cast[proc(state: BrotliDecoderState): cint {.cdecl.}](
    symAddr(libBrotli, "BrotliDecoderIsFinished"))
  
  BrotliDecoderDestroyProc = cast[proc(state: BrotliDecoderState) {.cdecl.}](
    symAddr(libBrotli, "BrotliDecoderDestroyInstance"))
  
  if BrotliDecoderDestroyProc == nil:
    BrotliDecoderDestroyProc = cast[proc(state: BrotliDecoderState) {.cdecl.}](
      symAddr(libBrotli, "BrotliDecoderDestroy"))
  
  BrotliDecoderGetErrorCodeProc = cast[proc(state: BrotliDecoderState): cint {.cdecl.}](
    symAddr(libBrotli, "BrotliDecoderGetErrorCode"))
  
  BrotliDecoderErrorStringProc = cast[proc(code: cint): cstring {.cdecl.}](
    symAddr(libBrotli, "BrotliDecoderErrorString"))
  
  # 必須の関数が取得できなかった場合はエラー
  if BrotliEncoderCreateProc == nil or BrotliEncoderCompressStreamProc == nil or
     BrotliEncoderDestroyProc == nil or BrotliDecoderCreateProc == nil or
     BrotliDecoderDecompressStreamProc == nil or BrotliDecoderDestroyProc == nil:
    when not defined(release):
      echo "Failed to load required Brotli functions"
    raise newException(BrotliError, "Brotliライブラリから必要な関数を取得できませんでした")

proc newBrotliOption*(quality: BrotliCompressionLevel = DEFAULT_QUALITY, 
                    mode: BrotliCompressionMode = DEFAULT_MODE,
                    lgwin: int = DEFAULT_WINDOW,
                    lgblock: int = DEFAULT_BLOCK): BrotliOption =
  ## 新しいBrotli圧縮オプションを作成する
  ## - quality: 圧縮品質 (0-11)
  ## - mode: 圧縮モード (汎用、テキスト、フォント)
  ## - lgwin: ウィンドウサイズの対数 (10-24)
  ## - lgblock: ブロックサイズの対数 (16-24)
  if lgwin < 10 or lgwin > 24:
    raise newException(BrotliError, "無効なウィンドウサイズ。10から24の間でなければなりません")
  
  if lgblock != 0 and (lgblock < 16 or lgblock > 24):
    raise newException(BrotliError, "無効なブロックサイズ。0または16から24の間でなければなりません")
  
  result = BrotliOption(
    quality: quality,
    mode: mode,
    lgwin: lgwin,
    lgblock: lgblock
  )

proc compress*(input: string, options: BrotliOption = newBrotliOption()): string =
  ## 文字列をBrotli形式で圧縮する
  loadBrotliLib()
  
  # エンコーダーを作成
  var state = BrotliEncoderCreateProc()
  if state == nil:
    raise newException(BrotliError, "Brotliエンコーダーの作成に失敗しました")
  
  defer: BrotliEncoderDestroyProc(state)
  
  # パラメータを設定
  discard BrotliEncoderSetParameterProc(state, BROTLI_PARAM_MODE, cuint(options.mode))
  discard BrotliEncoderSetParameterProc(state, BROTLI_PARAM_QUALITY, cuint(options.quality))
  discard BrotliEncoderSetParameterProc(state, BROTLI_PARAM_LGWIN, cuint(options.lgwin))
  
  if options.lgblock > 0:
    discard BrotliEncoderSetParameterProc(state, BROTLI_PARAM_LGBLOCK, cuint(options.lgblock))
  
  # バッファの設定
  var output = newStringOfCap(input.len)
  var outBuffer = newString(DEFAULT_BUFFER_SIZE)
  
  # 入力データの準備
  var next_in: ptr cuchar = cast[ptr cuchar](input.cstring)
  var available_in: csize_t = input.len.csize_t
  
  # 圧縮を実行
  while true:
    # 出力バッファの設定
    var next_out: ptr cuchar = cast[ptr cuchar](outBuffer[0].addr)
    var available_out: csize_t = outBuffer.len.csize_t
    var total_out: csize_t = 0
    
    # 必要な操作を決定
    let op = if available_in == 0: BROTLI_OPERATION_FINISH else: BROTLI_OPERATION_PROCESS
    
    # 圧縮ストリームを処理
    let success = BrotliEncoderCompressStreamProc(
      state, op, available_in.addr, next_in, available_out.addr, next_out, total_out.addr
    )
    
    if success == 0:
      raise newException(BrotliError, "圧縮プロセス中にエラーが発生しました")
    
    # 出力されたデータを追加
    if total_out > 0:
      output.add(outBuffer[0..<total_out])
    
    # 入力ポインタを更新
    if available_in > 0:
      next_in = cast[ptr cuchar](cast[int](next_in) + (input.len.csize_t - available_in))
    
    # 終了条件を確認
    if BrotliEncoderIsFinishedProc(state) != 0:
      break
    
    # 追加の出力がある場合は続行
    if BrotliEncoderHasMoreOutputProc(state) != 0:
      continue
    
    # 入力がすべて消費され、追加の出力がない場合
    if available_in == 0 and BrotliEncoderHasMoreOutputProc(state) == 0:
      continue
  
  return output

proc decompress*(input: string): string =
  ## Brotli圧縮された文字列を解凍する
  loadBrotliLib()
  
  # デコーダーを作成
  var state = BrotliDecoderCreateProc()
  if state == nil:
    raise newException(BrotliError, "Brotliデコーダーの作成に失敗しました")
  
  defer: BrotliDecoderDestroyProc(state)
  
  # バッファの設定
  var output = newStringOfCap(input.len * 4) # 展開後は元サイズの数倍になることが多い
  var outBuffer = newString(DEFAULT_BUFFER_SIZE)
  
  # 入力データの準備
  var next_in: ptr cuchar = cast[ptr cuchar](input.cstring)
  var available_in: csize_t = input.len.csize_t
  
  # 解凍を実行
  while true:
    # 出力バッファの設定
    var next_out: ptr cuchar = cast[ptr cuchar](outBuffer[0].addr)
    var available_out: csize_t = outBuffer.len.csize_t
    var total_out: csize_t = 0
    
    # 解凍ストリームを処理
    let result = BrotliDecoderDecompressStreamProc(
      state, available_in.addr, next_in, available_out.addr, next_out, total_out.addr
    )
    
    # エラー処理
    if result == BROTLI_DECODER_RESULT_ERROR:
      var errorCode = 0
      if BrotliDecoderGetErrorCodeProc != nil:
        errorCode = BrotliDecoderGetErrorCodeProc(state)
      
      var errorMsg = "解凍プロセス中にエラーが発生しました"
      if BrotliDecoderErrorStringProc != nil:
        errorMsg = $BrotliDecoderErrorStringProc(errorCode.cint)
      
      raise newException(BrotliError, errorMsg)
    
    # 出力されたデータを追加
    if total_out > 0:
      output.add(outBuffer[0..<total_out])
    
    # 入力ポインタを更新
    if available_in > 0:
      next_in = cast[ptr cuchar](cast[int](next_in) + (input.len.csize_t - available_in))
    
    # 終了条件を確認
    if BrotliDecoderIsFinishedProc(state) != 0:
      break
    
    # 追加の入力が必要だが、もう入力がない場合
    if result == BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT and available_in == 0:
      raise newException(BrotliError, "解凍には追加のデータが必要ですが、入力が終了しました")
  
  return output

proc compressFile*(inputFile, outputFile: string, options: BrotliOption = newBrotliOption()) =
  ## ファイルをBrotli形式で圧縮する
  let inData = readFile(inputFile)
  let compressedData = compress(inData, options)
  writeFile(outputFile, compressedData)

proc decompressFile*(inputFile, outputFile: string) =
  ## Brotli圧縮されたファイルを解凍する
  let compressedData = readFile(inputFile)
  let decompressedData = decompress(compressedData)
  writeFile(outputFile, decompressedData)

proc compressStream*(input, output: Stream, options: BrotliOption = newBrotliOption(), bufferSize: int = DEFAULT_BUFFER_SIZE) =
  ## ストリームをBrotli形式で圧縮する（大きなデータ向け）
  loadBrotliLib()
  
  # エンコーダーを作成
  var state = BrotliEncoderCreateProc()
  if state == nil:
    raise newException(BrotliError, "Brotliエンコーダーの作成に失敗しました")
  
  defer: BrotliEncoderDestroyProc(state)
  
  # パラメータを設定
  discard BrotliEncoderSetParameterProc(state, BROTLI_PARAM_MODE, cuint(options.mode))
  discard BrotliEncoderSetParameterProc(state, BROTLI_PARAM_QUALITY, cuint(options.quality))
  discard BrotliEncoderSetParameterProc(state, BROTLI_PARAM_LGWIN, cuint(options.lgwin))
  
  if options.lgblock > 0:
    discard BrotliEncoderSetParameterProc(state, BROTLI_PARAM_LGBLOCK, cuint(options.lgblock))
  
  # バッファの設定
  var inBuf = newString(bufferSize)
  var outBuf = newString(bufferSize)
  
  # データを読み込みながら圧縮
  var bytesRead = input.readData(inBuf[0].addr, bufferSize)
  var isEof = bytesRead < bufferSize
  
  while bytesRead > 0 or not BrotliEncoderIsFinishedProc(state).bool:
    # 入力バッファの設定
    var next_in: ptr cuchar = cast[ptr cuchar](inBuf[0].addr)
    var available_in: csize_t = bytesRead.csize_t
    
    # 操作を決定
    let op = if isEof and available_in == 0: BROTLI_OPERATION_FINISH else: BROTLI_OPERATION_PROCESS
    
    # 入力がすべて処理されるまで圧縮
    while available_in > 0 or op == BROTLI_OPERATION_FINISH and not BrotliEncoderIsFinishedProc(state).bool:
      # 出力バッファの設定
      var next_out: ptr cuchar = cast[ptr cuchar](outBuf[0].addr)
      var available_out: csize_t = outBuf.len.csize_t
      var total_out: csize_t = 0
      
      # 圧縮ストリームを処理
      let success = BrotliEncoderCompressStreamProc(
        state, op, available_in.addr, next_in, available_out.addr, next_out, total_out.addr
      )
      
      if success == 0:
        raise newException(BrotliError, "圧縮プロセス中にエラーが発生しました")
      
      # 圧縮したデータを書き込む
      if total_out > 0:
        output.writeData(outBuf[0].addr, total_out)
      
      # 入力ポインタを更新
      if available_in > 0:
        next_in = cast[ptr cuchar](cast[int](next_in) + (bytesRead.csize_t - available_in))
    
    # 次のデータを読み込む
    if not isEof:
      bytesRead = input.readData(inBuf[0].addr, bufferSize)
      isEof = bytesRead < bufferSize
    else:
      bytesRead = 0

proc decompressStream*(input, output: Stream, bufferSize: int = DEFAULT_BUFFER_SIZE) =
  ## Brotli圧縮されたストリームを解凍する（大きなデータ向け）
  loadBrotliLib()
  
  # デコーダーを作成
  var state = BrotliDecoderCreateProc()
  if state == nil:
    raise newException(BrotliError, "Brotliデコーダーの作成に失敗しました")
  
  defer: BrotliDecoderDestroyProc(state)
  
  # バッファの設定
  var inBuf = newString(bufferSize)
  var outBuf = newString(bufferSize)
  
  # データを読み込みながら解凍
  var bytesRead = input.readData(inBuf[0].addr, bufferSize)
  
  while bytesRead > 0 or not BrotliDecoderIsFinishedProc(state).bool:
    # 入力バッファの設定
    var next_in: ptr cuchar = cast[ptr cuchar](inBuf[0].addr)
    var available_in: csize_t = bytesRead.csize_t
    
    # 入力がすべて処理されるまで解凍
    while available_in > 0 or BrotliDecoderHasMoreOutput(state) and not BrotliDecoderIsFinishedProc(state).bool:
      # 出力バッファの設定
      var next_out: ptr cuchar = cast[ptr cuchar](outBuf[0].addr)
      var available_out: csize_t = outBuf.len.csize_t
      var total_out: csize_t = 0
      
      # 解凍ストリームを処理
      let result = BrotliDecoderDecompressStreamProc(
        state, available_in.addr, next_in, available_out.addr, next_out, total_out.addr
      )
      
      # エラー処理
      if result == BROTLI_DECODER_RESULT_ERROR:
        var errorCode = 0
        if BrotliDecoderGetErrorCodeProc != nil:
          errorCode = BrotliDecoderGetErrorCodeProc(state)
        
        var errorMsg = "解凍プロセス中にエラーが発生しました"
        if BrotliDecoderErrorStringProc != nil:
          errorMsg = $BrotliDecoderErrorStringProc(errorCode.cint)
        
        raise newException(BrotliError, errorMsg)
      
      # 解凍したデータを書き込む
      if total_out > 0:
        output.writeData(outBuf[0].addr, total_out)
      
      # 入力ポインタを更新
      if available_in > 0:
        next_in = cast[ptr cuchar](cast[int](next_in) + (bytesRead.csize_t - available_in))
      
      # 追加の入力が必要だが、エンドオブストリームに達した場合
      if result == BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT and available_in == 0:
        break
    
    # 次のデータを読み込む
    if input.atEnd:
      bytesRead = 0
    else:
      bytesRead = input.readData(inBuf[0].addr, bufferSize)

proc BrotliDecoderHasMoreOutput(state: BrotliDecoderState): bool =
  ## デコーダーが追加の出力データを持っているか確認
  return not BrotliDecoderIsFinishedProc(state).bool 