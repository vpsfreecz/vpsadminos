require 'osvm'
require 'fileutils'
require 'json'
require 'shellwords'
require 'tmpdir'

module ImagePipeline
  class Worker
    class Failure < StandardError; end

    def initialize(index, config:, root:, source:, source_dir:, bind:)
      @source = source
      @bind = bind
      @files = File.join(root, "worker-#{index}", 'exports')
      state = File.join(root, "worker-#{index}", 'state')
      raise ArgumentError, 'worker state must be fresh' if File.exist?(state)

      FileUtils.mkdir_p([@files, state])
      cfg = Marshal.load(Marshal.dump(config))
      # Omit opts to use UserNetwork's complete network/host/DNS defaults.
      # A partial opts hash replaces those defaults rather than merging them.
      cfg['networks'] = [{ 'type' => 'user' }]
      cfg['sharedFileSystems'] = {
        'pipelineSource' => source_dir,
        'pipelineFiles' => @files
      }
      @sockets = Dir.mktmpdir('osvm-images-')
      @machine = OsVm::VpsadminosMachine.new("image-worker-#{index}", OsVm::MachineConfig.from_config(cfg), state, @sockets)
      @machine.start
      @machine.wait_for_boot
      %w[pipelineSource pipelineFiles].each do |name|
        flags = name == 'pipelineSource' ? '-o ro' : ''
        @machine.succeeds("mkdir -p /mnt/#{name} && mount -t virtiofs #{flags} #{name} /mnt/#{name}")
      end
      @machine.wait_for_osctl_pool('tank')
      @machine.wait_until_online
      @machine.succeeds('zfs create -p tank/image-builds')
    rescue StandardError
      close
      raise
    end

    def perform(item)
      id = item.fetch('id')
      raise ArgumentError, 'invalid item ID' unless id.match?(/\A[\w.-]+\z/)

      host = File.join(@files, id)
      guest = "/mnt/pipelineFiles/#{id}"
      FileUtils.mkdir_p(host)
      descriptor = File.join(host, 'assignment.json')
      command = ['env', "OSCTL_IMAGE_VPSADMINOS_REV=#{@source}"] +
                %w[osctl-image --build-scripts /mnt/pipelineSource/image-scripts
                   --vpsadminos-dir /mnt/pipelineSource]
      if item['assignment']
        File.write(descriptor, "#{JSON.pretty_generate(item.fetch('assignment'))}\n")
      elsif !File.exist?(descriptor)
        @machine.succeeds(Shellwords.join(command + ['capture', '--source', @source, item.fetch('name'),
                                                     "#{guest}/assignment.json"]))
      end
      assignment = JSON.parse(File.read(descriptor))
      raise 'assignment source mismatch' unless assignment.fetch('source') == @source

      item['assignment'] = assignment
      item['attempt'] ||= 1
      @bind.call(item, assignment)
      status, output = @machine.execute(
        Shellwords.join(command + ['assigned', '--build-dataset', 'tank/image-builds',
                                   '--output-dir', "#{guest}/output", '--result', "#{guest}/result.json",
                                   "#{guest}/assignment.json"]), timeout: 24 * 60 * 60
      )
      File.write(File.join(host, 'command.log'), output)
      result = JSON.parse(File.read(File.join(host, 'result.json')))
      raise 'result assignment mismatch' unless result.fetch('assignment') == assignment
      raise 'invalid successful worker result' if status != 0 && result['status'] == 'verified'

      # A failed command is reusable only after its normal cleanup completed.
      # Retained test CTs or build children quarantine this worker instead.
      @machine.succeeds("test -z \"$(osctl-image ct ls -H -o type | grep -v '^builder$')\"")
      datasets = @machine.succeeds('zfs list -H -o name -r tank/image-builds')[1].lines.map(&:strip)
      raise Failure, 'build dataset cleanup incomplete' unless datasets == ['tank/image-builds']

      result.fetch('files').each do |file|
        path = file.fetch('path')
        raise 'export path escapes worker' unless path.start_with?("#{guest}/output/")

        file['path'] = File.join(host, path.delete_prefix("#{guest}/"))
      end
      result.merge('builder' => assignment.fetch('config').fetch('BUILDER'))
    rescue OsVm::TimeoutError, OsVm::MachineShellClosed, IOError => e
      # Uncertain command/transport effects must not return this guest to the
      # queue. The coordinator records the failure; a new run can retry it.
      close
      raise Failure, "#{e.class}: #{e.message}"
    end

    def close
      if @machine
        @machine.kill
        @machine.destroy_disks
        @machine.finalize
        @machine.cleanup
        @machine = nil
      end
      FileUtils.remove_entry_secure(@sockets) if @sockets && File.directory?(@sockets)
    end
  end
end
