require 'libosctl'
require 'osctl/exporter/collectors/base'
require 'osctl/cli'
require 'osctl/cli/cgroup_params'

module OsCtl::Exporter
  class Collectors::Container < Collectors::Base
    include OsCtl::Lib::Utils::Log
    include OsCtl::Cli::CGroupParams

    STATES = %i(
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
    )

    def setup
      @states = Hash[STATES.map do |s|
        [
          s,
          registry.gauge(
            :"osctl_container_state_#{s}",
            docstring: "Set if the container is in state #{s}",
            labels: [:pool, :id],
          )
        ]
      end]
      @memory_used_bytes = registry.gauge(
        :osctl_container_memory_used_bytes,
        docstring: 'Memory used by containers',
        labels: [:pool, :id],
      )
      @cpu_us_total = registry.gauge(
        :osctl_container_cpu_microseconds_total,
        docstring: 'Container CPU usage',
        labels: [:pool, :id, :mode],
      )
      @proc_pids = registry.gauge(
        :osctl_container_processes_pids,
        docstring: 'Number of processes inside the container',
        labels: [:pool, :id],
      )
      @loadavg = Hash[[1, 5, 15].map do |i|
        [
          i,
          registry.gauge(
            :"osctl_container_load#{i}",
            docstring: "Container #{i} minute load average",
            labels: [:pool, :id],
          ),
        ]
      end]
      @dataset_used = registry.gauge(
        :osctl_container_dataset_used_bytes,
        docstring: 'Dataset used space',
        labels: [:pool, :id, :dataset, :relative_name],
      )
      @dataset_referenced = registry.gauge(
        :osctl_container_dataset_referenced_bytes,
        docstring: 'Dataset referenced space',
        labels: [:pool, :id, :dataset, :relative_name],
      )
      @dataset_avail = registry.gauge(
        :osctl_container_dataset_avail_bytes,
        docstring: 'Dataset available space',
        labels: [:pool, :id, :dataset, :relative_name],
      )
      @dataset_quota = registry.gauge(
        :osctl_container_dataset_quota_bytes,
        docstring: 'Dataset quota',
        labels: [:pool, :id, :dataset, :relative_name],
      )
      @dataset_refquota = registry.gauge(
        :osctl_container_dataset_refquota_bytes,
        docstring: 'Dataset reference quota',
        labels: [:pool, :id, :dataset, :relative_name],
      )
      @dataset_bytes_written = registry.gauge(
        :osctl_container_dataset_bytes_written,
        docstring: 'Bytes written to this dataset',
        labels: [:pool, :id, :dataset, :relative_name],
      )
      @dataset_bytes_read = registry.gauge(
        :osctl_container_dataset_bytes_read,
        docstring: 'Bytes read from this dataset',
        labels: [:pool, :id, :dataset, :relative_name],
      )
      @dataset_ios_written = registry.gauge(
        :osctl_container_dataset_ios_written,
        docstring: 'Number of write IOs of this dataset',
        labels: [:pool, :id, :dataset, :relative_name],
      )
      @dataset_ios_read = registry.gauge(
        :osctl_container_dataset_ios_read,
        docstring: 'Number of read IOs of this dataset',
        labels: [:pool, :id, :dataset, :relative_name],
      )
      @netif_rx_bytes = registry.gauge(
        :osctl_container_network_receive_bytes_total,
        docstring: 'Number of received bytes over network',
        labels: [:pool, :id, :devicetype, :hostdevice, :ctdevice],
      )
      @netif_tx_bytes = registry.gauge(
        :osctl_container_network_transmit_bytes_total,
        docstring: 'Number of transmitted bytes over network',
        labels: [:pool, :id, :devicetype, :hostdevice, :ctdevice],
      )
      @netif_rx_packets = registry.gauge(
        :osctl_container_network_receive_packets_total,
        docstring: 'Number of received packets over network',
        labels: [:pool, :id, :devicetype, :hostdevice, :ctdevice],
      )
      @netif_tx_packets = registry.gauge(
        :osctl_container_network_transmit_packets_total,
        docstring: 'Number of transmitted packets over network',
        labels: [:pool, :id, :devicetype, :hostdevice, :ctdevice],
      )
    end

    def collect(client)
      cg_init_subsystems(client.client)
      cts = client.list_containers
      pools = container_pools(cts)
      netifs = client.list_netifs.reject { |v| v[:veth].nil? }

      cg_add_stats(
        cts,
        lambda { |ct| ct[:group_path] },
        [:memory, :cpu_us, :nproc],
        true
      )

      lavgs = OsCtl::Lib::LoadAvgReader.read_all_hash
      objsets = OsCtl::Lib::Zfs::ObjsetStats.read_pools(pools)
      propreader = OsCtl::Lib::Zfs::PropertyReader.new

      begin
        tree = propreader.read(
          cts.map { |ct| ct[:dataset] },
          %i(used referenced available quota refquota),
          recursive: true,
        )
      rescue OsCtl::Lib::Exceptions::SystemCommandFailed => e
        log(:warn, "Unable to read dataset properties: exit status #{e.rc}, output: #{e.output.inspect}")
        return
      end

      netif_stats = OsCtl::Lib::NetifStats.new
      netif_stats.cache_stats_for_interfaces(netifs.map { |v| v[:veth] })

      cts.each do |ct|
        STATES.each do |s|
          states[s].set(
            s == ct[:state].to_sym ? 1 : 0,
            labels: {pool: ct[:pool], id: ct[:id]},
          )
        end
        memory_used_bytes.set(
          ct[:memory].nil? ? 0 : ct[:memory].raw,
          labels: {pool: ct[:pool], id: ct[:id]},
        )
        cpu_us_total.set(
          ct[:cpu_user_us].nil? ? 0 : ct[:cpu_user_us].raw,
          labels: {pool: ct[:pool], id: ct[:id], mode: 'user'},
        )
        cpu_us_total.set(
          ct[:cpu_system_us].nil? ? 0 : ct[:cpu_system_us].raw,
          labels: {pool: ct[:pool], id: ct[:id], mode: 'system'},
        )
        proc_pids.set(
          ct[:nproc].nil? ? 0 : ct[:nproc],
          labels: {pool: ct[:pool], id: ct[:id]},
        )

        lavg = lavgs[ "#{ct[:pool]}:#{ct[:id]}" ]

        if lavg
          [1, 5, 15].each do |i|
            loadavg[i].set(
              lavg.avg[i],
              labels: {pool: ct[:pool], id: ct[:id]},
            )
          end
        end

        tree[ct[:dataset]].each_tree_dataset do |tr_ds|
          ds = tr_ds.as_dataset(base: ct[:dataset])

          dataset_used.set(
            tr_ds.properties['used'].to_i,
            labels: dataset_labels(ct, ds),
          )
          dataset_referenced.set(
            tr_ds.properties['referenced'].to_i,
            labels: dataset_labels(ct, ds),
          )
          dataset_avail.set(
            tr_ds.properties['available'].to_i,
            labels: dataset_labels(ct, ds),
          )
          dataset_quota.set(
            tr_ds.properties['quota'].to_i,
            labels: dataset_labels(ct, ds),
          )
          dataset_refquota.set(
            tr_ds.properties['refquota'].to_i,
            labels: dataset_labels(ct, ds),
          )

          objset = objsets[ds.name]

          if objset
            dataset_bytes_written.set(
              objset.write_bytes,
              labels: dataset_labels(ct, ds),
            )
            dataset_bytes_read.set(
              objset.read_bytes,
              labels: dataset_labels(ct, ds),
            )
            dataset_ios_written.set(
              objset.write_ios,
              labels: dataset_labels(ct, ds),
            )
            dataset_ios_read.set(
              objset.read_ios,
              labels: dataset_labels(ct, ds),
            )
          end
        end

        extract_container_netifs(ct, netifs).each do |netif|
          st = netif_stats[netif[:veth]]
          next if st.nil?

          netif_rx_bytes.set(
            st[:tx][:bytes],
            labels: netif_labels(ct, netif),
          )
          netif_tx_bytes.set(
            st[:rx][:bytes],
            labels: netif_labels(ct, netif),
          )
          netif_rx_packets.set(
            st[:tx][:packets],
            labels: netif_labels(ct, netif),
          )
          netif_tx_packets.set(
            st[:rx][:packets],
            labels: netif_labels(ct, netif),
          )
        end
      end
    end

    protected
    attr_reader :states, :memory_total_bytes, :memory_used_bytes, :cpu_us_total,
      :proc_pids, :loadavg, :dataset_used, :dataset_referenced, :dataset_avail,
      :dataset_quota, :dataset_refquota, :dataset_bytes_written,
      :dataset_bytes_read, :dataset_ios_written, :dataset_ios_read,
      :netif_rx_bytes, :netif_tx_bytes, :netif_rx_packets, :netif_tx_packets

    def dataset_labels(ct, ds)
      {
        pool: ct[:pool],
        id: ct[:id],
        dataset: ds.name,
        relative_name: ds.relative_name,
      }
    end

    def netif_labels(ct, netif)
      {
        pool: ct[:pool],
        id: ct[:id],
        devicetype: netif[:type],
        hostdevice: netif[:veth],
        ctdevice: netif[:name],
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
  end
end
