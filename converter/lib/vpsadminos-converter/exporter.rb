require 'libosctl'

module VpsAdminOS::Converter
  module Exporter
    module Mixin
      def dump_configs
        tar.mkdir('config', OsCtl::Lib::Exporter::Base::DIR_MODE)
        tar.add_file('config/user.yml', OsCtl::Lib::Exporter::Base::FILE_MODE) do |tf|
          tf.write(OsCtl::Lib::ConfigFile.dump_yaml(ct.user.dump_config))
        end
        tar.add_file('config/group.yml', OsCtl::Lib::Exporter::Base::FILE_MODE) do |tf|
          tf.write(OsCtl::Lib::ConfigFile.dump_yaml(ct.group.dump_config))
        end
        tar.add_file('config/container.yml', OsCtl::Lib::Exporter::Base::FILE_MODE) do |tf|
          tf.write(OsCtl::Lib::ConfigFile.dump_yaml(ct.dump_config))
        end
      end
    end

    class Base < OsCtl::Lib::Exporter::Base
      include Mixin
    end

    class Zfs < OsCtl::Lib::Exporter::Zfs
      include Mixin
    end

    class Tar < OsCtl::Lib::Exporter::Tar
      include Mixin
    end
  end
end
