<h1 align="center">Tessel</h1>

<p align="center">Dependency-light image I/O and mutable RGBA8 image surfaces for Ruby graphics.</p>

<p align="center">
  <a href="https://rubygems.org/gems/tessel"><img src="https://badge.fury.io/rb/tessel.svg" alt="Gem Version"></a>
  <a href="https://rubygems.org/gems/tessel"><img src="https://img.shields.io/gem/dt/tessel?label=downloads" alt="Downloads"></a>
  <a href="https://www.ruby-lang.org/"><img src="https://img.shields.io/badge/ruby-%3E%3D3.1-CC342D?logo=ruby&amp;logoColor=white" alt="Ruby Version"></a>
  <a href="LICENSE.txt"><img src="https://img.shields.io/badge/license-MIT-750014.svg" alt="License"></a>
</p>

[Features](#features) · [Installation](#installation) · [Quick Start](#quick-start)

***

Tessel is the shared pixel layer for the rbgfx ecosystem. It reads and writes common image formats and gives drawing code a small, predictable RGBA8 surface.

## Features

- PNG decoding and encoding, including filters, Adam7 interlace, palettes, and
  text metadata.
- PPM (P3/P6) and BMP (24/32-bit) input and output.
- Straight-alpha RGBA8 pixels with row-major, top-down storage.
- Clipped rectangles, horizontal spans, alpha blits, masks, crop, and resize.
- Median-cut palettes, fixed palettes, nearest-color mapping, and ordered or
  Floyd–Steinberg dithering for indexed image output.
- Explicit decode, unsupported-format, and pixel-limit errors.
- Optional RBGL framebuffer conversion.

## Installation

Add Tessel to your Gemfile:

~~~ruby
gem "tessel"
~~~

Then run:

~~~sh
bundle install
~~~

Or install the released gem directly:

~~~sh
gem install tessel
~~~

### Requirements

- Ruby 3.1 or newer.
- No runtime gems beyond Ruby's standard library are required.

## Quick Start

~~~ruby
require "tessel"

image = Tessel::Image.new(320, 180, fill: "#101827")
image.fill_rect(20, 20, 80, 40, "#e85d75")
image.write("out.png", filter: :adaptive)

copy = Tessel.read("out.png")
puts [copy.width, copy.height, copy[20, 20]].inspect

palette = Tessel::Quantize.palette_for([image, copy], colors: 32)
indices, palette = Tessel::Quantize.quantize(image, palette: palette, dither: :floyd_steinberg)
puts "#{indices.bytesize} indexed pixels, #{palette.length} colors"
~~~

Use <code>fill_rect</code>, <code>hspan</code>, <code>blit</code>, and
<code>blit_mask</code> for drawing. Image operations clip to the surface
boundaries.

`Tessel::Quantize.palette_for(images, colors:)` samples visible pixels from one
image or an array of images and builds a deterministic median-cut RGB palette.
`Quantize.quantize(image, palette:, dither:)` returns a binary string with one
palette index per pixel and the palette used. Supported dithering modes are
`:none`, `:ordered`, and `:floyd_steinberg`. Transparent pixels do not affect
palette generation. `fixed_palette` returns the 6×6×6 color cube plus 40 gray
levels; `web_safe_palette` returns the 216 web-safe colors.

## Development

~~~sh
bundle install
bundle exec rake verify
~~~

Performance scripts are available for local, workload-specific checks:

~~~sh
ruby bench/decode_bench.rb
ruby bench/encode_bench.rb
ruby bench/raster_bench.rb
~~~

## Contributing

Bug reports and pull requests are welcome at [rbgfx/tessel](https://github.com/rbgfx/tessel).

## License

[MIT](LICENSE.txt)
