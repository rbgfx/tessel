# frozen_string_literal: true

require "zlib"

require_relative "tessel/version"

module Tessel
  SIGNATURE = "\x89PNG\r\n\x1a\n".b.freeze

  class Error < StandardError; end
  class DecodeError < ArgumentError
    attr_reader :offset, :chunk

    def initialize(message, offset: nil, chunk: nil)
      @offset = offset
      @chunk = chunk
      super(message)
    end
  end
  class UnsupportedError < ArgumentError; end
  class LimitError < ArgumentError; end

  module Color
    module_function

    def pack(value)
      bytes = case value
      when String
        if value.bytesize == 4 && !value.start_with?("#")
          value.bytes
        else
        hex = value.delete_prefix("#")
        raise ArgumentError, "color must be #rrggbb or #rrggbbaa" unless [6, 8].include?(hex.length) && hex.match?(/\A[0-9a-fA-F]+\z/)

        hex.scan(/../).map { |part| part.to_i(16) }
        end
      when Array
        raise TypeError, "color must contain 3 or 4 channels" unless [3, 4].include?(value.length)
        raise TypeError, "color channels must be integers" unless value.all? { |channel| channel.is_a?(Integer) }
        raise ArgumentError, "color channels must be between 0 and 255" unless value.all? { |channel| (0..255).cover?(channel) }

        value
      else
        if value.respond_to?(:to_bytes)
          Array(value.to_bytes)
        else
          raise TypeError, "unsupported color: #{value.class}"
        end
      end
      bytes = bytes.dup
      bytes << 255 if bytes.length == 3
      raise TypeError, "color must contain 3 or 4 channels" unless bytes.length == 4
      raise ArgumentError, "color channels must be between 0 and 255" unless bytes.all? { |channel| channel.is_a?(Integer) && (0..255).cover?(channel) }

      bytes.pack("C*").b.freeze
    end
  end

  class Image
    attr_reader :width, :height, :metadata

    def initialize(width, height, fill: [0, 0, 0, 0], metadata: {})
      @width = Integer(width)
      @height = Integer(height)
      raise ArgumentError, "width and height must be non-negative" if @width.negative? || @height.negative?

      @data = Color.pack(fill) * (@width * @height)
      @metadata = metadata.transform_keys(&:to_s).transform_values(&:to_s)
    end

    def self.from_rgba(width, height, bytes, metadata: {})
      width = Integer(width)
      height = Integer(height)
      raise ArgumentError, "width and height must be non-negative" if width.negative? || height.negative?
      bytes = String(bytes).b
      expected = width * height * 4
      raise ArgumentError, "RGBA byte length must be #{expected}" unless bytes.bytesize == expected

      image = allocate
      image.instance_variable_set(:@width, width)
      image.instance_variable_set(:@height, height)
      image.instance_variable_set(:@data, bytes.dup)
      image.instance_variable_set(:@metadata, metadata.transform_keys(&:to_s).transform_values(&:to_s))
      image
    end

    def bytes
      @data.dup.freeze
    end

    alias to_rgba_bytes bytes

    def [](x, y)
      x = Integer(x)
      y = Integer(y)
      return nil unless x.between?(0, @width - 1) && y.between?(0, @height - 1)

      @data.byteslice((y * @width + x) * 4, 4).unpack("C4")
    end

    def []=(x, y, color)
      raise FrozenError, "can't modify frozen image" if frozen?

      x = Integer(x)
      y = Integer(y)
      return color unless x.between?(0, @width - 1) && y.between?(0, @height - 1)

      @data[((y * @width + x) * 4), 4] = Color.pack(color)
      color
    end

    def clear(color)
      raise FrozenError, "can't modify frozen image" if frozen?

      @data = Color.pack(color) * (@width * @height)
      self
    end

    def hspan(x0, x1, y, color, blend: :copy)
      fill_rect(x0, y, Integer(x1) - Integer(x0) + 1, 1, color, blend: blend)
    end

    def fill_rect(x, y, width, height, color, blend: :copy)
      raise FrozenError, "can't modify frozen image" if frozen?
      raise ArgumentError, "unknown blend: #{blend}" unless %i[copy alpha].include?(blend)

      x, y, width, height = Integer(x), Integer(y), Integer(width), Integer(height)
      x0 = [x, 0].max
      y0 = [y, 0].max
      x1 = [x + width, @width].min
      y1 = [y + height, @height].min
      return self if x0 >= x1 || y0 >= y1

      packed = Color.pack(color)
      if blend == :copy || packed.getbyte(3) == 255
        row = packed * (x1 - x0)
        (y0...y1).each { |row_y| @data[((row_y * @width + x0) * 4), row.bytesize] = row }
      elsif packed.getbyte(3).positive?
        (y0...y1).each { |row_y| (x0...x1).each { |pixel_x| blend_pixel(pixel_x, row_y, packed) } }
      end
      self
    end

    def blit(source, dx, dy, sx: 0, sy: 0, w: nil, h: nil, blend: :alpha)
      raise FrozenError, "can't modify frozen image" if frozen?
      raise TypeError, "source must be a Tessel::Image" unless source.is_a?(Image)
      raise ArgumentError, "unknown blend: #{blend}" unless %i[copy alpha].include?(blend)

      source = source.dup if source.equal?(self)

      sx, sy, dx, dy = Integer(sx), Integer(sy), Integer(dx), Integer(dy)
      w = source.width - sx if w.nil?
      h = source.height - sy if h.nil?
      w, h = Integer(w), Integer(h)
      (0...h).each do |row|
        source_x = sx
        target_x = dx
        count = w
        source_y = sy + row
        target_y = dy + row
        next unless source_y.between?(0, source.height - 1) && target_y.between?(0, @height - 1)

        if target_x.negative?
          source_x -= target_x
          count += target_x
          target_x = 0
        end
        if source_x.negative?
          target_x -= source_x
          count += source_x
          source_x = 0
        end
        count = [count, @width - target_x, source.width - source_x].min
        next if count <= 0

        if blend == :copy
          @data[((target_y * @width + target_x) * 4), count * 4] = source.instance_variable_get(:@data).byteslice((source_y * source.width + source_x) * 4, count * 4)
        else
          (0...count).each do |offset|
            source_pixel = source.instance_variable_get(:@data).byteslice((source_y * source.width + source_x + offset) * 4, 4)
            blend_pixel(target_x + offset, target_y, source_pixel)
          end
        end
      end
      self
    end

    def blit_mask(mask, dx, dy, color)
      raise FrozenError, "can't modify frozen image" if frozen?
      raise TypeError, "mask must respond to width, height and bytes" unless mask.respond_to?(:width) && mask.respond_to?(:height) && mask.respond_to?(:bytes)

      packed = Color.pack(color)
      mask.bytes.bytes.each_with_index do |coverage, index|
        next if coverage.zero?

        x = Integer(dx) + index % mask.width
        y = Integer(dy) + index / mask.width
        next unless x.between?(0, @width - 1) && y.between?(0, @height - 1)

        source = packed.dup
        source.setbyte(3, packed.getbyte(3) * coverage / 255)
        blend_pixel(x, y, source)
      end
      self
    end

    def crop(x, y, width, height)
      result = Image.new(width, height)
      result.blit(self, 0, 0, sx: x, sy: y, w: width, h: height, blend: :copy)
      result
    end

    def flip_vertical
      result = Image.new(@width, @height, metadata: @metadata)
      (0...@height).each do |y|
        result.instance_variable_get(:@data)[y * @width * 4, @width * 4] = @data.byteslice((@height - y - 1) * @width * 4, @width * 4)
      end
      result
    end

    def scale_nearest(width, height)
      width, height = Integer(width), Integer(height)
      raise ArgumentError, "dimensions must be non-negative" if width.negative? || height.negative?

      result = Image.new(width, height, metadata: @metadata)
      return result if width.zero? || height.zero? || @width.zero? || @height.zero?

      (0...height).each do |y|
        source_y = y * @height / height
        (0...width).each do |x|
          source_x = x * @width / width
          result.instance_variable_get(:@data)[(y * width + x) * 4, 4] = @data.byteslice((source_y * @width + source_x) * 4, 4)
        end
      end
      result
    end

    def to_rgb_bytes
      @data.unpack("C*").each_slice(4).flat_map { |r, g, b, _a| [r, g, b] }.pack("C*").b
    end

    def write(path, **options)
      filename = path.respond_to?(:to_path) ? path.to_path : String(path)
      case File.extname(filename).downcase
      when ".png" then File.binwrite(filename, PNG.encode(self, **options))
      when ".ppm", ".pnm" then File.binwrite(filename, PPM.encode(self, **options))
      when ".bmp" then File.binwrite(filename, BMP.encode(self, **options))
      else raise UnsupportedError, "unknown image format: #{filename}"
      end
      filename
    end

    def initialize_copy(other)
      super
      @data = other.instance_variable_get(:@data).dup
      @metadata = other.metadata.dup
    end

    private

    def blend_pixel(x, y, source)
      source_alpha = source.getbyte(3)
      return if source_alpha.zero?
      offset = (y * @width + x) * 4
      if source_alpha == 255
        @data[offset, 4] = source
        return
      end

      destination_alpha = @data.getbyte(offset + 3)
      output_alpha = source_alpha + destination_alpha * (255 - source_alpha) / 255
      if output_alpha.zero?
        @data[offset, 4] = "\0\0\0\0".b
        return
      end
      3.times do |channel|
        value = (source.getbyte(channel) * source_alpha + @data.getbyte(offset + channel) * destination_alpha * (255 - source_alpha) / 255) / output_alpha
        @data.setbyte(offset + channel, value)
      end
      @data.setbyte(offset + 3, output_alpha)
    end
  end

  module_function

  def decode(bytes, **options)
    bytes = String(bytes).b
    return PNG.decode(bytes, **options) if bytes.start_with?(SIGNATURE)
    return PPM.decode(bytes, **options) if bytes.start_with?("P3", "P6")
    return BMP.decode(bytes, **options) if bytes.start_with?("BM")

    raise UnsupportedError, "unknown image format"
  end

  def read(path, **options)
    decode(File.binread(path), **options)
  end
end

require_relative "tessel/quantize"

module Tessel
  module PNG
    module Chunk
      module_function

      def write(io, type, data)
        type = String(type).b
        data = String(data).b
        raise ArgumentError, "PNG chunk type must be four bytes" unless type.bytesize == 4

        io << [data.bytesize].pack("N") << type << data << [Zlib.crc32(type + data)].pack("N")
      end
    end

    module Filters
      module_function

      def unfilter(type, row, previous, bpp)
        bytes = row.bytes
        prior = previous ? previous.bytes : Array.new(bytes.length, 0)
        case type
        when 0 then bytes
        when 1 then bytes.each_index { |i| bytes[i] = (bytes[i] + (i >= bpp ? bytes[i - bpp] : 0)) & 255 }
        when 2 then bytes.each_index { |i| bytes[i] = (bytes[i] + prior[i]) & 255 }
        when 3 then bytes.each_index { |i| bytes[i] = (bytes[i] + (((i >= bpp ? bytes[i - bpp] : 0) + prior[i]) / 2)) & 255 }
        when 4 then bytes.each_index { |i| bytes[i] = (bytes[i] + paeth(i >= bpp ? bytes[i - bpp] : 0, prior[i], i >= bpp ? prior[i - bpp] : 0)) & 255 }
        else raise DecodeError, "unknown PNG filter: #{type}"
        end
        bytes.pack("C*").b
      end

      def filter(type, row, previous, bpp)
        bytes = row.bytes
        prior = previous ? previous.bytes : Array.new(bytes.length, 0)
        bytes.each_index.map do |i|
          left = i >= bpp ? bytes[i - bpp] : 0
          up = prior[i]
          upper_left = i >= bpp ? prior[i - bpp] : 0
          value = case type
          when 0 then bytes[i]
          when 1 then bytes[i] - left
          when 2 then bytes[i] - up
          when 3 then bytes[i] - ((left + up) / 2)
          when 4 then bytes[i] - paeth(left, up, upper_left)
          else raise ArgumentError, "unknown PNG filter: #{type}"
          end
          value & 255
        end.pack("C*").b
      end

      def paeth(a, b, c)
        p = a + b - c
        pa = (p - a).abs
        pb = (p - b).abs
        pc = (p - c).abs
        pa <= pb && pa <= pc ? a : (pb <= pc ? b : c)
      end
      private_class_method :paeth
    end

    module Encoder
      module_function

      def encode(image, color_type: :rgba, filter: :none, level: Zlib::DEFAULT_COMPRESSION, metadata: image.metadata)
        raise TypeError, "image must be a Tessel::Image" unless image.is_a?(Image)
        raise ArgumentError, "PNG dimensions must be positive" unless image.width.positive? && image.height.positive?
        type = { grayscale: 0, gray: 0, rgb: 2, palette: 3, gray_alpha: 4, rgba: 6 }.fetch(color_type.to_sym) { raise UnsupportedError, "unsupported PNG color type" }
        raise UnsupportedError, "palette PNG output needs an explicit palette" if type == 3

        raw = "".b
        previous = nil
        data = image.instance_variable_get(:@data)
        channels = { 0 => 1, 2 => 3, 4 => 2, 6 => 4 }.fetch(type)
        (0...image.height).each do |y|
          rgba = data.byteslice(y * image.width * 4, image.width * 4).bytes.each_slice(4)
          row = case type
          when 0 then rgba.map { |r, g, b, _a| (0.299 * r + 0.587 * g + 0.114 * b).round }.pack("C*")
          when 2 then rgba.flat_map { |r, g, b, _a| [r, g, b] }.pack("C*")
          when 4 then rgba.flat_map { |r, g, b, a| [(0.299 * r + 0.587 * g + 0.114 * b).round, a] }.pack("C*")
          else rgba.to_a.flatten.pack("C*")
          end
          selected = case filter.to_sym
          when :none then 0
          when :sub then 1
          when :up then 2
          when :average then 3
          when :paeth then 4
          when :adaptive
            (0..4).min_by { |kind| Filters.filter(kind, row, previous, channels).bytes.sum { |byte| byte < 128 ? byte : 256 - byte } }
          else raise ArgumentError, "unknown PNG filter: #{filter}"
          end
          raw << selected.chr << Filters.filter(selected, row, previous, channels)
          previous = row
        end

        output = SIGNATURE.dup
        Chunk.write(output, "IHDR", [image.width, image.height, 8, type, 0, 0, 0].pack("N2C5"))
        write_metadata(output, metadata)
        Chunk.write(output, "IDAT", Zlib::Deflate.deflate(raw, level))
        Chunk.write(output, "IEND", "")
        output
      end

      def write_metadata(output, metadata)
        metadata.each do |key, value|
          key = String(key)
          value = String(value)
          if key.bytesize.between?(1, 79) && key.ascii_only? && value.encode("ISO-8859-1")
            Chunk.write(output, "tEXt", key.b + "\0".b + value.encode("ISO-8859-1").b)
          else
            Chunk.write(output, "iTXt", key.encode("UTF-8").b + "\0\0\0\0\0".b + value.encode("UTF-8").b)
          end
        rescue EncodingError
          Chunk.write(output, "iTXt", key.encode("UTF-8").b + "\0\0\0\0\0".b + value.encode("UTF-8").b)
        end
      end
      private_class_method :write_metadata
    end

    module Decoder
      module_function

      ADAM7 = [[0, 0, 8, 8], [4, 0, 8, 8], [0, 4, 4, 8], [2, 0, 4, 4], [0, 2, 2, 4], [1, 0, 2, 2], [0, 1, 1, 2]].freeze

      def decode(bytes, max_pixels: 16384 * 16384, verify_crc: true)
        bytes = String(bytes).b
        raise DecodeError, "invalid PNG signature" unless bytes.start_with?(SIGNATURE)

        chunks = []
        offset = SIGNATURE.bytesize
        while offset < bytes.bytesize
          raise DecodeError.new("truncated PNG chunk", offset: offset) if offset + 12 > bytes.bytesize
          length = bytes.byteslice(offset, 4).unpack1("N")
          type = bytes.byteslice(offset + 4, 4)
          raise DecodeError.new("invalid PNG chunk length", offset: offset, chunk: type) if length > 0x7fff_ffff
          raise DecodeError.new("invalid PNG chunk type", offset: offset, chunk: type) unless type.match?(/\A[A-Za-z]{4}\z/)
          data_start = offset + 8
          data_end = data_start + length
          raise DecodeError.new("truncated PNG chunk", offset: offset, chunk: type) if data_end + 4 > bytes.bytesize
          data = bytes.byteslice(data_start, length)
          actual_crc = bytes.byteslice(data_end, 4).unpack1("N")
          if verify_crc && Zlib.crc32(type + data) != actual_crc
            raise DecodeError.new("PNG CRC mismatch", offset: offset, chunk: type)
          end
          chunks << [type, data]
          offset = data_end + 4
          break if type == "IEND"
        end
        raise DecodeError.new("trailing data after IEND", offset: offset) unless offset == bytes.bytesize
        raise DecodeError, "PNG is missing IEND" unless chunks.last&.first == "IEND"
        raise DecodeError, "IEND must be empty" unless chunks.last[1].empty?
        raise DecodeError, "PNG is missing IDAT" unless chunks.any? { |type, _| type == "IDAT" }
        raise DecodeError, "PNG must have one IHDR" unless chunks.count { |type, _| type == "IHDR" } == 1
        idat_index = chunks.index { |type, _| type == "IDAT" }
        %w[PLTE tRNS].each do |type|
          positions = chunks.each_index.select { |index| chunks[index][0] == type }
          raise DecodeError, "duplicate PNG #{type} chunk" if positions.length > 1
          raise DecodeError, "invalid PNG chunk order" if positions.first && positions.first > idat_index
        end
        plte_index = chunks.index { |type, _| type == "PLTE" }
        trns_index = chunks.index { |type, _| type == "tRNS" }
        raise DecodeError, "invalid PNG chunk order" if plte_index && trns_index && trns_index < plte_index
        raise UnsupportedError, "unknown critical PNG chunk" if chunks.any? { |type, _| type.getbyte(0) < 97 && !%w[IHDR PLTE IDAT IEND].include?(type) }
        idat_started = false
        idat_ended = false
        chunks.each do |type, _|
          if type == "IDAT"
            raise DecodeError, "PNG IDAT chunks must be consecutive" if idat_ended
            idat_started = true
          elsif idat_started && type != "IEND"
            idat_ended = true
          end
        end
        parse(chunks, max_pixels: max_pixels)
      rescue Zlib::Error => e
        raise DecodeError, "invalid PNG data: #{e.message}"
      end

      def parse(chunks, max_pixels:)
        raise DecodeError, "PNG is missing IHDR" unless chunks.first&.first == "IHDR"
        raise DecodeError, "invalid IHDR length" unless chunks.first[1].bytesize == 13
        width, height, bit_depth, color_type, compression, filter_method, interlace = chunks.first[1].unpack("N2C5")
        raise DecodeError, "invalid PNG dimensions" if width.zero? || height.zero?
        raise LimitError, "PNG dimensions exceed limit" if width > 16_384 || height > 16_384
        raise LimitError, "image exceeds pixel limit" if width * height > max_pixels
        raise DecodeError, "unsupported PNG compression or filter method" unless compression.zero? && filter_method.zero?
        valid_depths = { 0 => [1, 2, 4, 8, 16], 2 => [8, 16], 3 => [1, 2, 4, 8], 4 => [8, 16], 6 => [8, 16] }
        raise UnsupportedError, "unsupported PNG color type #{color_type}" unless valid_depths.key?(color_type)
        raise UnsupportedError, "unsupported PNG bit depth" unless valid_depths[color_type].include?(bit_depth)
        raise UnsupportedError, "unsupported PNG interlace method" unless [0, 1].include?(interlace)

        palette = chunks.find { |type, _| type == "PLTE" }&.last
        transparency = chunks.find { |type, _| type == "tRNS" }&.last
        raise DecodeError, "PNG palette is missing" if color_type == 3 && !palette
        raise DecodeError, "invalid PNG palette" if palette && (palette.empty? || palette.bytesize % 3 != 0 || palette.bytesize > 768)
        raise DecodeError, "PNG palette is not allowed" if palette && [0, 4].include?(color_type)
        raise DecodeError, "PNG palette exceeds bit depth" if palette && color_type == 3 && palette.bytesize / 3 > (1 << bit_depth)
        raise DecodeError, "invalid PNG transparency" if transparency && ((color_type == 3 && (!palette || transparency.bytesize > palette.bytesize / 3)) || (color_type == 0 && transparency.bytesize != 2) || (color_type == 2 && transparency.bytesize != 6) || [4, 6].include?(color_type))
        idat = chunks.select { |type, _| type == "IDAT" }.map(&:last).join
        raise DecodeError, "PNG is missing IDAT" if idat.empty?
        channels = { 0 => 1, 2 => 3, 3 => 1, 4 => 2, 6 => 4 }.fetch(color_type)
        bits_per_pixel = channels * bit_depth
        row_bytes = (width * bits_per_pixel + 7) / 8
        expected = if interlace.zero?
          (row_bytes + 1) * height
        else
          ADAM7.sum do |x_start, y_start, x_step, y_step|
            pass_width = pass_size(width, x_start, x_step)
            pass_height = pass_size(height, y_start, y_step)
            pass_row_bytes = (pass_width * bits_per_pixel + 7) / 8
            pass_width.zero? || pass_height.zero? ? 0 : (pass_row_bytes + 1) * pass_height
          end
        end
        inflated = "".b
        inflater = Zlib::Inflate.new
        begin
          idat_offset = 0
          while idat_offset < idat.bytesize
            inflater.inflate(idat.byteslice(idat_offset, 16_384)) do |part|
              inflated << part
              raise LimitError, "PNG decompressed data exceeds expected size" if inflated.bytesize > expected
            end
            idat_offset += 16_384
          end
          inflater.finish do |part|
            inflated << part
            raise LimitError, "PNG decompressed data exceeds expected size" if inflated.bytesize > expected
          end
        ensure
          inflater.close
        end
        raise DecodeError, "PNG decompressed size mismatch" unless inflated.bytesize == expected

        rgba = "\0".b * (width * height * 4)
        cursor = 0
        if interlace.zero?
          previous = nil
          (0...height).each do |y|
            filter = inflated.getbyte(cursor)
            row = inflated.byteslice(cursor + 1, row_bytes)
            cursor += row_bytes + 1
            decoded = Filters.unfilter(filter, row, previous, [1, (bits_per_pixel + 7) / 8].max)
            write_row(rgba, width, y, decoded, bit_depth, color_type, palette, transparency, output_width: width)
            previous = decoded
          end
        else
          ADAM7.each do |x_start, y_start, x_step, y_step|
            pass_width = pass_size(width, x_start, x_step)
            pass_height = pass_size(height, y_start, y_step)
            next if pass_width.zero? || pass_height.zero?
            pass_row_bytes = (pass_width * bits_per_pixel + 7) / 8
            previous = nil
            (0...pass_height).each do |pass_y|
              filter = inflated.getbyte(cursor)
              row = inflated.byteslice(cursor + 1, pass_row_bytes)
              cursor += pass_row_bytes + 1
              decoded = Filters.unfilter(filter, row, previous, [1, (bits_per_pixel + 7) / 8].max)
              write_row(rgba, pass_width, pass_y, decoded, bit_depth, color_type, palette, transparency, output_width: width, x_start: x_start, y_start: y_start, x_step: x_step, y_step: y_step)
              previous = decoded
            end
          end
        end
        Image.from_rgba(width, height, rgba, metadata: parse_metadata(chunks))
      end
      private_class_method :parse

      def pass_size(size, start, step)
        return 0 if start >= size

        (size - start + step - 1) / step
      end
      private_class_method :pass_size

      def write_row(output, row_width, pass_y, row, bit_depth, color_type, palette, transparency, output_width:, x_start: 0, y_start: 0, x_step: 1, y_step: 1)
        (0...row_width).each do |source_x|
          pixel = pixel_rgba(row, source_x, bit_depth, color_type, palette, transparency)
          x = x_start + source_x * x_step
          y = y_start + pass_y * y_step
          output[(y * output_width + x) * 4, 4] = pixel
        end
      end
      private_class_method :write_row

      def pixel_rgba(row, x, bit_depth, color_type, palette, transparency)
        sample = lambda do |index|
          if bit_depth == 16
            row.getbyte(index * 2) * 256 + row.getbyte(index * 2 + 1)
          elsif bit_depth < 8
            per_byte = 8 / bit_depth
            byte = row.getbyte(index / per_byte)
            shift = (per_byte - 1 - index % per_byte) * bit_depth
            (byte >> shift) & ((1 << bit_depth) - 1)
          else
            row.getbyte(index)
          end
        end
        convert = ->(value) { bit_depth == 16 ? ((value * 255 + 32_767) / 65_535) : ((value * 255 + ((1 << bit_depth) - 1) / 2) / ((1 << bit_depth) - 1)) }
        case color_type
        when 0
          gray = sample.call(x)
          transparent = transparency && (bit_depth == 16 ? transparency.unpack1("n") : transparency.unpack1("n") & ((1 << bit_depth) - 1)) == gray
          value = convert.call(gray)
          [value, value, value, transparent ? 0 : 255].pack("C4")
        when 2
          values = 3.times.map { |index| sample.call(x * 3 + index) }
          transparent = transparency && values == transparency.unpack("n3")
          [*values.map { |value| convert.call(value) }, transparent ? 0 : 255].pack("C4")
        when 3
          index = sample.call(x)
          raise DecodeError, "PNG palette index out of range" unless palette && index * 3 + 2 < palette.bytesize
          [*palette.byteslice(index * 3, 3).bytes, transparency&.getbyte(index) || 255].pack("C4")
        when 4
          gray = convert.call(sample.call(x * 2))
          alpha = convert.call(sample.call(x * 2 + 1))
          [gray, gray, gray, alpha].pack("C4")
        when 6
          4.times.map { |index| convert.call(sample.call(x * 4 + index)) }.pack("C4")
        end
      end
      private_class_method :pixel_rgba

      def parse_metadata(chunks)
        chunks.each_with_object({}) do |(type, data), metadata|
          case type
          when "tEXt"
            key, value = data.split("\0", 2)
            raise DecodeError, "invalid PNG tEXt chunk" unless key && !key.empty? && value
            metadata[key.force_encoding("ISO-8859-1").encode("UTF-8")] = value.force_encoding("ISO-8859-1").encode("UTF-8")
          when "iTXt"
            key, rest = data.split("\0", 2)
            raise DecodeError, "invalid PNG iTXt chunk" unless key && !key.empty? && rest && rest.bytesize >= 4
            compressed = rest.getbyte(0)
            raise DecodeError, "invalid PNG iTXt compression" unless [0, 1].include?(compressed) && rest.getbyte(1).zero?
            text = rest.byteslice(2..)
            language_end = text.index("\0")
            translated_end = text.index("\0", language_end + 1) if language_end
            raise DecodeError, "invalid PNG iTXt chunk" unless translated_end
            value = text.byteslice(translated_end + 1..)
            value = Zlib::Inflate.inflate(value) if compressed == 1
            value.force_encoding("UTF-8")
            raise DecodeError, "invalid PNG iTXt text" unless value.valid_encoding?
            key.force_encoding("UTF-8")
            raise DecodeError, "invalid PNG iTXt keyword" unless key.valid_encoding?
            metadata[key] = value
          end
        end
      end
      private_class_method :parse_metadata
    end

    module_function

    def encode(image, **options)
      Encoder.encode(image, **options)
    end

    def decode(bytes, **options)
      Decoder.decode(bytes, **options)
    end
  end

  module PPM
    module_function

    def encode(image, binary: true)
      rgb = image.to_rgb_bytes
      if binary
        "P6\n#{image.width} #{image.height}\n255\n".b + rgb
      else
        "P3\n#{image.width} #{image.height}\n255\n" + rgb.unpack("C*").each_slice(3).map { |pixel| pixel.join(" ") }.join("\n") + "\n"
      end
    end

    def decode(bytes, max_pixels: 16384 * 16384)
      bytes = String(bytes).b
      magic = bytes.byteslice(0, 2)
      raise DecodeError, "invalid PPM" unless %w[P3 P6].include?(magic)
      cursor = 2
      token = lambda do
        loop do
          cursor += 1 while cursor < bytes.bytesize && bytes.getbyte(cursor).chr.match?(/\s/)
          if bytes.getbyte(cursor) == 35
            cursor += 1
            cursor += 1 while cursor < bytes.bytesize && bytes.getbyte(cursor) != 10
          else
            break
          end
        end
        start = cursor
        cursor += 1 while cursor < bytes.bytesize && !bytes.getbyte(cursor).chr.match?(/\s/)
        value = bytes.byteslice(start, cursor - start)
        raise DecodeError, "truncated PPM" if value.nil? || value.empty?
        raise DecodeError, "invalid PPM number" unless value.match?(/\A\d+\z/)
        value.to_i
      end
      width, height, max = 3.times.map { token.call }
      raise DecodeError, "invalid PPM dimensions" unless width.positive? && height.positive? && max.between?(1, 65_535)
      raise LimitError, "image exceeds pixel limit" if width * height > max_pixels
      raise DecodeError, "truncated PPM header" if cursor >= bytes.bytesize
      cursor += bytes.byteslice(cursor, 2) == "\r\n" ? 2 : 1
      values = if magic == "P6"
        body = bytes.byteslice(cursor..)
        expected = width * height * 3 * (max < 256 ? 1 : 2)
        raise DecodeError, "invalid PPM pixel data length" unless body.bytesize == expected
        max < 256 ? body.bytes : body.unpack("n*")
      else
        cursor -= 1
        samples = Array.new(width * height * 3) { token.call }
        tail = bytes.byteslice(cursor..)
        raise DecodeError, "extra PPM samples" unless tail.match?(/\A(?:\s+|\#[^\n]*(?:\n|\z))*\z/)
        samples
      end
      raise DecodeError, "PPM sample exceeds maximum" if values.any? { |value| value > max }
      if max != 255
        values.map! { |value| (value * 255.0 / max).round }
      end
      rgba = values.each_slice(3).flat_map { |r, g, b| [r, g, b, 255] }.pack("C*")
      Image.from_rgba(width, height, rgba)
    rescue StandardError => e
      raise e if e.is_a?(DecodeError) || e.is_a?(LimitError)
      raise DecodeError, "invalid PPM: #{e.message}"
    end
  end

  module BMP
    module_function

    def encode(image)
      row_size = (image.width * 4 + 3) & ~3
      pixel_size = row_size * image.height
      header = "BM".b + [54 + pixel_size, 0, 0, 54].pack("L<S<S<L<")
      info = [40, image.width, image.height, 1, 32, 0, pixel_size, 2835, 2835, 0, 0].pack("L<l<l<S<S<L<L<l<l<L<L<")
      pixels = (image.height - 1).downto(0).map do |y|
        image.instance_variable_get(:@data).byteslice(y * image.width * 4, image.width * 4).bytes.each_slice(4).map { |r, g, b, a| [b, g, r, a] }.flatten.pack("C*")
      end.join
      header + info + pixels
    end

    def decode(bytes, max_pixels: 16384 * 16384)
      bytes = String(bytes).b
      raise DecodeError, "invalid BMP" unless bytes.start_with?("BM") && bytes.bytesize >= 54
      offset = bytes.byteslice(10, 4).unpack1("L<")
      header_size = bytes.byteslice(14, 4).unpack1("L<")
      width, height, planes, depth, compression = bytes.byteslice(18, 16).unpack("l<l<S<S<L<")
      raise UnsupportedError, "unsupported BMP" unless header_size >= 40 && planes == 1 && [24, 32].include?(depth) && compression.zero?
      top_down = height.negative?
      height = height.abs
      raise DecodeError, "invalid BMP dimensions" unless width.positive? && height.positive?
      raise LimitError, "image exceeds pixel limit" if width * height > max_pixels
      row_size = ((width * depth + 31) / 32) * 4
      raise DecodeError, "truncated BMP pixel data" if offset < 54 || offset + row_size * height > bytes.bytesize
      output = "".b
      height.times do |row|
        source_y = top_down ? row : height - row - 1
        data = bytes.byteslice(offset + source_y * row_size, width * depth / 8)
        data.bytes.each_slice(depth / 8) { |b, g, r, a| output << [r, g, b, depth == 32 ? a : 255].pack("C4") }
      end
      Image.from_rgba(width, height, output)
    rescue StandardError => e
      raise e if e.is_a?(Tessel::Error) || e.is_a?(ArgumentError)
      raise DecodeError, "invalid BMP: #{e.message}"
    end
  end
end
