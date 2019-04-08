require 'libosctl'
require 'yaml'

class Rollback
  User = Struct.new(:name, :type, :ugid, :config, :opts)

  include OsCtl::Lib::Utils::Log
  include OsCtl::Lib::Utils::System

  attr_reader :conf_dir, :users, :system_uids

  def initialize
    @conf_dir = zfs(:get, '-Hp -o value mountpoint', File.join($POOL, 'conf'))[:output].strip
    @users = load_users
    @system_uids = load_passwd
  end

  def run
    last_ugid = 100_000

    users.each do |user|
      if user.type == 'static'
        user.opts.delete('type')
        File.write(user.config, YAML.dump(user.opts))

      elsif user.type == 'dynamic'
        ugid = get_free_ugid(last_ugid)
        fail "unable to assign static ugid to user '#{user.name}'" unless ugid

        last_ugid = ugid

        user.opts.delete('type')
        user.opts['ugid'] = ugid
        File.write(user.config, YAML.dump(user.opts))
      end
    end
  end

  protected
  def get_free_ugid(start_ugid)
    ugid = start_ugid
    max = 2**31 - 2

    loop do
      ugid += 1

      if ugid == 65534 || system_uids.include?(ugid)
        next
      elsif ugid >= max
        return
      else
        return ugid
      end
    end
  end

  def load_users
    Dir.glob(File.join(conf_dir, 'user', '*.yml')).map do |f|
      name = File.basename(f)[0..(('.yml'.length+1) * -1)]
      cfg = YAML.load_file(f)

      User.new(
        name,
        cfg['type'] || 'static',
        cfg['ugid'],
        f,
        cfg
      )
    end
  end

  def load_passwd
    syscmd('getent passwd')[:output].split("\n").map do |line|
      fields = line.split(':')
      fields[2].to_i
    end
  end
end

r = Rollback.new
r.run
