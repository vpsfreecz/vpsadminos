require 'fileutils'
require 'json'
require 'tempfile'

# Invoked only by stage 2 before runit, while /run belongs to this new boot.
path = '/run/osctl/container-state-history.json'
FileUtils.mkdir_p(File.dirname(path), mode: 0o711)
data = {
  schema_version: 1,
  boot_id: File.read('/proc/sys/kernel/random/boot_id').strip,
  next_sequence: 1,
  dropped_events: 0,
  entries: [],
  events: []
}

Tempfile.create(['.container-state-history-', '.json'], File.dirname(path)) do |file|
  file.write(JSON.generate(data))
  file.flush
  file.fsync
  File.rename(file.path, path)
end

# Only boot initialization can clear a known failure from the previous boot.
FileUtils.rm_f('/run/osctl/container-state-history.failed.json')
