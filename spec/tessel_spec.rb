# frozen_string_literal: true

RSpec.describe Tessel do
  it "has a version number" do
    expect(Tessel::VERSION).not_to be nil
  end

  it "round trips RGBA PNGs" do
    image = Tessel::Image.new(2, 2)
    image[0, 0] = [255, 0, 0, 255]
    image[1, 1] = [0, 255, 0, 128]

    decoded = Tessel.decode(Tessel::PNG.encode(image, filter: :adaptive))

    expect(decoded.bytes).to eq(image.bytes)
  end

  it "clips spans and alpha blends" do
    image = Tessel::Image.new(3, 2, fill: "#000000")
    image.hspan(-1, 1, 0, [255, 0, 0, 255])
    image.fill_rect(1, 0, 1, 1, [255, 0, 0, 128], blend: :alpha)

    expect(image[0, 0]).to eq([255, 0, 0, 255])
    expect(image[1, 0]).to eq([255, 0, 0, 255])
    expect(image[2, 0]).to eq([0, 0, 0, 255])
  end

  it "writes and reads metadata" do
    image = Tessel::Image.new(1, 1, metadata: { "Software" => "tessel", "日本語" => "画像" })
    decoded = Tessel.decode(Tessel::PNG.encode(image))

    expect(decoded.metadata).to eq(image.metadata)
  end

  it "round trips BMP pixels including alpha" do
    image = Tessel::Image.from_rgba(2, 1, [1, 2, 3, 4, 255, 128, 0, 200].pack("C*"))
    expect(Tessel.decode(Tessel::BMP.encode(image)).bytes).to eq(image.bytes)
  end

  it "rejects truncated PPM headers and invalid sample data" do
    expect { Tessel.decode("P6\n2 ") }.to raise_error(Tessel::DecodeError)
    expect { Tessel.decode("P6\n1 1\n255\n\x00".b) }.to raise_error(Tessel::DecodeError)
    expect { Tessel.decode("P3\n1 1\n255\n256 0 0") }.to raise_error(Tessel::DecodeError)
    expect { Tessel.decode("P3\n1 1\n255\n0 0 0 12") }.to raise_error(Tessel::DecodeError)
  end

  it "rejects malformed PNG text and decodes Latin-1 tEXt" do
    png = Tessel::PNG.encode(Tessel::Image.new(1, 1))
    header = png.byteslice(0, 33)
    image_data = png.byteslice(33..)
    broken = header.dup
    Tessel::PNG::Chunk.write(broken, "iTXt", "name\0\1\1\0\0value".b)
    expect { Tessel.decode(broken + image_data) }.to raise_error(Tessel::DecodeError)

    valid = header.dup
    Tessel::PNG::Chunk.write(valid, "tEXt", "Title\0caf\xE9".b)
    expect(Tessel.decode(valid + image_data).metadata["Title"]).to eq("café")
  end

  it "rejects misplaced and duplicate PNG palette or transparency chunks" do
    rgb = Tessel::PNG.encode(Tessel::Image.new(1, 1), color_type: :rgb)
    header = rgb.byteslice(0, 33)
    image_data = rgb.byteslice(33...-12)

    misplaced = header.dup
    Tessel::PNG::Chunk.write(misplaced, "PLTE", "\0\0\0".b)
    misplaced << image_data
    Tessel::PNG::Chunk.write(misplaced, "tRNS", "\0".b * 6)
    Tessel::PNG::Chunk.write(misplaced, "IEND", "")
    expect { Tessel.decode(misplaced) }.to raise_error(Tessel::DecodeError)

    duplicate = header.dup
    2.times { Tessel::PNG::Chunk.write(duplicate, "PLTE", "\0\0\0".b) }
    duplicate << rgb.byteslice(33..)
    expect { Tessel.decode(duplicate) }.to raise_error(Tessel::DecodeError)
  end

  it "rejects PNG streams that expand beyond their declared size" do
    image = Tessel::Image.new(1, 1)
    png = Tessel::PNG.encode(image)
    output = Tessel::SIGNATURE.dup
    output << png.byteslice(8, 25)
    Tessel::PNG::Chunk.write(output, "IDAT", Zlib::Deflate.deflate("\0".b * 100_000))
    Tessel::PNG::Chunk.write(output, "IEND", "")

    expect { Tessel.decode(output) }.to raise_error(Tessel::LimitError)
  end

  it "clips blits with negative source offsets" do
    source = Tessel::Image.new(2, 1, fill: [255, 0, 0])
    target = Tessel::Image.new(3, 1)
    target.blit(source, 0, 0, sx: -1, w: 3, blend: :copy)
    expect(target[0, 0]).to eq([0, 0, 0, 0])
    expect(target[1, 0]).to eq([255, 0, 0, 255])
  end

  it "crops from the requested source origin and snapshots overlapping blits" do
    image = Tessel::Image.from_rgba(3, 1, [1, 0, 0, 255, 2, 0, 0, 255, 3, 0, 0, 255].pack("C*"))
    expect(image.crop(1, 0, 2, 1).bytes).to eq([2, 0, 0, 255, 3, 0, 0, 255].pack("C*"))
    expect(image.crop(-1, 0, 2, 1)[0, 0]).to eq([0, 0, 0, 0])

    image.blit(image, 1, 0, w: 2, blend: :copy)
    expect((0..2).map { |x| image[x, 0][0] }).to eq([1, 1, 2])

    column = Tessel::Image.from_rgba(1, 3, [1, 0, 0, 255, 2, 0, 0, 255, 3, 0, 0, 255].pack("C*"))
    column.blit(column, 0, 1, h: 2, blend: :copy)
    expect((0..2).map { |y| column[0, y][0] }).to eq([1, 1, 2])
  end
end
