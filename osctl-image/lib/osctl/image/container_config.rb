module OsCtl::Image
  class ContainerConfig
    attr_accessor :distribution, :version, :arch, :dataset, :rootfs

    def id = nil
    def user = nil
    def group = nil

    def datasets
      [dataset] + dataset.descendants
    end

    def override_with(opts)
      @overrides = opts
    end

    def dump_config
      ret = {
        'distribution' => distribution,
        'version' => version,
        'arch' => arch
      }

      ret.update(@overrides) if @overrides
      ret
    end
  end
end
