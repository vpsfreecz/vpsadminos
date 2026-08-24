require 'libosctl'
require 'osctl/exporter/collectors/base'
require 'osctl/cli'
require 'osctl/cli/cgroup_params'

module OsCtl::Exporter
  class Collectors::Container < Collectors::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Cli::CGroupParams

    CONFIG_STATES = %i[
      staged
      ready
      error
    ].freeze

    RUNTIME_STATES = %i[
      unknown
      stopped
      starting
      running
      stopping
      freezing
      frozen
      thawed
      aborting
    ].freeze

    DATASET_PROPERTY_METRICS = [
      {
        property: 'used',
        variable_name: :dataset_used,
        metric_name: :osctl_container_dataset_used_bytes,
        docstring: 'Dataset used space',
        value_type: :integer
      },
      {
        property: 'referenced',
        variable_name: :dataset_referenced,
        metric_name: :osctl_container_dataset_referenced_bytes,
        docstring: 'Dataset referenced space',
        value_type: :integer
      },
      {
        property: 'available',
        variable_name: :dataset_avail,
        metric_name: :osctl_container_dataset_avail_bytes,
        docstring: 'Dataset available space',
        value_type: :integer
      },
      {
        property: 'quota',
        variable_name: :dataset_quota,
        metric_name: :osctl_container_dataset_quota_bytes,
        docstring: 'Dataset quota',
        value_type: :integer
      },
      {
        property: 'refquota',
        variable_name: :dataset_refquota,
        metric_name: :osctl_container_dataset_refquota_bytes,
        docstring: 'Dataset reference quota',
        value_type: :integer
      },
      {
        property: 'reservation',
        variable_name: :dataset_reservation,
        metric_name: :osctl_container_dataset_reservation_bytes,
        docstring: 'Dataset reservation',
        value_type: :integer
      },
      {
        property: 'refreservation',
        variable_name: :dataset_refreservation,
        metric_name: :osctl_container_dataset_refreservation_bytes,
        docstring: 'Dataset reference reservation',
        value_type: :integer
      },
      {
        property: 'logicalused',
        variable_name: :dataset_logical_used,
        metric_name: :osctl_container_dataset_logical_used_bytes,
        docstring: 'Dataset logical used space',
        value_type: :integer
      },
      {
        property: 'logicalreferenced',
        variable_name: :dataset_logical_referenced,
        metric_name: :osctl_container_dataset_logical_referenced_bytes,
        docstring: 'Dataset logical referenced space',
        value_type: :integer
      },
      {
        property: 'usedbydataset',
        variable_name: :dataset_used_by_dataset,
        metric_name: :osctl_container_dataset_used_by_dataset_bytes,
        docstring: 'Dataset space used by the dataset itself',
        value_type: :integer
      },
      {
        property: 'usedbychildren',
        variable_name: :dataset_used_by_children,
        metric_name: :osctl_container_dataset_used_by_children_bytes,
        docstring: 'Dataset space used by child datasets',
        value_type: :integer
      },
      {
        property: 'usedbysnapshots',
        variable_name: :dataset_used_by_snapshots,
        metric_name: :osctl_container_dataset_used_by_snapshots_bytes,
        docstring: 'Dataset space used by snapshots',
        value_type: :integer
      },
      {
        property: 'usedbyrefreservation',
        variable_name: :dataset_used_by_refreservation,
        metric_name: :osctl_container_dataset_used_by_refreservation_bytes,
        docstring: 'Dataset space used by the reference reservation',
        value_type: :integer
      },
      {
        property: 'written',
        variable_name: :dataset_written,
        metric_name: :osctl_container_dataset_written_bytes,
        docstring: 'Dataset space written since the previous snapshot',
        value_type: :integer
      },
      {
        property: 'compressratio',
        variable_name: :dataset_compressratio,
        metric_name: :osctl_container_dataset_compressratio,
        docstring: 'Compression ratio achieved for the dataset used space',
        value_type: :ratio
      },
      {
        property: 'refcompressratio',
        variable_name: :dataset_refcompressratio,
        metric_name: :osctl_container_dataset_refcompressratio,
        docstring: 'Compression ratio achieved for the dataset referenced space',
        value_type: :ratio
      }
    ].freeze

    def setup
      @mutex = Mutex.new
      @last_container_data = nil

      add_metric(
        :config_state,
        :gauge,
        :osctl_container_config_state,
        docstring: 'Container configuration state',
        labels: %i[pool id state]
      )

      add_metric(
        :runtime_state,
        :gauge,
        :osctl_container_runtime_state,
        docstring: 'Container runtime state',
        labels: %i[pool id state]
      )

      add_metric(
        :memory_used_bytes,
        :gauge,
        :osctl_container_memory_used_bytes,
        docstring: 'Memory used by containers',
        labels: %i[pool id]
      )
      add_metric(
        :cpu_us_total,
        :gauge,
        :osctl_container_cpu_microseconds_total,
        docstring: 'Container CPU usage',
        labels: %i[pool id mode]
      )
      add_metric(
        :proc_pids,
        :gauge,
        :osctl_container_processes_pids,
        docstring: 'Number of processes inside the container',
        labels: %i[pool id]
      )
      add_metric(
        :proc_state,
        :gauge,
        :osctl_container_processes_state,
        docstring: 'Number of processes belonging to a container by their state',
        labels: %i[pool id state]
      )

      [1, 5, 15].each do |i|
        add_metric(
          "loadavg_#{i}",
          :gauge,
          :"osctl_container_load#{i}",
          docstring: "Container #{i} minute load average",
          labels: %i[pool id]
        )
      end

      DATASET_PROPERTY_METRICS.each do |cfg|
        add_metric(
          cfg[:variable_name],
          :gauge,
          cfg[:metric_name],
          docstring: cfg[:docstring],
          labels: %i[pool id dataset relative_name]
        )
      end
      add_metric(
        :dataset_bytes_written,
        :gauge,
        :osctl_container_dataset_bytes_written,
        docstring: 'Bytes written to this dataset',
        labels: %i[pool id dataset relative_name]
      )
      add_metric(
        :dataset_bytes_read,
        :gauge,
        :osctl_container_dataset_bytes_read,
        docstring: 'Bytes read from this dataset',
        labels: %i[pool id dataset relative_name]
      )
      add_metric(
        :dataset_ios_written,
        :gauge,
        :osctl_container_dataset_ios_written,
        docstring: 'Number of write IOs of this dataset',
        labels: %i[pool id dataset relative_name]
      )
      add_metric(
        :dataset_ios_read,
        :gauge,
        :osctl_container_dataset_ios_read,
        docstring: 'Number of read IOs of this dataset',
        labels: %i[pool id dataset relative_name]
      )
      add_metric(
        :netif_rx_bytes,
        :gauge,
        :osctl_container_network_receive_bytes_total,
        docstring: 'Number of received bytes over network',
        labels: %i[pool id devicetype hostdevice ctdevice]
      )
      add_metric(
        :netif_tx_bytes,
        :gauge,
        :osctl_container_network_transmit_bytes_total,
        docstring: 'Number of transmitted bytes over network',
        labels: %i[pool id devicetype hostdevice ctdevice]
      )
      add_metric(
        :netif_rx_packets,
        :gauge,
        :osctl_container_network_receive_packets_total,
        docstring: 'Number of received packets over network',
        labels: %i[pool id devicetype hostdevice ctdevice]
      )
      add_metric(
        :netif_tx_packets,
        :gauge,
        :osctl_container_network_transmit_packets_total,
        docstring: 'Number of transmitted packets over network',
        labels: %i[pool id devicetype hostdevice ctdevice]
      )
      add_metric(
        :keyring_qnkeys,
        :gauge,
        :osctl_container_keyring_qnkeys,
        docstring: "Number of keyring keys owned by the container's user IDs",
        labels: %i[pool id]
      )
      add_metric(
        :keyring_qnbytes,
        :gauge,
        :osctl_container_keyring_qnbytes,
        docstring: "Number of bytes used by owned keys of the container's user IDs",
        labels: %i[pool id]
      )
      add_metric(
        :nf_conntrack_entries,
        :gauge,
        :osctl_container_nf_conntrack_entries,
        docstring: "Number of conntrack entries in the container's netns",
        labels: %i[pool id]
      )
      add_metric(
        :nf_conntrack_entries_limit,
        :gauge,
        :osctl_container_nf_conntrack_limit,
        docstring: "Maximum number of conntrack entries in the container's netns",
        labels: %i[pool id]
      )
    end

    def collect(client)
      cg_init_subsystems(client.client)
      cts = client.list_containers
      pools = container_pools(cts)
      netifs = client.list_netifs.reject { |v| v[:veth].nil? }

      cg_add_stats(
        cts,
        ->(ct) { ct[:group_path] },
        %i[memory cpu_us nproc],
        true
      )

      @mutex.synchronize { @last_container_data = cts }

      lavgs = OsCtl::Lib::LoadAvgReader.read_for(cts)
      objsets = OsCtl::Lib::Zfs::ObjsetStats.read_pools(pools)
      propreader = OsCtl::Lib::Zfs::PropertyReader.new
      keyring = OsCtl::Lib::KernelKeyring.new

      begin
        tree = propreader.read(
          cts.map { |ct| ct[:dataset] },
          DATASET_PROPERTY_METRICS.map { |cfg| cfg[:property].to_sym },
          recursive: true
        )
      rescue OsCtl::Lib::Exceptions::SystemCommandFailed => e
        log(:warn, "Unable to read dataset properties: exit status #{e.rc}, output: #{e.output.inspect}")
        return
      end

      netif_stats = OsCtl::Lib::NetifStats.new
      netif_stats.cache_stats_for_interfaces(netifs.map { |v| v[:veth] })

      pool_ct_procs = parse_processes

      cts.each do |ct|
        CONFIG_STATES.each do |state|
          config_state.set(
            state == ct[:config_state].to_sym ? 1 : 0,
            labels: { pool: ct[:pool], id: ct[:id], state: }
          )
        end
        RUNTIME_STATES.each do |state|
          runtime_state.set(
            state == ct[:runtime_state].to_sym ? 1 : 0,
            labels: { pool: ct[:pool], id: ct[:id], state: }
          )
        end
        memory_used_bytes.set(
          ct[:memory].nil? ? 0 : ct[:memory].raw,
          labels: { pool: ct[:pool], id: ct[:id] }
        )
        cpu_us_total.set(
          ct[:cpu_user_us].nil? ? 0 : ct[:cpu_user_us].raw,
          labels: { pool: ct[:pool], id: ct[:id], mode: 'user' }
        )
        cpu_us_total.set(
          ct[:cpu_system_us].nil? ? 0 : ct[:cpu_system_us].raw,
          labels: { pool: ct[:pool], id: ct[:id], mode: 'system' }
        )
        proc_pids.set(
          ct[:nproc].nil? ? 0 : ct[:nproc],
          labels: { pool: ct[:pool], id: ct[:id] }
        )

        pool_ct_procs.fetch(ct[:pool], {}).fetch(ct[:id], {}).each do |state, cnt|
          proc_state.set(cnt, labels: { pool: ct[:pool], id: ct[:id], state: })
        end

        lavg = lavgs["#{ct[:pool]}:#{ct[:id]}"]

        if lavg
          [1, 5, 15].each do |i|
            metrics["loadavg_#{i}"].set(
              lavg.avg[i],
              labels: { pool: ct[:pool], id: ct[:id] }
            )
          end
        end

        tree[ct[:dataset]].each_tree_dataset do |tr_ds|
          ds = tr_ds.as_dataset(base: ct[:dataset])
          labels = dataset_labels(ct, ds)

          DATASET_PROPERTY_METRICS.each do |cfg|
            metrics[cfg[:variable_name]].set(
              parse_dataset_property_value(
                tr_ds.properties[cfg[:property]],
                cfg[:value_type]
              ),
              labels:
            )
          end

          objset = objsets[ds.name]

          next unless objset

          dataset_bytes_written.set(
            objset.write_bytes,
            labels:
          )
          dataset_bytes_read.set(
            objset.read_bytes,
            labels:
          )
          dataset_ios_written.set(
            objset.write_ios,
            labels:
          )
          dataset_ios_read.set(
            objset.read_ios,
            labels:
          )
        end

        extract_container_netifs(ct, netifs).each do |netif|
          st = netif_stats[netif[:veth]]
          next if st.nil?

          netif_rx_bytes.set(
            st[:tx][:bytes],
            labels: netif_labels(ct, netif)
          )
          netif_tx_bytes.set(
            st[:rx][:bytes],
            labels: netif_labels(ct, netif)
          )
          netif_rx_packets.set(
            st[:tx][:packets],
            labels: netif_labels(ct, netif)
          )
          netif_tx_packets.set(
            st[:rx][:packets],
            labels: netif_labels(ct, netif)
          )
        end

        uid_map = OsCtl::Lib::IdMap.from_hash_list(ct[:uid_map])
        key_users = keyring.for_id_map(uid_map)

        keyring_qnkeys.set(
          key_users.inject(0) { |acc, ku| acc + ku.qnkeys },
          labels: { pool: ct[:pool], id: ct[:id] }
        )
        keyring_qnbytes.set(
          key_users.inject(0) { |acc, ku| acc + ku.qnbytes },
          labels: { pool: ct[:pool], id: ct[:id] }
        )

        next if ct[:runtime_state] != 'running' || !ct[:init_pid]

        read_from_container_netns(ct)
      end
    end

    def get_last_container_data
      @mutex.synchronize { @last_container_data }
    end

    protected

    attr_reader :config_state, :runtime_state,
                :memory_total_bytes, :memory_used_bytes, :cpu_us_total,
                :proc_pids, :proc_state, :dataset_used, :dataset_referenced,
                :dataset_avail, :dataset_quota, :dataset_refquota, :dataset_bytes_written,
                :dataset_bytes_read, :dataset_ios_written, :dataset_ios_read,
                :netif_rx_bytes, :netif_tx_bytes, :netif_rx_packets, :netif_tx_packets,
                :keyring_qnkeys, :keyring_qnbytes, :nf_conntrack_entries, :nf_conntrack_entries_limit

    def dataset_labels(ct, ds)
      {
        pool: ct[:pool],
        id: ct[:id],
        dataset: ds.name,
        relative_name: ds.relative_name
      }
    end

    def netif_labels(ct, netif)
      {
        pool: ct[:pool],
        id: ct[:id],
        devicetype: netif[:type],
        hostdevice: netif[:veth],
        ctdevice: netif[:name]
      }
    end

    def parse_dataset_property_value(value, value_type)
      case value_type
      when :ratio
        parse_dataset_ratio(value)
      else
        value.nil? ? 0 : value.to_i
      end
    end

    def parse_dataset_ratio(value)
      return 0 if value.nil? || value.empty? || value == '-' || value == 'none'

      value.delete_suffix('x').to_f
    end

    def container_pools(cts)
      pools = []

      cts.each do |ct|
        pools << ct[:pool] unless pools.include?(ct[:pool])
      end

      pools
    end

    def extract_container_netifs(ct, netif_list)
      ret = []

      netif_list.delete_if do |netif|
        if netif[:pool] == ct[:pool] && netif[:ctid] == ct[:id]
          ret << netif
          true
        else
          false
        end
      end

      ret
    end

    def read_from_container_netns(ct)
      r, w = IO.pipe

      pid = Process.fork do
        r.close
        reset_child_process(w.fileno)

        begin
          sys = OsCtl::Lib::Sys.new
          sys.setns_path(File.join('/proc', ct[:init_pid].to_s, 'ns/net'), OsCtl::Lib::Sys::CLONE_NEWNET)

          w.puts({
            'nf_conntrack_count' => File.read('/proc/sys/net/netfilter/nf_conntrack_count').strip.to_i,
            'nf_conntrack_max' => File.read('/proc/sys/net/netfilter/nf_conntrack_max').strip.to_i
          }.to_json)
        rescue StandardError
          exit!(1)
        else
          exit!(0)
        ensure
          w.close unless w.closed?
        end
      end

      w.close

      data = r.read
      r.close
      Process.wait(pid)

      if $?.exitstatus != 0
        log(:warn, "Failed to read from netns of #{ct[:pool]}:#{ct[:id]}, exited with #{$?.exitstatus}")
        return
      end

      begin
        parsed = JSON.parse(data)
      rescue TypeError, JSON::ParserError => e
        log(:warn, "Failed to parse JSON from netns of #{ct[:pool]}:#{ct[:id]}: #{e.message}")
        return
      end

      nf_conntrack_entries.set(parsed['nf_conntrack_count'], labels: { pool: ct[:pool], id: ct[:id] })
      nf_conntrack_entries_limit.set(parsed['nf_conntrack_max'], labels: { pool: ct[:pool], id: ct[:id] })
    end

    def reset_child_process(result_fd)
      reset_child_signals
      close_inherited_fds([0, 1, 2, result_fd])
    end

    def reset_child_signals
      %w[HUP INT TERM].each do |sig|
        Signal.trap(sig, 'DEFAULT')
      rescue ArgumentError
        # Signal not available on this platform
      end
    end

    def close_inherited_fds(keep)
      Dir.children('/proc/self/fd').each do |fd|
        fd = fd.to_i
        next if keep.include?(fd)

        IO.new(fd).close
      rescue ArgumentError, Errno::EBADF, Errno::ENOENT, IOError
        # Already closed or raced with /proc/self/fd
      end
    end

    def parse_processes
      pool_ct_procs = {}

      OsCtl::Lib::ProcessList.each(parse_status: false) do |p|
        pool, ct = p.ct_id
        next if ct.nil?

        pool_ct_procs[pool] ||= {}
        pool_ct_procs[pool][ct] ||= {
          'R' => 0,
          'S' => 0,
          'D' => 0,
          'Z' => 0,
          'T' => 0,
          't' => 0,
          'X' => 0
        }

        pool_ct = pool_ct_procs[pool][ct]
        pool_ct[p.state] += 1 if pool_ct.has_key?(p.state)
      end

      pool_ct_procs
    end
  end
end
