require 'osctld/dist_config/redhat'

module OsCtld
  class DistConfig::CentOS < DistConfig::RedHat
    distribution :centos

    protected
    def template_dir
      if version.to_i >= 8
        'redhat_nm'
      else
        'redhat_initscripts'
      end
    end
  end
end
