# frozen_string_literal: true

begin
  require "rbgl"
rescue LoadError => error
  raise LoadError, "tessel/rbgl requires the rbgl gem: #{error.message}"
end

module Tessel
  module RBGL
    module_function

    def image_to_texture(image)
      colors = image.bytes.bytes.each_slice(4).map { |r, g, b, a| Larb::Color.rgba(r / 255.0, g / 255.0, b / 255.0, a / 255.0) }
      ::RBGL::Engine::Texture.new(image.width, image.height, colors)
    end

    def texture_from_png(path)
      image_to_texture(Tessel.read(path))
    end

    def framebuffer_to_image(framebuffer)
      Image.from_rgba(framebuffer.width, framebuffer.height, framebuffer.to_rgba_bytes)
    end
  end
end

class RBGL::Engine::Texture
  def self.from_image(image)
    Tessel::RBGL.image_to_texture(image)
  end

  def self.from_png(path)
    Tessel::RBGL.texture_from_png(path)
  end
end

class RBGL::Engine::Framebuffer
  def to_image
    Tessel::RBGL.framebuffer_to_image(self)
  end
end
