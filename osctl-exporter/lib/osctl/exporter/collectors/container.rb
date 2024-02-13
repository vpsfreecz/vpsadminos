require 'libosctl'
require 'osctl/exporter/collectors/base'
require 'osctl/cli'
require 'osctl/cli/cgroup_params'

module OsCtl::Exporter
  class Collectors::Container < Collectors::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Cli::CGroupParams

    STATES = %i[
      staged
      stopped
      starting
      running
      stopping
      freezing
      frozen
      thawed
      aborting
      error
    ]

    def setup
      @mutex = Mutex.new
      @last_container_data = nil

      STATES.each do |s|
        add_metric(
          "state_#{s}",
          :gauge,
          :"osctl_container_state_#{s}",
          docstring: "Set if the container is in state #{s}",
          labels: %i[pool id]
        )
      end

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

      add_metric(
        :dataset_used,
        :gauge,
        :osctl_container_dataset_used_bytes,
        docstring: 'Dataset used space',
        labels: %i[pool id dataset relative_name]
      )
      add_metric(
        :dataset_referenced,
        :gauge,
        :osctl_container_dataset_referenced_bytes,
        docstring: 'Dataset referenced space',
        labels: %i[pool id dataset relative_name]
      )
      add_metric(
        :dataset_avail,
        :gauge,
        :osctl_container_dataset_avail_bytes,
        docstring: 'Dataset available space',
        labels: %i[pool id dataset relative_name]
      )
      add_metric(
        :dataset_quota,
        :gauge,
        :osctl_container_dataset_quota_bytes,
        docstring: 'Dataset quota',
        labels: %i[pool id dataset relative_name]
      )
      add_metric(
        :dataset_refquota,
        :gauge,
        :osctl_container_dataset_refquota_bytes,
        docstring: 'Dataset reference quota',
        labels: %i[pool id dataset relative_name]
      )
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
          %i[used referenced available quota refquota],
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
        STATES.each do |s|
          metrics["state_#{s}"].set(
            s == ct[:state].to_sym ? 1 : 0,
            labels: { pool: ct[:pool], id: ct[:id] }
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

          dataset_used.set(
            tr_ds.properties['used'].to_i,
            labels: dataset_labels(ct, ds)
          )
          dataset_referenced.set(
            tr_ds.properties['referenced'].to_i,
            labels: dataset_labels(ct, ds)
          )
          dataset_avail.set(
            tr_ds.properties['available'].to_i,
            labels: dataset_labels(ct, ds)
          )
          dataset_quota.set(
            tr_ds.properties['quota'].to_i,
            labels: dataset_labels(ct, ds)
          )
          dataset_refquota.set(
            tr_ds.properties['refquota'].to_i,
            labels: dataset_labels(ct, ds)
          )

          objset = objsets[ds.name]

          next unless objset

          dataset_bytes_written.set(
            objset.write_bytes,
            labels: dataset_labels(ct, ds)
          )
          dataset_bytes_read.set(
            objset.read_bytes,
            labels: dataset_labels(ct, ds)
          )
          dataset_ios_written.set(
            objset.write_ios,
            labels: dataset_labels(ct, ds)
          )
          dataset_ios_read.set(
            objset.read_ios,
            labels: dataset_labels(ct, ds)
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
      end
    end

    def get_last_container_data
      @mutex.synchronize { @last_container_data }
    end

    protected

    attr_reader :memory_total_bytes, :memory_used_bytes, :cpu_us_total,
                :proc_pids, :proc_state, :dataset_used, :dataset_referenced,
                :dataset_avail, :dataset_quota, :dataset_refquota, :dataset_bytes_written,
                :dataset_bytes_read, :dataset_ios_written, :dataset_ios_read,
                :netif_rx_bytes, :netif_tx_bytes, :netif_rx_packets, :netif_tx_packets,
                :keyring_qnkeys, :keyring_qnbytes

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
