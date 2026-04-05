require 'vpsadminos-converter/vz6/migrator/simfs'

module VpsAdminOS::Converter
  class Vz6::Migrator::Ploop < Vz6::Migrator::Simfs
    def sync
      mounted = false

      unless vz_ct.status[:mounted]
        mounted = true
        syscmd("vzctl mount #{vz_ct.ctid}")
      end

      super
    ensure
      syscmd("vzctl umount #{vz_ct.ctid}") if mounted
    end

    def transfer(&block)
      self.progress_handler = block
      mounted = false

      # Stop the container
      running = vz_ct.running?
      syscmd("vzctl stop #{vz_ct.ctid}")
      syscmd("vzctl mount #{vz_ct.ctid}")
      mounted = true

      # Second sync
      do_sync

      # Transfer to dst
      transfer_container(running)
    ensure
      syscmd("vzctl umount #{vz_ct.ctid}") if mounted
    end
  end
end
