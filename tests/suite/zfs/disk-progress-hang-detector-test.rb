# frozen_string_literal: true

require_relative 'disk-progress-hang-detector'

progress = [
  ["machine-sda.img", 8, 1, 0],
  ["machine-sdb.img", 8, 1, 0]
]
detector = ZfsDiskProgressHangDetector.new { progress }
warning = "INFO: task txg_sync:3760 blocked for more than 122 seconds."

raise "first warning was fatal" if detector.observe(warning)

progress = [
  ["machine-sda.img", 8, 1, 0],
  ["machine-sdb.img", 16, 2, 1]
]
raise "disk progress was fatal" if detector.observe(warning)
raise "unchanged progress was not fatal" unless detector.observe(warning)

puts "disk-progress hang detector: pass"
