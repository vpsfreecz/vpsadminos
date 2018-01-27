require 'yaml'
require 'rubygems'
require 'rubygems/package'

module OsCtld
  class Commands::Container::Export < Commands::Logged
    handle :ct_export

    DIR_MODE = 16877 # 0755
    FILE_MODE = 33188 # 0644

    include Utils::Log
    include Utils::System
    include Utils::Zfs

    def find
      ct = DB::Containers.find(opts[:id], opts[:pool])
      ct || error!('container not found')
    end

    def execute(ct)
      ct.exclusively do
        File.open(opts[:file], 'w') do |f|
          export(ct, f)
        end

        ok
      end
    end

    protected
    def export(ct, io)
      Gem::Package::TarWriter.new(io) do |tar|
        tar.add_file('metadata.yml', FILE_MODE) do |tf|
          tf.write(YAML.dump(
            'type' => 'full',
            'user' => ct.user.name,
            'group' => ct.group.name,
            'container' => ct.id,
            'exported_at' => Time.now.to_i,
          ))
        end

        tar.mkdir('config', DIR_MODE)
        tar.add_file('config/user.yml', FILE_MODE) do |tf|
          tf.write(File.read(ct.user.config_path))
        end
        tar.add_file('config/group.yml', FILE_MODE) do |tf|
          tf.write(File.read(ct.group.config_path))
        end
        tar.add_file('config/container.yml', FILE_MODE) do |tf|
          tf.write(File.read(ct.config_path))
        end

        tar.mkdir('rootfs', DIR_MODE)
        snap1_name, snap1 = snapshot_name(ct, 'base')
        snap2_name, snap2 = nil

        zfs(:snapshot, '', snap1)

        tar.add_file('rootfs/base.dat', FILE_MODE) do |tf|
          IO.popen("exec zfs send #{snap1}") do |io|
            tf.write(io.read(4096)) until io.eof?
          end
        end

        if ct.state == :running && opts[:consistent]
          call_cmd(Commands::Container::Stop, id: ct.id, pool: ct.pool.name)

          snap2_name, snap2 = snapshot_name(ct, 'incr')
          zfs(:snapshot, '', snap2)

          tar.add_file('rootfs/incremental.dat', FILE_MODE) do |tf|
            IO.popen("exec zfs send -I #{snap1} #{snap2}") do |io|
              tf.write(io.read(4096)) until io.eof?
            end
          end

          call_cmd(
            Commands::Container::Start,
            id: ct.id,
            pool: ct.pool.name,
            force: true
          )
          zfs(:destroy, '', snap2)
        end

        zfs(:destroy, '', snap1)

        tar.add_file('snapshots.yml', FILE_MODE) do |tf|
          tf.write(YAML.dump([snap1_name, snap2_name].compact))
        end
      end
    end

    def snapshot_name(ct, type)
      name = "osctl-#{type}-#{Time.now.to_i}"
      [name, "#{ct.dataset}@#{name}"]
    end
  end
end
