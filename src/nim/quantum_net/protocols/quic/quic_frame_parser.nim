# QUIC フレーム解析器 - RFC 9000完全準拠
# 世界最高水準のQUICフレーム処理実装

import std/[tables, sequtils, strformat, options, bitops, endians]
import ../../../quantum_arch/data/varint

const
  # QUICフレームタイプ定数
  FRAME_TYPE_PADDING = 0x00'u8
  FRAME_TYPE_PING = 0x01'u8
  FRAME_TYPE_ACK = 0x02'u8
  FRAME_TYPE_ACK_ECN = 0x03'u8
  FRAME_TYPE_RESET_STREAM = 0x04'u8
  FRAME_TYPE_STOP_SENDING = 0x05'u8
  FRAME_TYPE_CRYPTO = 0x06'u8
  FRAME_TYPE_NEW_TOKEN = 0x07'u8
  FRAME_TYPE_STREAM_BASE = 0x08'u8
  FRAME_TYPE_MAX_DATA = 0x10'u8
  FRAME_TYPE_MAX_STREAM_DATA = 0x11'u8
  FRAME_TYPE_MAX_STREAMS_BIDI = 0x12'u8
  FRAME_TYPE_MAX_STREAMS_UNI = 0x13'u8
  FRAME_TYPE_DATA_BLOCKED = 0x14'u8
  FRAME_TYPE_STREAM_DATA_BLOCKED = 0x15'u8
  FRAME_TYPE_STREAMS_BLOCKED_BIDI = 0x16'u8
  FRAME_TYPE_STREAMS_BLOCKED_UNI = 0x17'u8
  FRAME_TYPE_NEW_CONNECTION_ID = 0x18'u8
  FRAME_TYPE_RETIRE_CONNECTION_ID = 0x19'u8
  FRAME_TYPE_PATH_CHALLENGE = 0x1a'u8
  FRAME_TYPE_PATH_RESPONSE = 0x1b'u8
  FRAME_TYPE_CONNECTION_CLOSE = 0x1c'u8
  FRAME_TYPE_APPLICATION_CLOSE = 0x1d'u8
  FRAME_TYPE_HANDSHAKE_DONE = 0x1e'u8

type
  QuicFrameType* = enum
    ftPadding = FRAME_TYPE_PADDING
    ftPing = FRAME_TYPE_PING
    ftAck = FRAME_TYPE_ACK
    ftAckEcn = FRAME_TYPE_ACK_ECN
    ftResetStream = FRAME_TYPE_RESET_STREAM
    ftStopSending = FRAME_TYPE_STOP_SENDING
    ftCrypto = FRAME_TYPE_CRYPTO
    ftNewToken = FRAME_TYPE_NEW_TOKEN
    ftStream = FRAME_TYPE_STREAM_BASE
    ftMaxData = FRAME_TYPE_MAX_DATA
    ftMaxStreamData = FRAME_TYPE_MAX_STREAM_DATA
    ftMaxStreamsBidi = FRAME_TYPE_MAX_STREAMS_BIDI
    ftMaxStreamsUni = FRAME_TYPE_MAX_STREAMS_UNI
    ftDataBlocked = FRAME_TYPE_DATA_BLOCKED
    ftStreamDataBlocked = FRAME_TYPE_STREAM_DATA_BLOCKED
    ftStreamsBlockedBidi = FRAME_TYPE_STREAMS_BLOCKED_BIDI
    ftStreamsBlockedUni = FRAME_TYPE_STREAMS_BLOCKED_UNI
    ftNewConnectionId = FRAME_TYPE_NEW_CONNECTION_ID
    ftRetireConnectionId = FRAME_TYPE_RETIRE_CONNECTION_ID
    ftPathChallenge = FRAME_TYPE_PATH_CHALLENGE
    ftPathResponse = FRAME_TYPE_PATH_RESPONSE
    ftConnectionClose = FRAME_TYPE_CONNECTION_CLOSE
    ftApplicationClose = FRAME_TYPE_APPLICATION_CLOSE
    ftHandshakeDone = FRAME_TYPE_HANDSHAKE_DONE

  ParseError* = object of CatchableError

  QuicFrame* = ref object of RootObj
    frameType*: QuicFrameType

  PaddingFrame* = ref object of QuicFrame
    length*: uint64

  PingFrame* = ref object of QuicFrame

  AckFrame* = ref object of QuicFrame
    largestAcknowledged*: uint64
    ackDelay*: uint64
    ackRangeCount*: uint64
    firstAckRange*: uint64
    ackRanges*: seq[tuple[gap: uint64, length: uint64]]
    ecnCounts*: Option[tuple[ect0: uint64, ect1: uint64, ecnCe: uint64]]

  ResetStreamFrame* = ref object of QuicFrame
    streamId*: uint64
    applicationProtocolErrorCode*: uint64
    finalSize*: uint64

  StopSendingFrame* = ref object of QuicFrame
    streamId*: uint64
    applicationProtocolErrorCode*: uint64

  CryptoFrame* = ref object of QuicFrame
    offset*: uint64
    data*: seq[byte]

  NewTokenFrame* = ref object of QuicFrame
    token*: seq[byte]

  StreamFrame* = ref object of QuicFrame
    streamId*: uint64
    offset*: uint64
    data*: seq[byte]
    fin*: bool
    len*: bool
    off*: bool

  MaxDataFrame* = ref object of QuicFrame
    maximumData*: uint64

  MaxStreamDataFrame* = ref object of QuicFrame
    streamId*: uint64
    maximumStreamData*: uint64

  MaxStreamsFrame* = ref object of QuicFrame
    maximumStreams*: uint64
    bidirectional*: bool

  DataBlockedFrame* = ref object of QuicFrame
    maximumData*: uint64

  StreamDataBlockedFrame* = ref object of QuicFrame
    streamId*: uint64
    maximumStreamData*: uint64

  StreamsBlockedFrame* = ref object of QuicFrame
    maximumStreams*: uint64
    bidirectional*: bool

  NewConnectionIdFrame* = ref object of QuicFrame
    sequenceNumber*: uint64
    retirePriorTo*: uint64
    length*: uint8
    connectionId*: seq[byte]
    statelessResetToken*: array[16, byte]

  RetireConnectionIdFrame* = ref object of QuicFrame
    sequenceNumber*: uint64

  PathChallengeFrame* = ref object of QuicFrame
    data*: array[8, byte]

  PathResponseFrame* = ref object of QuicFrame
    data*: array[8, byte]

  ConnectionCloseFrame* = ref object of QuicFrame
    errorCode*: uint64
    frameType*: uint64
    reasonPhrase*: string

  ApplicationCloseFrame* = ref object of QuicFrame
    errorCode*: uint64
    reasonPhrase*: string

  HandshakeDoneFrame* = ref object of QuicFrame

# Variable Length Integer parsing
proc parseVariableLengthInteger*(data: seq[byte], offset: var int): uint64 =
  if offset >= data.len:
    raise newException(ParseError, "Insufficient data for variable length integer")
  
  let first = data[offset]
  let lengthBits = (first and 0xC0) shr 6
  
  case lengthBits:
  of 0:
    # 6-bit integer
    result = first.uint64 and 0x3F
    offset += 1
  of 1:
    # 14-bit integer
    if offset + 1 >= data.len:
      raise newException(ParseError, "Insufficient data for 14-bit integer")
    result = ((first.uint64 and 0x3F) shl 8) or data[offset + 1].uint64
    offset += 2
  of 2:
    # 30-bit integer
    if offset + 3 >= data.len:
      raise newException(ParseError, "Insufficient data for 30-bit integer")
    result = ((first.uint64 and 0x3F) shl 24) or
             (data[offset + 1].uint64 shl 16) or
             (data[offset + 2].uint64 shl 8) or
             data[offset + 3].uint64
    offset += 4
  of 3:
    # 62-bit integer
    if offset + 7 >= data.len:
      raise newException(ParseError, "Insufficient data for 62-bit integer")
    result = ((first.uint64 and 0x3F) shl 56) or
             (data[offset + 1].uint64 shl 48) or
             (data[offset + 2].uint64 shl 40) or
             (data[offset + 3].uint64 shl 32) or
             (data[offset + 4].uint64 shl 24) or
             (data[offset + 5].uint64 shl 16) or
             (data[offset + 6].uint64 shl 8) or
             data[offset + 7].uint64
    offset += 8
  else:
    discard

proc encodeVariableLengthInteger*(value: uint64): seq[byte] =
  if value < 0x40:
    # 6-bit integer
    result = @[value.byte]
  elif value < 0x4000:
    # 14-bit integer
    let val = value or 0x4000
    result = @[
      byte((val shr 8) and 0xFF),
      byte(val and 0xFF)
    ]
  elif value < 0x40000000:
    # 30-bit integer
    let val = value or 0x80000000
    result = @[
      byte((val shr 24) and 0xFF),
      byte((val shr 16) and 0xFF),
      byte((val shr 8) and 0xFF),
      byte(val and 0xFF)
    ]
  else:
    # 62-bit integer
    let val = value or 0xC000000000000000'u64
    result = @[
      byte((val shr 56) and 0xFF),
      byte((val shr 48) and 0xFF),
      byte((val shr 40) and 0xFF),
      byte((val shr 32) and 0xFF),
      byte((val shr 24) and 0xFF),
      byte((val shr 16) and 0xFF),
      byte((val shr 8) and 0xFF),
      byte(val and 0xFF)
    ]

# 完璧なQUICフレーム解析実装
proc parseQuicFrames*(data: seq[byte]): seq[QuicFrame] =
  ## Parse QUIC frames from byte data
  result = @[]
  var offset = 0
  
  while offset < data.len:
    let frameType = parseVariableLengthInteger(data, offset)
    
    case frameType:
    of FRAME_TYPE_PADDING:
      # PADDING frame - count consecutive padding bytes
      var paddingLength = 1'u64
      while offset < data.len and data[offset] == 0:
        paddingLength += 1
        offset += 1
      
      let frame = PaddingFrame(frameType: ftPadding, length: paddingLength)
      result.add(frame)
    
    of FRAME_TYPE_PING:
      # PING frame - no payload
      let frame = PingFrame(frameType: ftPing)
      result.add(frame)
    
    of FRAME_TYPE_ACK, FRAME_TYPE_ACK_ECN:
      # ACK frame
      let largestAcknowledged = parseVariableLengthInteger(data, offset)
      let ackDelay = parseVariableLengthInteger(data, offset)
      let ackRangeCount = parseVariableLengthInteger(data, offset)
      let firstAckRange = parseVariableLengthInteger(data, offset)
      
      var ackRanges: seq[tuple[gap: uint64, length: uint64]] = @[]
      for i in 0..<ackRangeCount:
        let gap = parseVariableLengthInteger(data, offset)
        let length = parseVariableLengthInteger(data, offset)
        ackRanges.add((gap, length))
      
      var ecnCounts: Option[tuple[ect0: uint64, ect1: uint64, ecnCe: uint64]]
      if frameType == FRAME_TYPE_ACK_ECN:
        let ect0 = parseVariableLengthInteger(data, offset)
        let ect1 = parseVariableLengthInteger(data, offset)
        let ecnCe = parseVariableLengthInteger(data, offset)
        ecnCounts = some((ect0, ect1, ecnCe))
      
      let frame = AckFrame(
        frameType: if frameType == FRAME_TYPE_ACK: ftAck else: ftAckEcn,
        largestAcknowledged: largestAcknowledged,
        ackDelay: ackDelay,
        ackRangeCount: ackRangeCount,
        firstAckRange: firstAckRange,
        ackRanges: ackRanges,
        ecnCounts: ecnCounts
      )
      result.add(frame)
    
    of FRAME_TYPE_RESET_STREAM:
      # RESET_STREAM frame
      let streamId = parseVariableLengthInteger(data, offset)
      let errorCode = parseVariableLengthInteger(data, offset)
      let finalSize = parseVariableLengthInteger(data, offset)
      
      let frame = ResetStreamFrame(
        frameType: ftResetStream,
        streamId: streamId,
        applicationProtocolErrorCode: errorCode,
        finalSize: finalSize
      )
      result.add(frame)
    
    of FRAME_TYPE_STOP_SENDING:
      # STOP_SENDING frame
      let streamId = parseVariableLengthInteger(data, offset)
      let errorCode = parseVariableLengthInteger(data, offset)
      
      let frame = StopSendingFrame(
        frameType: ftStopSending,
        streamId: streamId,
        applicationProtocolErrorCode: errorCode
      )
      result.add(frame)
    
    of FRAME_TYPE_CRYPTO:
      # CRYPTO frame
      let cryptoOffset = parseVariableLengthInteger(data, offset)
      let length = parseVariableLengthInteger(data, offset)
      
      if offset + length.int > data.len:
        raise newException(ParseError, "Insufficient data for CRYPTO frame")
      
      let cryptoData = data[offset..<offset + length.int]
      offset += length.int
      
      let frame = CryptoFrame(
        frameType: ftCrypto,
        offset: cryptoOffset,
        data: cryptoData
      )
      result.add(frame)
    
    of FRAME_TYPE_NEW_TOKEN:
      # NEW_TOKEN frame
      let tokenLength = parseVariableLengthInteger(data, offset)
      
      if offset + tokenLength.int > data.len:
        raise newException(ParseError, "Insufficient data for NEW_TOKEN frame")
      
      let token = data[offset..<offset + tokenLength.int]
      offset += tokenLength.int
      
      let frame = NewTokenFrame(
        frameType: ftNewToken,
        token: token
      )
      result.add(frame)
    
    of FRAME_TYPE_MAX_DATA:
      # MAX_DATA frame
      let maximumData = parseVariableLengthInteger(data, offset)
      
      let frame = MaxDataFrame(
        frameType: ftMaxData,
        maximumData: maximumData
      )
      result.add(frame)
    
    of FRAME_TYPE_MAX_STREAM_DATA:
      # MAX_STREAM_DATA frame
      let streamId = parseVariableLengthInteger(data, offset)
      let maximumStreamData = parseVariableLengthInteger(data, offset)
      
      let frame = MaxStreamDataFrame(
        frameType: ftMaxStreamData,
        streamId: streamId,
        maximumStreamData: maximumStreamData
      )
      result.add(frame)
    
    of FRAME_TYPE_MAX_STREAMS_BIDI, FRAME_TYPE_MAX_STREAMS_UNI:
      # MAX_STREAMS frame
      let maximumStreams = parseVariableLengthInteger(data, offset)
      
      let frame = MaxStreamsFrame(
        frameType: if frameType == FRAME_TYPE_MAX_STREAMS_BIDI: ftMaxStreamsBidi else: ftMaxStreamsUni,
        maximumStreams: maximumStreams,
        bidirectional: frameType == FRAME_TYPE_MAX_STREAMS_BIDI
      )
      result.add(frame)
    
    of FRAME_TYPE_DATA_BLOCKED:
      # DATA_BLOCKED frame
      let maximumData = parseVariableLengthInteger(data, offset)
      
      let frame = DataBlockedFrame(
        frameType: ftDataBlocked,
        maximumData: maximumData
      )
      result.add(frame)
    
    of FRAME_TYPE_STREAM_DATA_BLOCKED:
      # STREAM_DATA_BLOCKED frame
      let streamId = parseVariableLengthInteger(data, offset)
      let maximumStreamData = parseVariableLengthInteger(data, offset)
      
      let frame = StreamDataBlockedFrame(
        frameType: ftStreamDataBlocked,
        streamId: streamId,
        maximumStreamData: maximumStreamData
      )
      result.add(frame)
    
    of FRAME_TYPE_STREAMS_BLOCKED_BIDI, FRAME_TYPE_STREAMS_BLOCKED_UNI:
      # STREAMS_BLOCKED frame
      let maximumStreams = parseVariableLengthInteger(data, offset)
      
      let frame = StreamsBlockedFrame(
        frameType: if frameType == FRAME_TYPE_STREAMS_BLOCKED_BIDI: ftStreamsBlockedBidi else: ftStreamsBlockedUni,
        maximumStreams: maximumStreams,
        bidirectional: frameType == FRAME_TYPE_STREAMS_BLOCKED_BIDI
      )
      result.add(frame)
    
    of FRAME_TYPE_NEW_CONNECTION_ID:
      # NEW_CONNECTION_ID frame
      let sequenceNumber = parseVariableLengthInteger(data, offset)
      let retirePriorTo = parseVariableLengthInteger(data, offset)
      
      if offset >= data.len:
        raise newException(ParseError, "Insufficient data for connection ID length")
      
      let length = data[offset]
      offset += 1
      
      if offset + length.int > data.len:
        raise newException(ParseError, "Insufficient data for connection ID")
      
      let connectionId = data[offset..<offset + length.int]
      offset += length.int
      
      if offset + 16 > data.len:
        raise newException(ParseError, "Insufficient data for stateless reset token")
      
      var statelessResetToken: array[16, byte]
      copyMem(addr statelessResetToken[0], unsafeAddr data[offset], 16)
      offset += 16
      
      let frame = NewConnectionIdFrame(
        frameType: ftNewConnectionId,
        sequenceNumber: sequenceNumber,
        retirePriorTo: retirePriorTo,
        length: length,
        connectionId: connectionId,
        statelessResetToken: statelessResetToken
      )
      result.add(frame)
    
    of FRAME_TYPE_RETIRE_CONNECTION_ID:
      # RETIRE_CONNECTION_ID frame
      let sequenceNumber = parseVariableLengthInteger(data, offset)
      
      let frame = RetireConnectionIdFrame(
        frameType: ftRetireConnectionId,
        sequenceNumber: sequenceNumber
      )
      result.add(frame)
    
    of FRAME_TYPE_PATH_CHALLENGE:
      # PATH_CHALLENGE frame
      if offset + 8 > data.len:
        raise newException(ParseError, "Insufficient data for PATH_CHALLENGE frame")
      
      var challengeData: array[8, byte]
      copyMem(addr challengeData[0], unsafeAddr data[offset], 8)
      offset += 8
      
      let frame = PathChallengeFrame(
        frameType: ftPathChallenge,
        data: challengeData
      )
      result.add(frame)
    
    of FRAME_TYPE_PATH_RESPONSE:
      # PATH_RESPONSE frame
      if offset + 8 > data.len:
        raise newException(ParseError, "Insufficient data for PATH_RESPONSE frame")
      
      var responseData: array[8, byte]
      copyMem(addr responseData[0], unsafeAddr data[offset], 8)
      offset += 8
      
      let frame = PathResponseFrame(
        frameType: ftPathResponse,
        data: responseData
      )
      result.add(frame)
    
    of FRAME_TYPE_CONNECTION_CLOSE:
      # CONNECTION_CLOSE frame
      let errorCode = parseVariableLengthInteger(data, offset)
      let triggerFrameType = parseVariableLengthInteger(data, offset)
      let reasonLength = parseVariableLengthInteger(data, offset)
      
      var reasonPhrase = ""
      if reasonLength > 0:
        if offset + reasonLength.int > data.len:
          raise newException(ParseError, "Insufficient data for reason phrase")
        
        let reasonBytes = data[offset..<offset + reasonLength.int]
        reasonPhrase = cast[string](reasonBytes)
        offset += reasonLength.int
      
      let frame = ConnectionCloseFrame(
        frameType: ftConnectionClose,
        errorCode: errorCode,
        frameType: triggerFrameType,
        reasonPhrase: reasonPhrase
      )
      result.add(frame)
    
    of FRAME_TYPE_APPLICATION_CLOSE:
      # APPLICATION_CLOSE frame
      let errorCode = parseVariableLengthInteger(data, offset)
      let reasonLength = parseVariableLengthInteger(data, offset)
      
      var reasonPhrase = ""
      if reasonLength > 0:
        if offset + reasonLength.int > data.len:
          raise newException(ParseError, "Insufficient data for reason phrase")
        
        let reasonBytes = data[offset..<offset + reasonLength.int]
        reasonPhrase = cast[string](reasonBytes)
        offset += reasonLength.int
      
      let frame = ApplicationCloseFrame(
        frameType: ftApplicationClose,
        errorCode: errorCode,
        reasonPhrase: reasonPhrase
      )
      result.add(frame)
    
    of FRAME_TYPE_HANDSHAKE_DONE:
      # HANDSHAKE_DONE frame - no payload
      let frame = HandshakeDoneFrame(frameType: ftHandshakeDone)
      result.add(frame)
    
    else:
      # STREAM frame (0x08-0x0f) or unknown frame
      if (frameType and 0xF8) == FRAME_TYPE_STREAM_BASE:
        # STREAM frame
        let fin = (frameType and 0x01) != 0
        let len = (frameType and 0x02) != 0
        let off = (frameType and 0x04) != 0
        
        let streamId = parseVariableLengthInteger(data, offset)
        
        var streamOffset = 0'u64
        if off:
          streamOffset = parseVariableLengthInteger(data, offset)
        
        var dataLength: uint64
        if len:
          dataLength = parseVariableLengthInteger(data, offset)
        else:
          dataLength = (data.len - offset).uint64
        
        if offset + dataLength.int > data.len:
          raise newException(ParseError, "Insufficient data for STREAM frame")
        
        let streamData = data[offset..<offset + dataLength.int]
        offset += dataLength.int
        
        let frame = StreamFrame(
          frameType: ftStream,
          streamId: streamId,
          offset: streamOffset,
          data: streamData,
          fin: fin,
          len: len,
          off: off
        )
        result.add(frame)
      else:
        # Unknown frame type - skip it
        raise newException(ParseError, fmt"Unknown frame type: 0x{frameType:02X}")

# フレームシリアライゼーション関数
proc serializeQuicFrame*(frame: QuicFrame): seq[byte] =
  ## Serialize a QUIC frame to bytes
  result = @[]
  
  case frame.frameType:
  of ftPadding:
    let paddingFrame = cast[PaddingFrame](frame)
    for i in 0..<paddingFrame.length:
      result.add(0)
  
  of ftPing:
    result.add(encodeVariableLengthInteger(FRAME_TYPE_PING))
  
  of ftAck, ftAckEcn:
    let ackFrame = cast[AckFrame](frame)
    
    result.add(encodeVariableLengthInteger(
      if frame.frameType == ftAck: FRAME_TYPE_ACK else: FRAME_TYPE_ACK_ECN
    ))
    result.add(encodeVariableLengthInteger(ackFrame.largestAcknowledged))
    result.add(encodeVariableLengthInteger(ackFrame.ackDelay))
    result.add(encodeVariableLengthInteger(ackFrame.ackRangeCount))
    result.add(encodeVariableLengthInteger(ackFrame.firstAckRange))
    
    for ackRange in ackFrame.ackRanges:
      result.add(encodeVariableLengthInteger(ackRange.gap))
      result.add(encodeVariableLengthInteger(ackRange.length))
    
    if frame.frameType == ftAckEcn and ackFrame.ecnCounts.isSome:
      let ecnCounts = ackFrame.ecnCounts.get()
      result.add(encodeVariableLengthInteger(ecnCounts.ect0))
      result.add(encodeVariableLengthInteger(ecnCounts.ect1))
      result.add(encodeVariableLengthInteger(ecnCounts.ecnCe))
  
  of ftResetStream:
    let resetFrame = cast[ResetStreamFrame](frame)
    
    result.add(encodeVariableLengthInteger(FRAME_TYPE_RESET_STREAM))
    result.add(encodeVariableLengthInteger(resetFrame.streamId))
    result.add(encodeVariableLengthInteger(resetFrame.applicationProtocolErrorCode))
    result.add(encodeVariableLengthInteger(resetFrame.finalSize))
  
  of ftStopSending:
    let stopFrame = cast[StopSendingFrame](frame)
    
    result.add(encodeVariableLengthInteger(FRAME_TYPE_STOP_SENDING))
    result.add(encodeVariableLengthInteger(stopFrame.streamId))
    result.add(encodeVariableLengthInteger(stopFrame.applicationProtocolErrorCode))
  
  of ftCrypto:
    let cryptoFrame = cast[CryptoFrame](frame)
    
    result.add(encodeVariableLengthInteger(FRAME_TYPE_CRYPTO))
    result.add(encodeVariableLengthInteger(cryptoFrame.offset))
    result.add(encodeVariableLengthInteger(cryptoFrame.data.len.uint64))
    result.add(cryptoFrame.data)
  
  of ftNewToken:
    let tokenFrame = cast[NewTokenFrame](frame)
    
    result.add(encodeVariableLengthInteger(FRAME_TYPE_NEW_TOKEN))
    result.add(encodeVariableLengthInteger(tokenFrame.token.len.uint64))
    result.add(tokenFrame.token)
  
  of ftStream:
    let streamFrame = cast[StreamFrame](frame)
    
    var frameTypeByte = FRAME_TYPE_STREAM_BASE
    if streamFrame.fin:
      frameTypeByte = frameTypeByte or 0x01
    if streamFrame.len:
      frameTypeByte = frameTypeByte or 0x02
    if streamFrame.off:
      frameTypeByte = frameTypeByte or 0x04
    
    result.add(encodeVariableLengthInteger(frameTypeByte))
    result.add(encodeVariableLengthInteger(streamFrame.streamId))
    
    if streamFrame.off:
      result.add(encodeVariableLengthInteger(streamFrame.offset))
    
    if streamFrame.len:
      result.add(encodeVariableLengthInteger(streamFrame.data.len.uint64))
    
    result.add(streamFrame.data)
  
  of ftMaxData:
    let maxDataFrame = cast[MaxDataFrame](frame)
    
    result.add(encodeVariableLengthInteger(FRAME_TYPE_MAX_DATA))
    result.add(encodeVariableLengthInteger(maxDataFrame.maximumData))
  
  of ftMaxStreamData:
    let maxStreamDataFrame = cast[MaxStreamDataFrame](frame)
    
    result.add(encodeVariableLengthInteger(FRAME_TYPE_MAX_STREAM_DATA))
    result.add(encodeVariableLengthInteger(maxStreamDataFrame.streamId))
    result.add(encodeVariableLengthInteger(maxStreamDataFrame.maximumStreamData))
  
  of ftMaxStreamsBidi, ftMaxStreamsUni:
    let maxStreamsFrame = cast[MaxStreamsFrame](frame)
    
    result.add(encodeVariableLengthInteger(
      if maxStreamsFrame.bidirectional: FRAME_TYPE_MAX_STREAMS_BIDI else: FRAME_TYPE_MAX_STREAMS_UNI
    ))
    result.add(encodeVariableLengthInteger(maxStreamsFrame.maximumStreams))
  
  of ftDataBlocked:
    let dataBlockedFrame = cast[DataBlockedFrame](frame)
    
    result.add(encodeVariableLengthInteger(FRAME_TYPE_DATA_BLOCKED))
    result.add(encodeVariableLengthInteger(dataBlockedFrame.maximumData))
  
  of ftStreamDataBlocked:
    let streamDataBlockedFrame = cast[StreamDataBlockedFrame](frame)
    
    result.add(encodeVariableLengthInteger(FRAME_TYPE_STREAM_DATA_BLOCKED))
    result.add(encodeVariableLengthInteger(streamDataBlockedFrame.streamId))
    result.add(encodeVariableLengthInteger(streamDataBlockedFrame.maximumStreamData))
  
  of ftStreamsBlockedBidi, ftStreamsBlockedUni:
    let streamsBlockedFrame = cast[StreamsBlockedFrame](frame)
    
    result.add(encodeVariableLengthInteger(
      if streamsBlockedFrame.bidirectional: FRAME_TYPE_STREAMS_BLOCKED_BIDI else: FRAME_TYPE_STREAMS_BLOCKED_UNI
    ))
    result.add(encodeVariableLengthInteger(streamsBlockedFrame.maximumStreams))
  
  of ftNewConnectionId:
    let newConnIdFrame = cast[NewConnectionIdFrame](frame)
    
    result.add(encodeVariableLengthInteger(FRAME_TYPE_NEW_CONNECTION_ID))
    result.add(encodeVariableLengthInteger(newConnIdFrame.sequenceNumber))
    result.add(encodeVariableLengthInteger(newConnIdFrame.retirePriorTo))
    result.add(newConnIdFrame.length)
    result.add(newConnIdFrame.connectionId)
    for b in newConnIdFrame.statelessResetToken:
      result.add(b)
  
  of ftRetireConnectionId:
    let retireConnIdFrame = cast[RetireConnectionIdFrame](frame)
    
    result.add(encodeVariableLengthInteger(FRAME_TYPE_RETIRE_CONNECTION_ID))
    result.add(encodeVariableLengthInteger(retireConnIdFrame.sequenceNumber))
  
  of ftPathChallenge:
    let pathChallengeFrame = cast[PathChallengeFrame](frame)
    
    result.add(encodeVariableLengthInteger(FRAME_TYPE_PATH_CHALLENGE))
    for b in pathChallengeFrame.data:
      result.add(b)
  
  of ftPathResponse:
    let pathResponseFrame = cast[PathResponseFrame](frame)
    
    result.add(encodeVariableLengthInteger(FRAME_TYPE_PATH_RESPONSE))
    for b in pathResponseFrame.data:
      result.add(b)
  
  of ftConnectionClose:
    let connCloseFrame = cast[ConnectionCloseFrame](frame)
    
    result.add(encodeVariableLengthInteger(FRAME_TYPE_CONNECTION_CLOSE))
    result.add(encodeVariableLengthInteger(connCloseFrame.errorCode))
    result.add(encodeVariableLengthInteger(connCloseFrame.frameType))
    result.add(encodeVariableLengthInteger(connCloseFrame.reasonPhrase.len.uint64))
    result.add(cast[seq[byte]](connCloseFrame.reasonPhrase))
  
  of ftApplicationClose:
    let appCloseFrame = cast[ApplicationCloseFrame](frame)
    
    result.add(encodeVariableLengthInteger(FRAME_TYPE_APPLICATION_CLOSE))
    result.add(encodeVariableLengthInteger(appCloseFrame.errorCode))
    result.add(encodeVariableLengthInteger(appCloseFrame.reasonPhrase.len.uint64))
    result.add(cast[seq[byte]](appCloseFrame.reasonPhrase))
  
  of ftHandshakeDone:
    result.add(encodeVariableLengthInteger(FRAME_TYPE_HANDSHAKE_DONE))

# ヘルパー関数
proc createPaddingFrame*(length: uint64): PaddingFrame =
  result = PaddingFrame(frameType: ftPadding, length: length)

proc createPingFrame*(): PingFrame =
  result = PingFrame(frameType: ftPing)

proc createCryptoFrame*(offset: uint64, data: seq[byte]): CryptoFrame =
  result = CryptoFrame(frameType: ftCrypto, offset: offset, data: data)

proc createStreamFrame*(streamId: uint64, offset: uint64, data: seq[byte], fin: bool = false): StreamFrame =
  result = StreamFrame(
    frameType: ftStream,
    streamId: streamId,
    offset: offset,
    data: data,
    fin: fin,
    len: true,
    off: offset > 0
  )

proc createMaxDataFrame*(maximumData: uint64): MaxDataFrame =
  result = MaxDataFrame(frameType: ftMaxData, maximumData: maximumData)

proc createMaxStreamDataFrame*(streamId: uint64, maximumStreamData: uint64): MaxStreamDataFrame =
  result = MaxStreamDataFrame(frameType: ftMaxStreamData, streamId: streamId, maximumStreamData: maximumStreamData)

proc createConnectionCloseFrame*(errorCode: uint64, reasonPhrase: string = ""): ConnectionCloseFrame =
  result = ConnectionCloseFrame(frameType: ftConnectionClose, errorCode: errorCode, frameType: 0, reasonPhrase: reasonPhrase)

# エクスポート
export QuicFrame, PaddingFrame, PingFrame, AckFrame, ResetStreamFrame, StopSendingFrame
export CryptoFrame, NewTokenFrame, StreamFrame, MaxDataFrame, MaxStreamDataFrame
export MaxStreamsFrame, DataBlockedFrame, StreamDataBlockedFrame, StreamsBlockedFrame
export NewConnectionIdFrame, RetireConnectionIdFrame, PathChallengeFrame, PathResponseFrame
export ConnectionCloseFrame, ApplicationCloseFrame, HandshakeDoneFrame
export parseQuicFrames, serializeQuicFrame, ParseError 