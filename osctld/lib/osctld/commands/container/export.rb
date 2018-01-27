require 'yaml'
require 'rubygems'
require 'rubygems/package'
require 'zlib'

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
        snap1 = snapshot_name('base')
        snap2 = nil

        zfs(:snapshot, '', "#{ct.dataset}@#{snap1}")
        dump_stream(tar, 'base', ct.dataset, snap1)

        if ct.state == :running && opts[:consistent]
          call_cmd(Commands::Container::Stop, id: ct.id, pool: ct.pool.name)

          snap2 = snapshot_name('incr')
          zfs(:snapshot, '', "#{ct.dataset}@#{snap2}")
          dump_stream(tar, 'incremental', ct.dataset, snap2, snap1)

          call_cmd(
            Commands::Container::Start,
            id: ct.id,
            pool: ct.pool.name,
            force: true
          )
          zfs(:destroy, '', "#{ct.dataset}@#{snap2}")
        end

        zfs(:destroy, '', "#{ct.dataset}@#{snap1}")

        tar.add_file('snapshots.yml', FILE_MODE) do |tf|
          tf.write(YAML.dump([snap1, snap2].compact))
        end
      end
    end

    def snapshot_name(type)
      "osctl-#{type}-#{Time.now.to_i}"
    end

    def dump_stream(tar, name, dataset, snap, from_snap = nil)
      compression = get_compression(dataset)

      if from_snap
        cmd = "zfs send -c -I @#{from_snap} #{dataset}@#{snap}"
      else
        cmd = "zfs send -c #{dataset}@#{snap}"
      end

      tar.add_file(dump_file_name(compression, name), FILE_MODE) do |tf|
        IO.popen("exec #{cmd}") do |io|
          process_stream(compression, io, tf)
        end
      end
    end

    def process_stream(compression, stream, tf)
      case compression
      when :gzip
        gz = Zlib::GzipWriter.new(tf)
        gz.write(stream.read(16*1024)) until stream.eof?
        gz.close

      when :off
        tf.write(stream.read(16*1024)) until stream.eof?

      else
        fail "unexpected compression type '#{compression}'"
      end
    end

    def get_compression(dataset)
      case opts[:compression]
      when 'auto'
        if zfs(:get, "-H -o value compression", dataset)[:output].strip == 'off'
          :gzip
        else
          :off
        end

      else
        opts[:compression].to_sym
      end
    end

    def dump_file_name(compression, name)
      base = "rootfs/#{name}.dat"

      case compression
      when :gzip
        "#{base}.gz"

      else
        base
      end
    end
  end
end
