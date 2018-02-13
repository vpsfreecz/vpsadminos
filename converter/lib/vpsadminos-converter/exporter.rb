module VpsAdminOS::Converter
  class Exporter < OsCtl::Lib::Exporter
    def dump_configs
      tar.mkdir('config', DIR_MODE)
      tar.add_file('config/user.yml', FILE_MODE) do |tf|
        tf.write(YAML.dump(ct.user.dump_config))
      end
      tar.add_file('config/group.yml', FILE_MODE) do |tf|
        tf.write(YAML.dump(ct.group.dump_config))
      end
      tar.add_file('config/container.yml', FILE_MODE) do |tf|
        tf.write(YAML.dump(ct.dump_config))
      end
    end
  end
end
