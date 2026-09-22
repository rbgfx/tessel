# frozen_string_literal: true

require "benchmark"
require_relative "../lib/tessel"

image = Tessel::Image.new(1024, 1024)
image.fill_rect(0, 0, image.width, image.height, [40, 80, 120, 255])
encoded = Tessel::PNG.encode(image, filter: :up)

puts "decode 1024x1024 RGBA8"
Benchmark.bm(8) { |benchmark| benchmark.report { Tessel.decode(encoded) } }
