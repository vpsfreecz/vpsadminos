require 'libosctl'
require 'yaml'

class RenameMigration
  include OsCtl::Lib::Utils::Log
  include OsCtl::Lib::Utils::System
  include OsCtl::Lib::Utils::File

  def initialize
    @conf_dir = zfs(
      :get,
      '-Hp -o value mountpoint',
      File.join($DATASET, 'conf')
    ).output.strip
    @conf_ct = File.join(conf_dir, 'ct')
  end

  def rename_pool_config(old_name, new_name)
    old_dir = File.join(conf_dir, old_name)
    new_dir = File.join(conf_dir, new_name)

    Dir.mkdir(new_dir, 0o500) unless Dir.exist?(new_dir)

    puts "Moving contents of #{old_dir} to #{new_dir}"
    move_contents(old_dir, new_dir)

    if Dir.empty?(old_dir)
      puts "  removing #{old_dir}"
      Dir.rmdir(old_dir)
    else
      puts "  #{old_dir} not empty"
    end
  end

  def rename_ct_configs(old_key, new_key)
    Dir.glob(File.join(conf_ct, '*.yml')).each do |cfg_path|
      ctid = File.basename(cfg_path)[0..-5]
      puts "CT #{ctid}"

      cfg = YAML.load_file(cfg_path)

      if cfg.has_key?(old_key)
        puts "  renaming #{old_key} to #{new_key}"
        cfg[new_key] = cfg.delete(old_key)

        regenerate_file(cfg_path, 0o400) do |new|
          new.write(YAML.dump(cfg))
        end
      else
        puts '  nothing to do'
      end
    end
  end

  protected

  attr_reader :conf_dir, :conf_ct

  def move_contents(src, dst)
    Dir.entries(src).each do |f|
      next if %w[. ..].include?(f)

      File.rename(File.join(src, f), File.join(dst, f))
    end
  end
end
