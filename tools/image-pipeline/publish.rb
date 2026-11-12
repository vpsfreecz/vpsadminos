#!/usr/bin/env ruby
require 'json'
require 'optparse'
require 'digest'
require 'fileutils'
require_relative 'lib/image_pipeline/publisher'

options = {}
OptionParser.new do |parser|
  %w[summary publisher source-dir receipts].each do |key|
    parser.on("--#{key} VALUE") { |value| options[key] = value }
  end
end.parse!
summary = JSON.parse(File.read(options.fetch('summary')))
source_dir = options.fetch('source-dir')
sha = IO.popen(['git', '-C', source_dir, 'rev-parse', 'HEAD'], &:read).strip
raise 'publisher checkout differs from receipt source' unless sha == summary.fetch('source').fetch('sha')

control = ImagePipeline::Control.new(options.fetch('publisher'), repository: 'vpsadminos', receipts: options.fetch('receipts'))
# Publication consumes durable producer receipts rather than re-running builds
# or requiring a sealed/full-success run. Never place publisher keys in guests.
result = ImagePipeline::Publisher.new(summary, control).publish(source_dir:)
File.write(File.join(options.fetch('receipts'), 'publication.json'), "#{JSON.pretty_generate(result)}\n")
