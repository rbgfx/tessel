# Tessel

> Dependency-light image I/O and mutable RGBA8 image surfaces for Ruby graphics.

[![Gem version](https://badge.fury.io/rb/tessel.svg)](https://rubygems.org/gems/tessel) [![Downloads](https://img.shields.io/gem/dt/tessel?label=downloads)](https://rubygems.org/gems/tessel) [![Ruby](https://img.shields.io/badge/ruby-%3E%3D3.1-CC342D?logo=ruby&logoColor=white)](https://www.ruby-lang.org/) [![CI](https://github.com/rbgfx/tessel/actions/workflows/main.yml/badge.svg)](https://github.com/rbgfx/tessel/actions/workflows/main.yml) [![License](https://img.shields.io/badge/license-MIT-750014.svg)](LICENSE.txt)

**[Features](#features) · [Installation](#installation) · [Requirements](#requirements) · [Quick start](#quick-start) · [Development](#development) · [License](#license) · [Website](https://rbgfx.github.io/tessel/)**

---

Tessel is the shared pixel layer for the rbgfx ecosystem, with predictable top-down RGBA8 storage.

## Features

- PNG decoding and encoding, including filters, Adam7 interlace, palettes, and
  text metadata.
- PPM (P3/P6) and BMP (24/32-bit) input and output.
- Straight-alpha RGBA8 pixels with row-major, top-down storage.
- Clipped rectangles, horizontal spans, alpha blits, masks, crop, and resize.
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

## Requirements

- Ruby 3.1 or newer.
- No runtime gems beyond Ruby's standard library are required.

## Quick start

~~~ruby
require "tessel"

image = Tessel::Image.new(320, 180, fill: "#101827")
image.fill_rect(20, 20, 80, 40, "#e85d75")
image.write("out.png", filter: :adaptive)

copy = Tessel.read("out.png")
puts [copy.width, copy.height, copy[20, 20]].inspect
~~~

Use <code>fill_rect</code>, <code>hspan</code>, <code>blit</code>, and
<code>blit_mask</code> for drawing. Image operations clip to the surface
boundaries.

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

## License

[MIT](LICENSE.txt)
