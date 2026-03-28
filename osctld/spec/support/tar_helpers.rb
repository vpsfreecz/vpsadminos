# frozen_string_literal: true

require 'rubygems/package'
require 'stringio'

module TarHelpers
  def build_tar(entries)
    io = StringIO.new

    Gem::Package::TarWriter.new(io) do |tar|
      entries.each do |entry|
        name = entry.fetch(:name)
        mode = entry.fetch(:mode, 0o644)

        if entry[:type] == :directory
          tar.mkdir(name, mode)
          next
        end

        body = entry.fetch(:body, '')

        tar.add_file_simple(name, mode, body.bytesize) do |tf|
          tf.write(body)
        end
      end
    end

    io.rewind
    io
  end
end

RSpec.configure do |config|
  config.include TarHelpers
end
