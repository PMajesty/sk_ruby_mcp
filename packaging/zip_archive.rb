# frozen_string_literal: true

# Минимальный ZIP без гемов: RBZ - это ZIP с другим расширением.

require 'zlib'

module Packaging
  class ZipArchive
    LOCAL_SIG = 0x04034b50
    CENTRAL_SIG = 0x02014b50
    EOCD_SIG = 0x06054b50
    VERSION = 20
    UTF8_FLAG = 0x0800
    METHOD_STORE = 0
    METHOD_DEFLATE = 8

    Entry = Struct.new(:name, :data)

    def initialize
      @entries = []
    end

    def add(name, data)
      normalized = normalize_name(name)
      raise ArgumentError, "duplicate zip entry #{normalized}" if @entries.any? { |entry| entry.name == normalized }

      @entries << Entry.new(normalized, data.to_s.b)
      self
    end

    def names
      @entries.map(&:name)
    end

    def write(path)
      File.binwrite(path, dump)
      path
    end

    def dump
      local = +''.b
      central = +''.b
      @entries.each do |entry|
        crc = Zlib.crc32(entry.data)
        compressed, method = compress(entry.data)
        time, date = dos_datetime(Time.now)
        name = entry.name.encode('UTF-8').b
        local_offset = local.bytesize
        local << [
          LOCAL_SIG, VERSION, UTF8_FLAG, method, time, date,
          crc, compressed.bytesize, entry.data.bytesize, name.bytesize, 0
        ].pack('VvvvvvVVVvv')
        local << name
        local << compressed
        central << [
          CENTRAL_SIG, VERSION, VERSION, UTF8_FLAG, method, time, date,
          crc, compressed.bytesize, entry.data.bytesize, name.bytesize,
          0, 0, 0, 0, 0, local_offset
        ].pack('VvvvvvvVVVvvvvvVV')
        central << name
      end
      eocd = [
        EOCD_SIG, 0, 0, @entries.length, @entries.length,
        central.bytesize, local.bytesize, 0
      ].pack('VvvvvVVv')
      local + central + eocd
    end

    def self.read(path)
      parse(File.binread(path))
    end

    def self.parse(bytes)
      blob = bytes.to_s.b
      offset = 0
      entries = []
      while offset + 4 <= blob.bytesize
        signature = blob[offset, 4].unpack1('V')
        break if signature == CENTRAL_SIG || signature == EOCD_SIG
        raise ArgumentError, 'not a zip archive' unless signature == LOCAL_SIG
        raise ArgumentError, 'truncated zip local header' if offset + 30 > blob.bytesize

        _ver, flags, method, _time, _date, crc, compressed_size, size, name_len, extra_len =
          blob[offset + 4, 26].unpack('vvvvvVVVvv')
        raise ArgumentError, 'zip data descriptors are not supported' if (flags & 0x0008).nonzero?

        name_at = offset + 30
        data_at = name_at + name_len + extra_len
        raise ArgumentError, 'truncated zip entry' if data_at + compressed_size > blob.bytesize

        name = blob[name_at, name_len].force_encoding('UTF-8')
        payload = blob[data_at, compressed_size]
        data = inflate(payload, method)
        raise ArgumentError, "zip crc mismatch for #{name}" if Zlib.crc32(data) != crc
        raise ArgumentError, "zip size mismatch for #{name}" if data.bytesize != size

        entries << Entry.new(name, data)
        offset = data_at + compressed_size
      end
      raise ArgumentError, 'zip archive has no entries' if entries.empty?

      entries
    end

    def self.inflate(payload, method)
      case method
      when METHOD_STORE
        payload
      when METHOD_DEFLATE
        inflater = Zlib::Inflate.new(-Zlib::MAX_WBITS)
        inflater.inflate(payload)
      else
        raise ArgumentError, "unsupported zip method #{method}"
      end
    ensure
      inflater.close if inflater
    end

    private

    def normalize_name(name)
      text = name.to_s.tr('\\', '/')
      raise ArgumentError, 'zip entry name is empty' if text.empty?
      raise ArgumentError, 'zip entry name must be relative' if text.start_with?('/') || text.match?(/\A[A-Za-z]:/)
      raise ArgumentError, 'zip entry name must not contain ..' if text.split('/').include?('..')

      text.sub(%r{\A\./}, '')
    end

    def compress(data)
      return [data, METHOD_STORE] if data.empty?

      deflater = Zlib::Deflate.new(Zlib::DEFAULT_COMPRESSION, -Zlib::MAX_WBITS)
      compressed = deflater.deflate(data, Zlib::FINISH)
      compressed.bytesize < data.bytesize ? [compressed, METHOD_DEFLATE] : [data, METHOD_STORE]
    ensure
      deflater.close if deflater
    end

    def dos_datetime(time)
      year = time.year - 1980
      year = 0 if year.negative?
      time_bits = (time.hour << 11) | (time.min << 5) | (time.sec / 2)
      date_bits = (year << 9) | (time.month << 5) | time.day
      [time_bits, date_bits]
    end
  end
end
