# frozen_string_literal: true

module Tessel
  module Quantize
    MATRIX = [
      [0, 48, 12, 60, 3, 51, 15, 63], [32, 16, 44, 28, 35, 19, 47, 31],
      [8, 56, 4, 52, 11, 59, 7, 55], [40, 24, 36, 20, 43, 27, 39, 23],
      [2, 50, 14, 62, 1, 49, 13, 61], [34, 18, 46, 30, 33, 17, 45, 29],
      [10, 58, 6, 54, 9, 57, 5, 53], [42, 26, 38, 22, 41, 25, 37, 21]
    ].freeze
    private_constant :MATRIX

    module_function

    def palette_for(images, colors: 256, sample_limit: 100_000)
      images = [images] unless images.is_a?(Array)
      raise ArgumentError, "sample_limit must be positive" unless sample_limit.is_a?(Integer) && sample_limit.positive?
      validate_colors(colors)
      total = images.sum do |image|
        raise TypeError, "images must contain Tessel::Image values" unless image.is_a?(Image)

        image.width * image.height
      end
      raise ArgumentError, "images must not be empty" if total.zero?

      stride = [(total.to_f / sample_limit).ceil, 1].max
      histogram = Hash.new(0)
      position = 0
      images.each do |image|
        image.bytes.bytes.each_slice(4) do |r, g, b, a|
          histogram[[r, g, b]] += 1 if (position % stride).zero? && a.positive?
          position += 1
        end
      end
      histogram[[0, 0, 0]] = 1 if histogram.empty?
      median_cut(histogram, colors)
    end

    def fixed_palette
      (0..5).flat_map do |r|
        (0..5).flat_map { |g| (0..5).map { |b| [r * 51, g * 51, b * 51] } }
      end.concat((0...40).map { |n| value = (n * 255.0 / 39).round; [value, value, value] })
    end

    def web_safe_palette
      [0, 51, 102, 153, 204, 255].repeated_permutation(3).to_a
    end

    def quantize(image, colors: 256, palette: nil, dither: :none, serpentine: true)
      raise TypeError, "image must be a Tessel::Image" unless image.is_a?(Image)
      raise TypeError, "palette must be an array" if palette && !palette.is_a?(Array)
      raise ArgumentError, "palette must not be empty" if palette && palette.empty?
      raise ArgumentError, "unknown dither: #{dither}" unless %i[none floyd_steinberg ordered].include?(dither)

      palette ||= palette_for(image, colors: colors)
      palette = palette.map do |color|
        raise TypeError, "palette colors must be RGB triples" unless color.is_a?(Array) && color.length == 3 && color.all? { |v| v.is_a?(Integer) && v.between?(0, 255) }
        color
      end
      raise ArgumentError, "palette must contain at most 256 colors" if palette.length > 256

      nearest = {}
      indices = "\0".b * (image.width * image.height)
      errors = Array.new(image.width) { [0, 0, 0] }
      next_errors = Array.new(image.width) { [0, 0, 0] }
      bytes = image.bytes
      (0...(image.width * image.height)).each do |index|
        offset = index * 4
        r, g, b, alpha = bytes.getbyte(offset), bytes.getbyte(offset + 1), bytes.getbyte(offset + 2), bytes.getbyte(offset + 3)
        x = index % image.width
        y = index / image.width
        reverse = dither == :floyd_steinberg && serpentine && y.odd?
        x = image.width - x - 1 if reverse
        if dither == :floyd_steinberg && alpha.positive?
          input = [r, g, b].each_with_index.map { |v, c| [[v + errors[x][c].div(16), 0].max, 255].min }
        elsif dither == :ordered
          offset = ((MATRIX[y % 8][x % 8] * 2 - 63) * 4).div(16)
          input = [r, g, b].map { |v| [[v + offset, 0].max, 255].min }
        else
          input = [r, g, b]
        end
        key = input.pack("C3")
        palette_index = nearest[key] ||= closest_index(input, palette)
        indices.setbyte(index, palette_index)

        if dither == :floyd_steinberg
          color = palette[palette_index]
          direction = reverse ? -1 : 1
          distribute(errors, next_errors, x, direction, input, color)
        end
        if x == (reverse ? 0 : image.width - 1)
          errors, next_errors = next_errors, Array.new(image.width) { [0, 0, 0] }
        end
      end
      [indices, palette]
    end

    def closest_index(color, palette)
      palette.each_index.min_by do |index|
        palette[index].each_index.sum { |channel| (color[channel] - palette[index][channel])**2 }
      end
    end
    private_class_method :closest_index

    def validate_colors(colors)
      raise ArgumentError, "colors must be between 2 and 256" unless colors.is_a?(Integer) && colors.between?(2, 256)
    end
    private_class_method :validate_colors

    def median_cut(histogram, limit)
      boxes = [histogram.to_a]
      while boxes.length < limit
        index = boxes.each_index.max_by do |box_index|
          box = boxes[box_index]
          ranges = 3.times.map { |channel| box.map { |(color, _)| color[channel] }.then { |values| values.max - values.min } }
          [ranges.max, box.sum { |_, count| count }, -box_index]
        end
        break unless index && boxes[index].length > 1

        box = boxes.delete_at(index)
        channel = (0..2).max_by { |component| box.map { |(color, _)| color[component] }.then { |values| values.max - values.min } }
        sorted = box.sort_by { |color, _| [color[channel], *color] }
        midpoint = (box.sum { |_, count| count } + 1) / 2
        count = 0
        split = sorted.index do |_, weight|
          count += weight
          count >= midpoint
        end
        split = [[split + 1, 1].max, sorted.length - 1].min
        boxes.insert(index, sorted[0...split], sorted[split..])
      end
      boxes.map do |box|
        count = box.sum { |_, weight| weight }
        3.times.map { |channel| (box.sum { |(color, weight)| color[channel] * weight }.to_f / count).round }
      end.uniq
    end
    private_class_method :median_cut

    def distribute(current, following, x, direction, input, color)
      3.times do |channel|
        error = input[channel] - color[channel]
        right = x + direction
        current[right][channel] += error * 7 if right.between?(0, current.length - 1)
        following[x][channel] += error * 5
        following[x - direction][channel] += error * 3 if (x - direction).between?(0, following.length - 1)
        following[x + direction][channel] += error if (x + direction).between?(0, following.length - 1)
      end
    end
    private_class_method :distribute
  end
end
