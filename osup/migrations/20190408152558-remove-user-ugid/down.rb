require 'libosctl'
require 'yaml'

class Rollback
  User = Struct.new(:name, :config, :opts)

  include OsCtl::Lib::Utils::Log
  include OsCtl::Lib::Utils::System

  attr_reader :migration_dir, :conf_dir, :users, :system_uids, :assigned_ugids,
              :ugid_map

  def initialize
    @migration_dir = File.join(
      zfs(:get, '-Hp -o value mountpoint', File.join($POOL, 'migration')).output.strip,
      $MIGRATION_ID.to_s
    )
    @ugid_map = load_ugid_map
    @conf_dir = zfs(:get, '-Hp -o value mountpoint', File.join($POOL, 'conf')).output.strip
    @users = load_users
    @system_uids = load_passwd
    @assigned_ugids = []
  end

  def run
    last_ugid = 100_000

    users.each do |user|
      ugid, last_ugid = get_ugid(user, last_ugid)
      fail "unable to assign static ugid to user '#{user.name}'" unless ugid

      user.opts.delete('type')
      user.opts['ugid'] = ugid
      File.write(user.config, YAML.dump(user.opts))
    end

    remove_ugid_map
  end

  protected
  def get_ugid(user, start_ugid)
    orig_ugid = ugid_map[user.name]

    if orig_ugid && ugid_usable?(orig_ugid)
      assigned_ugids << orig_ugid
      [orig_ugid, start_ugid]
    else
      ugid = get_free_ugid(start_ugid)
      assigned_ugids << ugid
      [ugid, ugid]
    end
  end

  def get_free_ugid(start_ugid)
    ugid = start_ugid
    max = 2**31 - 2

    loop do
      ugid += 1

      if !ugid_usable?(ugid)
        next
      elsif ugid >= max
        return
      else
        return ugid
      end
    end
  end

  def ugid_usable?(ugid)
    ugid != 65534 && !system_uids.include?(ugid) && !assigned_ugids.include?(ugid)
  end

  def load_ugid_map
    if File.exist?(ugid_map_path)
      YAML.load_file(ugid_map_path)
    else
      {}
    end
  end

  def remove_ugid_map
    File.unlink(ugid_map_path) if File.exist?(ugid_map_path)
    Dir.rmdir(migration_dir) if Dir.exist?(migration_dir)
  end

  def ugid_map_path
    File.join(migration_dir, 'user_ugids.yml')
  end

  def load_users
    Dir.glob(File.join(conf_dir, 'user', '*.yml')).map do |f|
      name = File.basename(f)[0..(('.yml'.length+1) * -1)]
      cfg = YAML.load_file(f)

      User.new(name, f, cfg)
    end
  end

  def load_passwd
    syscmd('getent passwd').output.split("\n").map do |line|
      fields = line.split(':')
      fields[2].to_i
    end
  end
end

r = Rollback.new
r.run
