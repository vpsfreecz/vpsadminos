module VpsAdminOS::Converter
  class Vz6::Migrator::Ploop < Vz6::Migrator::Simfs
    def sync
      mounted = false

      unless vz_ct.status[:mounted]
        mounted = true
        syscmd("vzctl mount #{vz_ct.ctid}")
      end

      super

      syscmd("vzctl umount #{vz_ct.ctid}") if mounted
    end

    def transfer(&block)
      self.progress_handler = block

      # Stop the container
      running = vz_ct.running?
      syscmd("vzctl stop #{vz_ct.ctid}")
      syscmd("vzctl mount #{vz_ct.ctid}")

      # Second sync
      do_sync

      # Transfer to dst
      transfer_container(running)
      syscmd("vzctl umount #{vz_ct.ctid}")
    end
  end
end
