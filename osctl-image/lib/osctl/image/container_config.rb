module OsCtl::Image
  class ContainerConfig
    attr_accessor :distribution, :version, :arch, :dataset, :rootfs

    def id ; nil ; end
    def user ; nil ; end
    def group ; nil ; end

    def datasets
      [dataset] + dataset.descendants
    end

    def dump_config
      {
        'distribution' => distribution,
        'version' => version,
        'arch' => arch,
      }
    end
  end
end
