require 'osctl/exporter/collectors/base'
require 'libosctl'

module OsCtl::Exporter
  class Collectors::ZpoolStatus < Collectors::Base
    include OsCtl::Lib::Utils::Log

    POOL_STATES = %i(online degraded suspended faulted)

    SCAN_TYPES = %i(none scrub resilver)

    VDEV_STATES = %i(degraded faulted offline online removed avail unavail)

    def setup
      @zpool_status_success = registry.gauge(
        :zpool_status_success,
        docstring: 'Process exit code',
      )
      @zpool_status_parse_success = registry.gauge(
        :zpool_status_parse_success,
        docstring: 'Parsing successful',
      )

      POOL_STATES.each do |state|
        add_metric(
          "zpool_status_state_#{state}",
          :gauge,
          :"zpool_status_state_#{state}",
          docstring: "Set if pool is in state #{state}",
          labels: [:pool],
        )
      end

      SCAN_TYPES.each do |scan|
        add_metric(
          "zpool_status_scan_#{scan}",
          :gauge,
          :"zpool_status_scan_#{scan}",
          docstring: "Set if pool scan is #{scan}",
          labels: [:pool],
        )
      end

      add_metric(
        :zpool_status_scan_percent,
        :gauge,
        :zpool_status_scan_percent,
        docstring: 'Pool scan percent',
        labels: [:pool, :scan],
      )

      VDEV_STATES.each do |state|
        add_metric(
          "zpool_status_vdev_state_#{state}",
          :gauge,
          :"zpool_status_vdev_state_#{state}",
          docstring: "Set if virtual device state is #{state}",
          labels: [:pool, :vdev_name, :vdev_role, :vdev_type],
        )
      end

      add_metric(
        :zpool_status_vdev_read_errors,
        :gauge,
        :zpool_status_vdev_read_errors,
        docstring: 'Number of read errors of a pool virtual device',
        labels: [:pool, :vdev_name, :vdev_role, :vdev_type, :vdev_state],
      )
      add_metric(
        :zpool_status_vdev_write_errors,
        :gauge,
        :zpool_status_vdev_write_errors,
        docstring: 'Number of write errors of a pool virtual device',
        labels: [:pool, :vdev_name, :vdev_role, :vdev_type, :vdev_state],
      )
      add_metric(
        :zpool_status_vdev_checksum_errors,
        :gauge,
        :zpool_status_vdev_checksum_errors,
        docstring: 'Number of checksum errors of a pool virtual device',
        labels: [:pool, :vdev_name, :vdev_role, :vdev_type, :vdev_state],
      )
    end

    def collect(client)
      begin
        st = OsCtl::Lib::Zfs::ZpoolStatus.new
      rescue => e
        log(:warn, "Failed to parse zpool status: #{e.message} (#{e.class})")
      end

      if st.nil?
        @zpool_status_success.set(0)
        return
      end

      @zpool_status_success.set(1)
      @zpool_status_parse_success.set(1)

      st.pools.each do |pool|
        POOL_STATES.each do |state|
          metrics["zpool_status_state_#{state}"].set(
            pool.state == state ? 1 : 0,
            labels: {pool: pool.name},
          )
        end

        SCAN_TYPES.each do |scan|
          metrics["zpool_status_scan_#{scan}"].set(
            pool.scan == scan ? 1 : 0,
            labels: {pool: pool.name},
          )

          @zpool_status_scan_percent.set(
            pool.scan == scan ? pool.scan_percent || 0 : 0,
            labels: {pool: pool.name, scan: scan},
          )
        end

        add_vdevs(pool, pool)
      end
    end

    protected
    def add_vdevs(pool, root)
      root.virtual_devices.each do |vdev|
        labels = vdev_labels(pool, vdev)
        labels.delete(:vdev_state)
        VDEV_STATES.each do |state|

          metrics["zpool_status_vdev_state_#{state}"].set(
            vdev.state == state ? 1 : 0,
            labels: labels,
          )
        end

        labels = vdev_labels(pool, vdev)
        @zpool_status_vdev_read_errors.set(vdev.read, labels: labels))
        @zpool_status_vdev_write_errors.set(vdev.write, labels: labels)
        @zpool_status_vdev_checksum_errors.set(vdev.checksum, labels: labels)

        add_vdevs(pool, vdev)
      end
    end

    def vdev_labels(pool, vdev)
      {
        pool: pool.name,
        vdev_name: vdev.name,
        vdev_role: vdev.role,
        vdev_type: vdev.type,
        vdev_state: vdev.state,
      }
    end
  end
end
