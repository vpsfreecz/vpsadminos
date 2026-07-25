require 'libosctl/zfs/stream'
require 'osctld/commands/logged'
require 'osctld/local_transfer/log'
require 'osctld/utils/container'
require 'securerandom'

module OsCtld
  module Commands::Container::LocalTransfer; end

  class Commands::Container::LocalTransfer::Base < Commands::Logged
    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::System
    include Utils::Container

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    protected

    def operation
      raise NotImplementedError
    end

    def require_local_transfer_log!(ct)
      log = ct.local_transfer_log
      error!('invalid local transfer sequence') unless log

      unless log.opts.operation == operation
        error!("local transfer is for #{log.opts.operation}, not #{operation}")
      end

      log
    end

    def target_pool(log)
      DB::Pools.find(log.opts.target_pool) || error!('target pool not found')
    end

    def target_ct(log)
      pool = target_pool(log)
      DB::Containers.find(log.opts.target_id, pool) || error!('target container not found')
    end

    def ensure_target_staged_or_complete!(log)
      ct = target_ct(log)

      ct.exclusively do
        unless %i[staged stopped].include?(ct.state)
          error!('target container is not staged')
        end
      end

      ct
    end

    def complete_target!(log)
      ct = ensure_target_staged_or_complete!(log)

      ct.state = :complete if ct.state == :staged
      ct
    end

    def start_target!(log)
      call_cmd!(
        Commands::Container::Start,
        id: log.opts.target_id,
        pool: log.opts.target_pool,
        force: true
      )
    end

    def build_dataset_map(source_ct, target_ct)
      root = LocalTransfer::Log::Dataset.new(
        relative_name: '/',
        source: source_ct.dataset.name,
        target: target_ct.dataset.name
      )

      children = source_ct.dataset.descendants.map do |src_ds|
        LocalTransfer::Log::Dataset.new(
          relative_name: src_ds.relative_name,
          source: src_ds.name,
          target: File.join(target_ct.dataset.name, src_ds.relative_name)
        )
      end

      [root, *children]
    end

    def validate_dataset_layout!(ct)
      expected = ct.local_transfer_log.opts.datasets.map(&:source).sort
      actual = ct.datasets.map(&:name).sort

      return if expected == actual

      error!('container dataset layout changed since transfer was prepared; cancel and start again')
    end

    def snapshot_name(kind)
      prefix = operation == :copy ? 'osctl-copy' : 'osctl-move'
      "#{prefix}-#{kind}-#{Time.now.to_i}-#{SecureRandom.hex(4)}"
    end

    def snapshot_datasets(log, snap)
      zfs(:snapshot, nil, log.opts.datasets.map { |ds| "#{ds.source}@#{snap}" }.join(' '))
    end

    def transfer_dataset(pair, snapshot, from_snapshot: nil)
      src = OsCtl::Lib::Zfs::Dataset.new(pair.source, base: pair.source)
      dst = OsCtl::Lib::Zfs::Dataset.new(pair.target, base: pair.target)

      progress("Copying dataset #{pair.relative_name}")

      stream = OsCtl::Lib::Zfs::Stream.new(
        src,
        snapshot,
        from_snapshot,
        intermediary: false
      )

      stream.progress do |total, _transfered, changed|
        progress(type: :progress, data: {
          time: Time.now.to_i,
          size: stream.size,
          transfered: total,
          changed:
        })
      end

      stream.send_recv(dst.name)
    end

    def force_writeout(ct)
      return unless Daemon.get.config.writeout_dirtied_pages?

      begin
        ct.unmount(force: true)
      rescue SystemCommandFailed => e
        log(:warn, ct, "Unable to unmount dataset for writeback: #{e.message}")
        ct.mount(force: true)
      end
    end

    def clear_failed_state_snapshot(ct, log)
      snap = log.state_snapshot
      return if snap.nil?

      progress("Removing failed cutover snapshot #{snap}")

      log.opts.datasets.each do |pair|
        zfs(:destroy, nil, "#{pair.source}@#{snap}", valid_rcs: [1])
        zfs(:destroy, nil, "#{pair.target}@#{snap}", valid_rcs: [1])
      end

      ct.exclusively do
        ct.local_transfer_log.state_snapshot = nil
        ct.save_config
      end
    end

    def destroy_local_transfer_snapshots(log)
      snaps = log.snapshots.dup
      snaps << log.state_snapshot if log.state_snapshot

      log.opts.datasets.each do |pair|
        snaps.reverse_each do |snap|
          zfs(:destroy, nil, "#{pair.source}@#{snap}", valid_rcs: [1])
          zfs(:destroy, nil, "#{pair.target}@#{snap}", valid_rcs: [1])
        end
      end
    end

    def cleanup_target_container!(log)
      target = begin
        target_ct(log)
      rescue CommandFailed
        nil
      end
      return unless target

      builder = Container::Builder.new(target.new_run_conf, cmd: self)
      builder.cleanup(dataset: !log.opts.target_dataset_custom)
    end
  end
end
