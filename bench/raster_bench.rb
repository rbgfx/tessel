# frozen_string_literal: true

require "benchmark"
require_relative "../lib/tessel"

puts "raster 640x480"
Benchmark.bm(12) do |benchmark|
  benchmark.report("clear") do
    image = Tessel::Image.new(640, 480)
    image.clear([0, 0, 0, 255])
  end
  benchmark.report("1000 rectangles") do
    image = Tessel::Image.new(640, 480)
    1000.times { |index| image.fill_rect(index % 620, index % 460, 20, 20, [255, 80, 40, 255]) }
  end
end
