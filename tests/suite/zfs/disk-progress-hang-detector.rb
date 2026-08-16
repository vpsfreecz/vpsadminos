# frozen_string_literal: true

class ZfsDiskProgressHangDetector
  HUNG_LINE = /INFO: task (txg_sync|zpool):([0-9]+) blocked for more than/

  def initialize(&disk_progress)
    @disk_progress = disk_progress
    @last_progress = {}
  end

  def observe(line)
    match = HUNG_LINE.match(line)
    return false unless match

    key = match.captures
    progress = @disk_progress.call
    stalled = @last_progress.key?(key) && @last_progress[key] == progress
    @last_progress[key] = progress
    stalled
  end
end
