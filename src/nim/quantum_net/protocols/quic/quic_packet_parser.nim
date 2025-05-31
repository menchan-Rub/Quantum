# QUIC パケット解析器 - RFC 9000完全準拠
# 世界最高水準のQUICパケット解析実装

import std/[options, tables, sequtils, strformat, bitops, endians]
import quic_frame_parser
import quic_packet_protection
import ../../../quantum_arch/data/varint

const
  QUIC_VERSION_1 = 0x00000001'u32
  QUIC_VERSION_DRAFT_29 = 0xff00001d'u32
  MINIMUM_PACKET_SIZE = 20
  MAXIMUM_PACKET_SIZE = 65535

type
  QuicPacketType* = enum
    ptInitial = 0x00
    ptZeroRTT = 0x01  
    ptHandshake = 0x02
    ptRetry = 0x03
    ptVersionNegotiation = 0x04
    ptShort = 0x05

  QuicPacketHeader* = object
    packetType*: QuicPacketType
    version*: uint32
    destConnId*: seq[byte]
    srcConnId*: seq[byte]
    token*: seq[byte]
    packetNumber*: uint64
    packetNumberLength*: int
    payload*: seq[byte]
    isLongHeader*: bool

  QuicPacket* = object
    header*: QuicPacketHeader
    frames*: seq[QuicFrame]
    originalBytes*: seq[byte]

  PacketParseError* = object of CatchableError

# パケットタイプの判定
proc getPacketType*(firstByte: byte): QuicPacketType =
  if (firstByte and 0x80) == 0:
    # Short header packet
    return ptShort
  else:
    # Long header packet
    let packetType = (firstByte and 0x30) shr 4
    case packetType:
    of 0x00:
      return ptInitial
    of 0x01:
      return ptZeroRTT
    of 0x02:
      return ptHandshake
    of 0x03:
      return ptRetry
    else:
      raise newException(PacketParseError, fmt"Invalid packet type: {packetType}")

# バージョンの検証
proc isValidVersion*(version: uint32): bool =
  case version:
  of QUIC_VERSION_1, QUIC_VERSION_DRAFT_29:
    return true
  of 0x00000000'u32:
    return true  # Version negotiation
  else:
    # Reserved versions (0x?a?a?a?a)
    return (version and 0x0F0F0F0F) == 0x0A0A0A0A

# 接続IDの長さを取得
proc getConnectionIdLength*(lengthByte: byte): int =
  if lengthByte == 0:
    return 0
  else:
    return lengthByte.int

# Variable Length Integerの解析
proc parseVarInt(data: seq[byte], offset: var int): uint64 =
  if offset >= data.len:
    raise newException(PacketParseError, "Insufficient data for variable integer")
  
  let first = data[offset]
  let lengthField = (first and 0xC0) shr 6
  
  case lengthField:
  of 0:
    # 6-bit integer
    result = (first and 0x3F).uint64
    offset += 1
  of 1:
    # 14-bit integer
    if offset + 1 >= data.len:
      raise newException(PacketParseError, "Insufficient data for 14-bit integer")
    result = ((first and 0x3F).uint64 shl 8) or data[offset + 1].uint64
    offset += 2
  of 2:
    # 30-bit integer
    if offset + 3 >= data.len:
      raise newException(PacketParseError, "Insufficient data for 30-bit integer")
    result = ((first and 0x3F).uint64 shl 24) or
             (data[offset + 1].uint64 shl 16) or
             (data[offset + 2].uint64 shl 8) or
             data[offset + 3].uint64
    offset += 4
  of 3:
    # 62-bit integer
    if offset + 7 >= data.len:
      raise newException(PacketParseError, "Insufficient data for 62-bit integer")
    result = ((first and 0x3F).uint64 shl 56) or
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

# Long Header パケットの解析
proc parseLongHeaderPacket*(data: seq[byte]): QuicPacketHeader =
  if data.len < 5:
    raise newException(PacketParseError, "Packet too short for long header")
  
  var offset = 0
  let firstByte = data[offset]
  offset += 1
  
  # Header form bit must be 1
  if (firstByte and 0x80) == 0:
    raise newException(PacketParseError, "Not a long header packet")
  
  # Fixed bit must be 1
  if (firstByte and 0x40) == 0:
    raise newException(PacketParseError, "Fixed bit not set")
  
  result.isLongHeader = true
  result.packetType = getPacketType(firstByte)
  
  # Version (4 bytes)
  if offset + 4 > data.len:
    raise newException(PacketParseError, "Insufficient data for version")
  
  result.version = (data[offset].uint32 shl 24) or
                   (data[offset + 1].uint32 shl 16) or
                   (data[offset + 2].uint32 shl 8) or
                   data[offset + 3].uint32
  offset += 4
  
  # Version negotiation packet
  if result.version == 0:
    result.packetType = ptVersionNegotiation
    # Rest of packet is list of supported versions
    result.payload = data[offset..^1]
    return
  
  if not isValidVersion(result.version):
    raise newException(PacketParseError, fmt"Invalid version: 0x{result.version:08X}")
  
  # Destination Connection ID Length
  if offset >= data.len:
    raise newException(PacketParseError, "Missing destination connection ID length")
  
  let destConnIdLen = getConnectionIdLength(data[offset])
  offset += 1
  
  # Destination Connection ID
  if offset + destConnIdLen > data.len:
    raise newException(PacketParseError, "Insufficient data for destination connection ID")
  
  result.destConnId = data[offset..<offset + destConnIdLen]
  offset += destConnIdLen
  
  # Source Connection ID Length
  if offset >= data.len:
    raise newException(PacketParseError, "Missing source connection ID length")
  
  let srcConnIdLen = getConnectionIdLength(data[offset])
  offset += 1
  
  # Source Connection ID
  if offset + srcConnIdLen > data.len:
    raise newException(PacketParseError, "Insufficient data for source connection ID")
  
  result.srcConnId = data[offset..<offset + srcConnIdLen]
  offset += srcConnIdLen
  
  case result.packetType:
  of ptInitial:
    # Token Length and Token
    let tokenLen = parseVarInt(data, offset)
    
    if offset + tokenLen.int > data.len:
      raise newException(PacketParseError, "Insufficient data for token")
    
    result.token = data[offset..<offset + tokenLen.int]
    offset += tokenLen.int
    
    # Length
    let length = parseVarInt(data, offset)
    
    if offset + length.int > data.len:
      raise newException(PacketParseError, "Insufficient data for payload")
    
    # Packet Number Length (from first byte)
    result.packetNumberLength = ((firstByte and 0x03) + 1).int
    
    if offset + result.packetNumberLength > data.len:
      raise newException(PacketParseError, "Insufficient data for packet number")
    
    # Packet Number (variable length)
    result.packetNumber = 0
    for i in 0..<result.packetNumberLength:
      result.packetNumber = (result.packetNumber shl 8) or data[offset + i].uint64
    offset += result.packetNumberLength
    
    # Payload
    let payloadLen = length.int - result.packetNumberLength
    if offset + payloadLen > data.len:
      raise newException(PacketParseError, "Insufficient data for payload")
    
    result.payload = data[offset..<offset + payloadLen]
  
  of ptZeroRTT, ptHandshake:
    # Length
    let length = parseVarInt(data, offset)
    
    if offset + length.int > data.len:
      raise newException(PacketParseError, "Insufficient data for payload")
    
    # Packet Number Length (from first byte)
    result.packetNumberLength = ((firstByte and 0x03) + 1).int
    
    if offset + result.packetNumberLength > data.len:
      raise newException(PacketParseError, "Insufficient data for packet number")
    
    # Packet Number
    result.packetNumber = 0
    for i in 0..<result.packetNumberLength:
      result.packetNumber = (result.packetNumber shl 8) or data[offset + i].uint64
    offset += result.packetNumberLength
    
    # Payload
    let payloadLen = length.int - result.packetNumberLength
    if offset + payloadLen > data.len:
      raise newException(PacketParseError, "Insufficient data for payload")
    
    result.payload = data[offset..<offset + payloadLen]
  
  of ptRetry:
    # Retry Integrity Tag (16 bytes)
    if data.len < offset + 16:
      raise newException(PacketParseError, "Insufficient data for Retry Integrity Tag")
    
    # Retry Token (everything between connection IDs and Integrity Tag)
    result.token = data[offset..<data.len - 16]
    result.payload = data[data.len - 16..^1]  # Integrity Tag
  
  else:
    raise newException(PacketParseError, fmt"Unsupported packet type: {result.packetType}")

# Short Header パケットの解析
proc parseShortHeaderPacket*(data: seq[byte], connIdLen: int): QuicPacketHeader =
  if data.len < 1 + connIdLen + 1:
    raise newException(PacketParseError, "Packet too short for short header")
  
  var offset = 0
  let firstByte = data[offset]
  offset += 1
  
  # Header form bit must be 0
  if (firstByte and 0x80) != 0:
    raise newException(PacketParseError, "Not a short header packet")
  
  # Fixed bit must be 1
  if (firstByte and 0x40) == 0:
    raise newException(PacketParseError, "Fixed bit not set")
  
  result.isLongHeader = false
  result.packetType = ptShort
  
  # Destination Connection ID
  if offset + connIdLen > data.len:
    raise newException(PacketParseError, "Insufficient data for destination connection ID")
  
  result.destConnId = data[offset..<offset + connIdLen]
  offset += connIdLen
  
  # Packet Number Length (from first byte)
  result.packetNumberLength = ((firstByte and 0x03) + 1).int
  
  if offset + result.packetNumberLength > data.len:
    raise newException(PacketParseError, "Insufficient data for packet number")
  
  # Packet Number
  result.packetNumber = 0
  for i in 0..<result.packetNumberLength:
    result.packetNumber = (result.packetNumber shl 8) or data[offset + i].uint64
  offset += result.packetNumberLength
  
  # Payload (rest of packet)
  result.payload = data[offset..^1]

# 完全なQUICパケット解析
proc parseQuicPacket*(data: seq[byte], destConnIdLen: int = 8): QuicPacket =
  ## Parse a complete QUIC packet from raw bytes
  
  if data.len < MINIMUM_PACKET_SIZE:
    raise newException(PacketParseError, fmt"Packet too short: {data.len} bytes")
  
  if data.len > MAXIMUM_PACKET_SIZE:
    raise newException(PacketParseError, fmt"Packet too large: {data.len} bytes")
  
  result.originalBytes = data
  
  # Determine packet type from first byte
  let firstByte = data[0]
  let isLongHeader = (firstByte and 0x80) != 0
  
  if isLongHeader:
    result.header = parseLongHeaderPacket(data)
  else:
    result.header = parseShortHeaderPacket(data, destConnIdLen)
  
  # Parse frames from payload (if decrypted)
  if result.header.payload.len > 0:
    try:
      result.frames = parseQuicFrames(result.header.payload)
    except ParseError:
      # Payload might be encrypted, frames cannot be parsed
      result.frames = @[]

# パケット番号の復号化
proc decodePacketNumber*(encoded: uint64, largestAcked: uint64, packetNumberLength: int): uint64 =
  ## Decode packet number using largest acknowledged packet number
  
  let packetNumberWindow = 1'u64 shl (packetNumberLength * 8)
  let halfWindow = packetNumberWindow div 2
  
  # Expected packet number is largest_acked + 1
  let expected = largestAcked + 1
  
  # Truncated packet number combined with bits from expected
  let candidate = (expected and (not (packetNumberWindow - 1))) or encoded
  
  # Adjust based on distance from expected
  if candidate <= expected - halfWindow and candidate < (1'u64 shl 62) - packetNumberWindow:
    result = candidate + packetNumberWindow
  elif candidate > expected + halfWindow and candidate >= packetNumberWindow:
    result = candidate - packetNumberWindow
  else:
    result = candidate

# パケット番号のエンコード
proc encodePacketNumber*(packetNumber: uint64, largestAcked: uint64): tuple[encoded: uint64, length: int] =
  ## Encode packet number using minimal bytes
  
  let numUnacked = packetNumber - largestAcked
  
  if numUnacked < 0x80:
    result = (packetNumber and 0xFF, 1)
  elif numUnacked < 0x8000:
    result = (packetNumber and 0xFFFF, 2)
  elif numUnacked < 0x800000:
    result = (packetNumber and 0xFFFFFF, 3)
  else:
    result = (packetNumber and 0xFFFFFFFF, 4)

# パケットの暗号化状態チェック
proc isPacketEncrypted*(packet: QuicPacket): bool =
  ## Check if packet payload is encrypted (cannot parse frames)
  return packet.frames.len == 0 and packet.header.payload.len > 0

# パケットサイズの検証
proc validatePacketSize*(packet: QuicPacket): bool =
  ## Validate packet size constraints
  
  # Initial packets must be at least 1200 bytes
  if packet.header.packetType == ptInitial:
    return packet.originalBytes.len >= 1200
  
  # All packets must be at least 20 bytes
  return packet.originalBytes.len >= MINIMUM_PACKET_SIZE

# パケットヘッダーのシリアライゼーション
proc serializePacketHeader*(header: QuicPacketHeader): seq[byte] =
  ## Serialize packet header to bytes
  result = @[]
  
  if header.isLongHeader:
    # Long header packet
    var firstByte = 0x80'u8  # Header form = 1
    firstByte = firstByte or 0x40  # Fixed bit = 1
    
    # Packet type
    case header.packetType:
    of ptInitial:
      firstByte = firstByte or (0x00 shl 4)
    of ptZeroRTT:
      firstByte = firstByte or (0x01 shl 4)
    of ptHandshake:
      firstByte = firstByte or (0x02 shl 4)
    of ptRetry:
      firstByte = firstByte or (0x03 shl 4)
    else:
      discard
    
    # Packet number length (for non-retry packets)
    if header.packetType != ptRetry:
      firstByte = firstByte or ((header.packetNumberLength - 1).uint8 and 0x03)
    
    result.add(firstByte)
    
    # Version (4 bytes)
    result.add(byte((header.version shr 24) and 0xFF))
    result.add(byte((header.version shr 16) and 0xFF))
    result.add(byte((header.version shr 8) and 0xFF))
    result.add(byte(header.version and 0xFF))
    
    # Destination Connection ID Length
    result.add(header.destConnId.len.uint8)
    
    # Destination Connection ID
    result.add(header.destConnId)
    
    # Source Connection ID Length
    result.add(header.srcConnId.len.uint8)
    
    # Source Connection ID
    result.add(header.srcConnId)
    
    case header.packetType:
    of ptInitial:
      # Token Length
      result.add(encodeVariableLengthInteger(header.token.len.uint64))
      
      # Token
      result.add(header.token)
      
      # Length (will be filled later)
      result.add(encodeVariableLengthInteger((header.packetNumberLength + header.payload.len).uint64))
      
      # Packet Number
      for i in countdown(header.packetNumberLength - 1, 0):
        result.add(byte((header.packetNumber shr (i * 8)) and 0xFF))
    
    of ptZeroRTT, ptHandshake:
      # Length
      result.add(encodeVariableLengthInteger((header.packetNumberLength + header.payload.len).uint64))
      
      # Packet Number
      for i in countdown(header.packetNumberLength - 1, 0):
        result.add(byte((header.packetNumber shr (i * 8)) and 0xFF))
    
    of ptRetry:
      # Token (retry token)
      result.add(header.token)
    
    else:
      discard
  
  else:
    # Short header packet
    var firstByte = 0x40'u8  # Fixed bit = 1, Header form = 0
    
    # Packet number length
    firstByte = firstByte or ((header.packetNumberLength - 1).uint8 and 0x03)
    
    result.add(firstByte)
    
    # Destination Connection ID
    result.add(header.destConnId)
    
    # Packet Number
    for i in countdown(header.packetNumberLength - 1, 0):
      result.add(byte((header.packetNumber shr (i * 8)) and 0xFF))

# 完全なパケットのシリアライゼーション
proc serializeQuicPacket*(packet: QuicPacket): seq[byte] =
  ## Serialize complete QUIC packet to bytes
  
  result = serializePacketHeader(packet.header)
  
  # Add payload (encrypted frames or raw data)
  if packet.header.payload.len > 0:
    result.add(packet.header.payload)
  elif packet.frames.len > 0:
    # Serialize frames
    for frame in packet.frames:
      result.add(serializeQuicFrame(frame))

# ヘルパー関数
proc createInitialPacket*(destConnId: seq[byte], srcConnId: seq[byte], packetNumber: uint64, payload: seq[byte], token: seq[byte] = @[]): QuicPacket =
  ## Create an Initial packet
  
  result.header = QuicPacketHeader(
    packetType: ptInitial,
    version: QUIC_VERSION_1,
    destConnId: destConnId,
    srcConnId: srcConnId,
    token: token,
    packetNumber: packetNumber,
    packetNumberLength: 4,
    payload: payload,
    isLongHeader: true
  )
  
  result.originalBytes = serializeQuicPacket(result)

proc createHandshakePacket*(destConnId: seq[byte], srcConnId: seq[byte], packetNumber: uint64, payload: seq[byte]): QuicPacket =
  ## Create a Handshake packet
  
  result.header = QuicPacketHeader(
    packetType: ptHandshake,
    version: QUIC_VERSION_1,
    destConnId: destConnId,
    srcConnId: srcConnId,
    packetNumber: packetNumber,
    packetNumberLength: 4,
    payload: payload,
    isLongHeader: true
  )
  
  result.originalBytes = serializeQuicPacket(result)

proc createShortHeaderPacket*(destConnId: seq[byte], packetNumber: uint64, payload: seq[byte]): QuicPacket =
  ## Create a Short Header (1-RTT) packet
  
  result.header = QuicPacketHeader(
    packetType: ptShort,
    destConnId: destConnId,
    packetNumber: packetNumber,
    packetNumberLength: 4,
    payload: payload,
    isLongHeader: false
  )
  
  result.originalBytes = serializeQuicPacket(result)

# デバッグ用の関数
proc `$`*(header: QuicPacketHeader): string =
  result = fmt"QuicPacketHeader(type: {header.packetType}, version: 0x{header.version:08X}, "
  result.add(fmt"destConnId: {header.destConnId.len} bytes, srcConnId: {header.srcConnId.len} bytes, ")
  result.add(fmt"packetNumber: {header.packetNumber}, payloadLen: {header.payload.len})")

proc `$`*(packet: QuicPacket): string =
  result = fmt"QuicPacket(header: {packet.header}, frames: {packet.frames.len}, "
  result.add(fmt"originalSize: {packet.originalBytes.len} bytes)")

# エクスポート
export QuicPacketType, QuicPacketHeader, QuicPacket, PacketParseError
export parseQuicPacket, serializeQuicPacket, decodePacketNumber, encodePacketNumber
export createInitialPacket, createHandshakePacket, createShortHeaderPacket
export isPacketEncrypted, validatePacketSize 