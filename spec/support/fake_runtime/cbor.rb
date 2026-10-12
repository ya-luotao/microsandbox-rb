# frozen_string_literal: true

# Minimal CBOR codec — just enough for the microsandbox agent protocol
# (uint / negint / bytes / text / array / map / bool / nil). No floats/tags.
module MiniCbor
  # Marks a value to be encoded as a CBOR byte string (a plain String is text).
  Bytes = Struct.new(:data)

  module_function

  def head(major, n)
    m = major << 5
    if n < 24
      [m | n].pack("C")
    elsif n < 0x100
      [m | 24, n].pack("CC")
    elsif n < 0x10000
      [m | 25, n].pack("Cn")
    elsif n < 0x1_0000_0000
      [m | 26, n].pack("CN")
    else
      [m | 27, n].pack("CQ>")
    end
  end

  def encode(v)
    case v
    when Integer then (v >= 0) ? head(0, v) : head(1, -1 - v)
    when Bytes then head(2, v.data.bytesize) + v.data.b
    when String
      text = v.encode("UTF-8").b
      head(3, text.bytesize) + text
    when Symbol then encode(v.to_s)
    when Array then head(4, v.size) + v.map { |e| encode(e) }.join
    when Hash then head(5, v.size) + v.map { |k, e| encode(k.to_s) + encode(e) }.join
    when true then "\xF5".b
    when false then "\xF4".b
    when nil then "\xF6".b
    else raise ArgumentError, "MiniCbor: cannot encode #{v.class}"
    end
  end

  # The argument that follows an initial byte: returns [n, next_offset].
  def argument(s, i, info)
    case info
    when 0..23 then [info, i]
    when 24 then [s.getbyte(i), i + 1]
    when 25 then [s.byteslice(i, 2).unpack1("n"), i + 2]
    when 26 then [s.byteslice(i, 4).unpack1("N"), i + 4]
    when 27 then [s.byteslice(i, 8).unpack1("Q>"), i + 8]
    else raise ArgumentError, "MiniCbor: unsupported additional info #{info}"
    end
  end

  # Returns [value, next_offset]. Byte strings come back as Bytes.
  def decode_at(s, i = 0)
    b = s.getbyte(i)
    major = b >> 5
    info = b & 0x1f
    n, i = argument(s, i + 1, info)
    case major
    when 0 then [n, i]
    when 1 then [-1 - n, i]
    when 2 then [Bytes.new(s.byteslice(i, n)), i + n]
    when 3 then [s.byteslice(i, n).force_encoding("UTF-8"), i + n]
    when 4
      arr = []
      n.times do
        v, i = decode_at(s, i)
        arr << v
      end
      [arr, i]
    when 5
      h = {}
      n.times do
        k, i = decode_at(s, i)
        v, i = decode_at(s, i)
        h[k] = v
      end
      [h, i]
    when 7
      case info
      when 20 then [false, i]
      when 21 then [true, i]
      when 22, 23 then [nil, i]
      else raise ArgumentError, "MiniCbor: unsupported simple #{info}"
      end
    else raise ArgumentError, "MiniCbor: unsupported major #{major}"
    end
  end

  def decode(s) = decode_at(s.b, 0).first
end
