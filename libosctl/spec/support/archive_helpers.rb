# frozen_string_literal: true

require 'rubygems/package'
require 'stringio'
require 'zlib'

module ArchiveHelpers
  def tar_entries(blob)
    io = blob.is_a?(String) ? StringIO.new(blob) : blob
    io.rewind if io.respond_to?(:rewind)

    entries = {}

    Gem::Package::TarReader.new(io) do |tar|
      tar.each do |entry|
        entries[entry.full_name] = if entry.directory?
                                     :directory
                                   else
                                     entry.read
                                   end
      end
    end

    entries
  end

  def gzipped_tar_entries(blob)
    Zlib::GzipReader.wrap(StringIO.new(blob)) do |gz|
      tar_entries(gz)
    end
  end
end

RSpec.configure do |config|
  config.include ArchiveHelpers
end
