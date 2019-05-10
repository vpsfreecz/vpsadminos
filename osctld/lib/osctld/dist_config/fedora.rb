require 'osctld/dist_config/redhat'

module OsCtld
  class DistConfig::Fedora < DistConfig::RedHat
    distribution :fedora

    protected
    def template_dir
      if version.to_i >= 30
        'redhat_nm'
      else
        'redhat_initscripts'
      end
    end
  end
end
