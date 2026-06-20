require 'libosctl'
require 'osctld/exceptions'
require 'shellwords'
require 'tempfile'

module OsCtld
  class Container::DatasetBuilder
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::SwitchUser

    # @param opts [Hash]
    # @option opts [Command::Base] :cmd
    def initialize(opts = {})
      @builder_opts = opts
    end

    # @param ds [OsCtl::Lib::Zfs::Dataset]
    # @param opts [Hash] options
    # @option opts [OsCtl::Lib::IdMap] :uid_map
    # @option opts [OsCtl::Lib::IdMap] :gid_map
    # @option opts [Boolean] :parents
    # @option opts [Hash] :properties
    def create_dataset(ds, opts = {})
      zfs_opts = {
        properties: {
          canmount: 'noauto'
        }.merge(opts[:properties] || {})
      }
      zfs_opts[:parents] = true if opts[:parents]

      if opts[:uid_map]
        zfs_opts[:properties][:uidmap] = opts[:uid_map].map(&:to_s).join(',')
      end

      if opts[:gid_map]
        zfs_opts[:properties][:gidmap] = opts[:gid_map].map(&:to_s).join(',')
      end

      ds.create!(**zfs_opts)
      ds.mount(recursive: true)
    end

    # @param src [Array<OsCtl::Lib::Zfs::Dataset>]
    # @param dst [Array<OsCtl::Lib::Zfs::Dataset>]
    # @param from [String, nil] base snapshot
    # @return [String] snapshot name
    def copy_datasets(src, dst, from: nil)
      snap = "osctl-copy-#{from ? 'incr' : 'base'}-#{Time.now.to_i}"
      zfs(:snapshot, nil, src.map { |ds| "#{ds}@#{snap}" }.join(' '))

      zipped = src.zip(dst)

      zipped.each do |src_ds, dst_ds|
        progress("Copying dataset #{src_ds.relative_name}")
        syscmd("zfs send -p -L #{from ? "-i @#{from}" : ''} #{src_ds}@#{snap} " \
               "| zfs recv -F #{dst_ds}")
      end

      snap
    end

    # @param image [String] image path
    # @param dir [String] dir to extract it to
    # @param ds [OsCtl::Lib::Zfs::Dataset]
    # @param opts [Hash] options
    # @option opts [String] :distribution
    # @option opts [String] :version
    # @option opts [Boolean] :mapping
    def from_local_archive(image, dir, ds, opts = {})
      progress('Extracting image')
      syscmd("tar -xzf #{image} -C #{dir}")
      shift_dataset(ds, opts) if opts[:mapping]
    end

    # @param image [String] image path
    # @param member [String] file from the tar to use
    # @param compression [:gzip, :off] compression type
    # @param ds [OsCtl::Lib::Zfs::Dataset]
    def from_tar_stream(image, member, compression, ds)
      progress('Writing data stream')

      commands = [
        ['tar', '-xOf', image, member]
      ]

      case compression
      when :gzip
        commands << ['gunzip']
      when :off
        # no command
      else
        raise "unexpected compression type '#{compression}'"
      end

      commands << ['zfs', 'recv', '-F', ds.to_s]

      command_string = commands.map { |c| Shellwords.join(c) }.join(' | ')
      pipeline_script = <<~BASH
        #{command_string}
        pipeline_status=("${PIPESTATUS[@]}")
        printf '%s\n' "${pipeline_status[*]}" > "$1"
        for stage_status in "${pipeline_status[@]}"; do
          if (( stage_status != 0 )); then
            exit "$stage_status"
          fi
        done
      BASH

      # Note that we intentionally use shell to run the pipeline. Whenever ruby
      # is more involved in the process, we start to experience random deadlocks
      # when the zfs receive hangs.
      stderr_output, stage_statuses, status = Tempfile.create('osctld-import-stream-stderr') do |stderr|
        Tempfile.create('osctld-import-stream-status') do |status_file|
          pid = Process.spawn(
            'bash',
            '-c', pipeline_script,
            'osctld-import-stream', status_file.path,
            err: stderr
          )
          wait_result = Process.wait2(pid)
          status_file.rewind
          statuses = status_file.read.strip.split.map { |v| Integer(v, 10) }
          stderr.rewind

          [stderr.read, statuses, wait_result[1]]
        end
      end

      complete_status = stage_statuses.length == commands.length
      return nil if status.success? && complete_status && stage_statuses.all?(&:zero?)

      shell_status =
        if status.signaled?
          "signal #{status.termsig}"
        else
          status.exitstatus.to_s
        end

      failed_stages = commands.each_with_index.filter_map do |command, i|
        stage_status = stage_statuses[i]
        next if stage_status.nil? || stage_status == 0

        "stage #{i + 1} '#{Shellwords.join(command)}' exited with #{stage_status}"
      end

      detail =
        if !complete_status
          "pipeline reported #{stage_statuses.length} of #{commands.length} stage statuses; " \
            "shell exited with #{shell_status}"
        elsif failed_stages.any?
          "#{failed_stages.join(', ')}; shell exited with #{shell_status}"
        else
          "shell exited with #{shell_status} despite successful stage statuses"
        end

      msg = "failed to import stream: #{detail}"
      stderr_output = stderr_output.strip
      stderr_tail = stderr_output.bytesize > 4096 ? stderr_output.byteslice(-4096, 4096) : stderr_output
      msg = "#{msg}, stderr: #{stderr_tail}" unless stderr_tail.empty?

      raise CommandFailed, msg
    end

    # @param ds [OsCtl::Lib::Zfs::Dataset]
    # @param opts [Hash] options
    # @option opts [OsCtl::Lib::IdMap] :uid_map
    # @option opts [OsCtl::Lib::IdMap] :gid_map
    def shift_dataset(ds, opts = {})
      progress('Configuring UID/GID mapping')

      set_opts = []

      if opts[:uid_map]
        set_opts << "\"uidmap=#{opts[:uid_map].map(&:to_s).join(',')}\""
      end

      if opts[:gid_map]
        set_opts << "\"gidmap=#{opts[:gid_map].map(&:to_s).join(',')}\""
      end

      if set_opts.empty?
        raise 'provide uid_map or gid_map'
      end

      zfs(:unmount, nil, ds, valid_rcs: [1])
      zfs(:set, set_opts.join(' '), ds)

      5.times do |i|
        zfs(:mount, nil, ds)

        f = Tempfile.create(['.ugid-map-test'], ds.mountpoint)
        f.close

        st = File.stat(f.path)
        File.unlink(f.path)

        uid_ok = !opts[:uid_map] || st.uid == opts[:uid_map].ns_to_host(0)
        gid_ok = !opts[:gid_map] || st.gid == opts[:gid_map].ns_to_host(0)

        if uid_ok && gid_ok
          return # rubocop:disable Lint/NonLocalExitFromIterator
        end

        zfs(:unmount, nil, ds)
        sleep(1 + i)
      end

      raise 'unable to configure UID/GID mapping'
    end

    protected

    def progress(msg)
      return unless @builder_opts[:cmd]

      @builder_opts[:cmd].send(:progress, msg)
    end
  end
end
