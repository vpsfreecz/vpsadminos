module OsCtld
  class DistConfig::Debian < DistConfig::Base
    distribution :debian

    def network(_opts)
      OsCtld::Template.render_to(
        'dist_config/network/debian/interfaces',
        {netifs: ct.netifs},
        File.join(ct.rootfs, 'etc', 'network', 'interfaces')
      )
    end
  end
end
