require 'libosctl'
require 'osctl/exporter/collectors/base'
require 'osctl/exportfs'

module OsCtl::Exporter
  class Collectors::Exportfs < Collectors::Base
    def setup
      @server_count = registry.gauge(
        :osctl_exportfs_server_count,
        docstring: 'Number of osctl-exportfs servers',
        labels: [:state],
      )

      @netif_rx_bytes = registry.gauge(
        :osctl_exportfs_server_receive_bytes_total,
        docstring: 'Number of received bytes over network',
        labels: [:nfs_server, :hostdevice, :ip_address],
      )
      @netif_tx_bytes = registry.gauge(
        :osctl_exportfs_server_transmit_bytes_total,
        docstring: 'Number of transmitted bytes over network',
        labels: [:nfs_server, :hostdevice, :ip_address],
      )
      @netif_rx_packets = registry.gauge(
        :osctl_exportfs_server_receive_packets_total,
        docstring: 'Number of received packets over network',
        labels: [:nfs_server, :hostdevice, :ip_address],
      )
      @netif_tx_packets = registry.gauge(
        :osctl_exportfs_server_transmit_packets_total,
        docstring: 'Number of transmitted packets over network',
        labels: [:nfs_server, :hostdevice, :ip_address],
      )
    end

    def collect(client)
      servers = OsCtl::ExportFS::Operations::Server::List.run
      netif_stats = OsCtl::Lib::NetifStats.new
      running = 0
      stopped = 0

      servers.each do |s|
        cfg = s.open_config

        if s.running?
          running += 1

          st = netif_stats.get_stats_for(cfg.netif)

          @netif_rx_bytes.set(
            st[:tx][:bytes],
            labels: netif_labels(s, cfg),
          )
          @netif_tx_bytes.set(
            st[:rx][:bytes],
            labels: netif_labels(s, cfg),
          )
          @netif_rx_packets.set(
            st[:tx][:packets],
            labels: netif_labels(s, cfg),
          )
          @netif_tx_packets.set(
            st[:rx][:packets],
            labels: netif_labels(s, cfg),
          )
        else
          stopped += 1
        end
      end

      @server_count.set(running, labels: {state: :running})
      @server_count.set(stopped, labels: {state: :stopped})
    end

    protected
    def netif_labels(server, cfg)
      {nfs_server: server.name, hostdevice: cfg.netif, ip_address: cfg.address}
    end
  end
end
