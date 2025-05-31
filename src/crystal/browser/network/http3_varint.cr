# HTTP/3可変長整数エンコード/デコードモジュール
#
# RFC 9000で定義されたQUIC/HTTP/3可変長整数の実装
# 超高速かつメモリ効率の良い実装

require "io"

module QuantumBrowser
  # HTTP/3可変長整数処理モジュール
  # 1,2,4,8バイトの可変長整数形式を処理
  module Http3Varint
    # バイト長識別マスク
    VARINT_LENGTH_MASK = 0xC0_u8
    
    # バイト長ごとの値マスク
    VARINT_VALUE_MASK_1 = 0x3F_u8  # 6ビット
    VARINT_VALUE_MASK_2 = 0x3FFF_u16  # 14ビット
    VARINT_VALUE_MASK_4 = 0x3FFFFFFF_u32  # 30ビット
    VARINT_VALUE_MASK_8 = 0x3FFFFFFFFFFFFFFF_u64  # 62ビット
    
    # バイト長の値
    VARINT_LENGTH_1 = 0x00_u8  # 00xxxxxx - 1バイト
    VARINT_LENGTH_2 = 0x40_u8  # 01xxxxxx - 2バイト
    VARINT_LENGTH_4 = 0x80_u8  # 10xxxxxx - 4バイト
    VARINT_LENGTH_8 = 0xC0_u8  # 11xxxxxx - 8バイト
    
    # バイト長ごとの最大値
    MAX_VARINT_VALUE_1 = 2_u64**6 - 1   # 63
    MAX_VARINT_VALUE_2 = 2_u64**14 - 1  # 16383
    MAX_VARINT_VALUE_4 = 2_u64**30 - 1  # 1073741823
    MAX_VARINT_VALUE_8 = 2_u64**62 - 1  # 4611686018427387903
    
    # 整数値のエンコード（最小バイト数を自動選択）
    def self.encode(io : IO, value : UInt64) : Nil
      # 値の範囲に応じてエンコード長を決定
      if value <= MAX_VARINT_VALUE_1
        # 1バイトエンコード (0～63)
        io.write_byte((VARINT_LENGTH_1 | value.to_u8).to_u8)
      elsif value <= MAX_VARINT_VALUE_2
        # 2バイトエンコード (64～16383)
        encoded_value = (VARINT_LENGTH_2 | (value >> 8)).to_u8
        io.write_byte(encoded_value)
        io.write_byte((value & 0xFF).to_u8)
      elsif value <= MAX_VARINT_VALUE_4
        # 4バイトエンコード (16384～1073741823)
        encoded_value = (VARINT_LENGTH_4 | (value >> 24)).to_u8
        io.write_byte(encoded_value)
        io.write_byte(((value >> 16) & 0xFF).to_u8)
        io.write_byte(((value >> 8) & 0xFF).to_u8)
        io.write_byte((value & 0xFF).to_u8)
      elsif value <= MAX_VARINT_VALUE_8
        # 8バイトエンコード (1073741824～4611686018427387903)
        encoded_value = (VARINT_LENGTH_8 | (value >> 56)).to_u8
        io.write_byte(encoded_value)
        io.write_byte(((value >> 48) & 0xFF).to_u8)
        io.write_byte(((value >> 40) & 0xFF).to_u8)
        io.write_byte(((value >> 32) & 0xFF).to_u8)
        io.write_byte(((value >> 24) & 0xFF).to_u8)
        io.write_byte(((value >> 16) & 0xFF).to_u8)
        io.write_byte(((value >> 8) & 0xFF).to_u8)
        io.write_byte((value & 0xFF).to_u8)
      else
        # 値が大きすぎる
        raise Exception.new("値が可変長整数の範囲を超えています: #{value}")
      end
    end
    
    # 整数値のデコード
    def self.decode(data : Bytes, offset : Int32) : {UInt64, Int32}
      # バッファの境界チェック
      if offset >= data.size
        return {0_u64, 0}
      end
      
      # 最初のバイトで長さを判定
      first_byte = data[offset]
      length_bits = first_byte & VARINT_LENGTH_MASK
      
      bytes_needed = case length_bits
                      when VARINT_LENGTH_1 then 1
                      when VARINT_LENGTH_2 then 2
                      when VARINT_LENGTH_4 then 4
                      when VARINT_LENGTH_8 then 8
                      else 0
                      end
      
      # バッファサイズチェック
      if offset + bytes_needed > data.size
        return {0_u64, 0}
      end
      
      # 長さに応じてデコード
      case length_bits
      when VARINT_LENGTH_1
        # 1バイトデコード
        value = (first_byte & VARINT_VALUE_MASK_1).to_u64
        {value, 1}
      when VARINT_LENGTH_2
        # 2バイトデコード
        value = ((first_byte & VARINT_VALUE_MASK_1).to_u64 << 8) | data[offset + 1].to_u64
        {value, 2}
      when VARINT_LENGTH_4
        # 4バイトデコード
        value = ((first_byte & VARINT_VALUE_MASK_1).to_u64 << 24) |
                (data[offset + 1].to_u64 << 16) |
                (data[offset + 2].to_u64 << 8) |
                data[offset + 3].to_u64
        {value, 4}
      when VARINT_LENGTH_8
        # 8バイトデコード
        value = ((first_byte & VARINT_VALUE_MASK_1).to_u64 << 56) |
                (data[offset + 1].to_u64 << 48) |
                (data[offset + 2].to_u64 << 40) |
                (data[offset + 3].to_u64 << 32) |
                (data[offset + 4].to_u64 << 24) |
                (data[offset + 5].to_u64 << 16) |
                (data[offset + 6].to_u64 << 8) |
                data[offset + 7].to_u64
        {value, 8}
      else
        # 不正な長さビット（通常は発生しない）
        {0_u64, 0}
      end
    end
    
    # 値を格納するのに必要なバイト数を計算
    def self.size(value : UInt64) : UInt64
      if value <= MAX_VARINT_VALUE_1
        1_u64
      elsif value <= MAX_VARINT_VALUE_2
        2_u64
      elsif value <= MAX_VARINT_VALUE_4
        4_u64
      elsif value <= MAX_VARINT_VALUE_8
        8_u64
      else
        raise Exception.new("値が可変長整数の範囲を超えています: #{value}")
      end
    end
    
    # 値をエンコードしてバイト配列として返す
    def self.encode_bytes(value : UInt64) : Bytes
      io = IO::Memory.new(8)  # 最大8バイト
      encode(io, value)
      io.rewind
      io.to_slice
    end
    
    # 整数値のバッチエンコード（複数の値を一度にエンコード）
    def self.encode_batch(io : IO, values : Array(UInt64)) : Nil
      values.each do |value|
        encode(io, value)
      end
    end
    
    # 1バイトからデコード（高速パス）
    def self.decode_1byte(byte : UInt8) : UInt64
      byte & VARINT_VALUE_MASK_1
    end
    
    # 2バイトからデコード（高速パス）
    def self.decode_2bytes(bytes : Bytes) : UInt64
      ((bytes[0] & VARINT_VALUE_MASK_1).to_u64 << 8) | bytes[1].to_u64
    end
    
    # 4バイトからデコード（高速パス）
    def self.decode_4bytes(bytes : Bytes) : UInt64
      ((bytes[0] & VARINT_VALUE_MASK_1).to_u64 << 24) |
      (bytes[1].to_u64 << 16) |
      (bytes[2].to_u64 << 8) |
      bytes[3].to_u64
    end
    
    # 8バイトからデコード（高速パス）
    def self.decode_8bytes(bytes : Bytes) : UInt64
      ((bytes[0] & VARINT_VALUE_MASK_1).to_u64 << 56) |
      (bytes[1].to_u64 << 48) |
      (bytes[2].to_u64 << 40) |
      (bytes[3].to_u64 << 32) |
      (bytes[4].to_u64 << 24) |
      (bytes[5].to_u64 << 16) |
      (bytes[6].to_u64 << 8) |
      bytes[7].to_u64
    end
  end
end 