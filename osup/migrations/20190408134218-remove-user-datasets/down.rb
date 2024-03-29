require 'fileutils'
require 'libosctl'
require 'yaml'

class Rollback
  User = Struct.new(:name, :type, :ugid)
  Container = Struct.new(:id, :user, :group)

  include OsCtl::Lib::Utils::Log
  include OsCtl::Lib::Utils::System

  attr_reader :users, :groups, :cts, :users_ds, :users_dir, :conf_ds, :conf_dir

  def initialize
    @users_ds = File.join($DATASET, 'user')
    @conf_ds = File.join($DATASET, 'conf')
    @conf_dir = zfs(:get, '-Hp -o value mountpoint', conf_ds).output.strip

    @users = load_users
    @groups = load_groups
    @cts = load_cts
  end

  def run
    # Create root dataset for users
    zfs(:create, nil, users_ds)
    @users_dir = zfs(:get, '-Hp -o value mountpoint', users_ds).output.strip

    users.each do |user|
      # Create dataset for every user
      zfs(:create, nil, File.join(users_ds, user.name))

      # Create LXC paths for all containers owned by `user`
      user_group_containers(user).each do |group, cts|
        user_dir = File.join(users_dir, user.name)
        usergroup_dir = File.join(
          user_dir,
          *group.split('/').drop(1).map { |v| "group.#{v}" },
          'cts'
        )

        FileUtils.mkdir_p(usergroup_dir, mode: 0o751)
        File.chown(0, user.ugid, usergroup_dir)

        cts.each do |ct|
          ct_dir = File.join(usergroup_dir, ct.id)

          Dir.mkdir(ct_dir, 0o750)
          File.chown(0, user.ugid, ct_dir)

          generate_bashrc(usergroup_dir, ct_dir, ct)
        end
      end
    end
  end

  protected

  def user_group_containers(user)
    ret = {}

    cts.each do |ct|
      next if ct.user != user.name

      if ret.has_key?(ct.group)
        ret[ct.group] << ct
      else
        ret[ct.group] = [ct]
      end
    end

    ret
  end

  def load_users
    Dir.glob(File.join(conf_dir, 'user', '*.yml')).map do |f|
      name = File.basename(f)[0..(('.yml'.length + 1) * -1)]
      cfg = YAML.load_file(f)

      User.new(
        name,
        cfg['type'] || 'static',
        cfg['ugid']
      )
    end
  end

  def load_groups
    rx = %r{^#{Regexp.escape(File.join(conf_dir, 'group'))}(.*)/config\.yml$}

    Dir.glob(File.join(conf_dir, 'group', '**', 'config.yml')).map do |file|
      next unless rx =~ file

      ::Regexp.last_match(1)
    end
  end

  def load_cts
    Dir.glob(File.join(conf_dir, 'ct', '*.yml')).map do |f|
      ctid = File.basename(f)[0..(('.yml'.length + 1) * -1)]
      cfg = YAML.load_file(f)

      Container.new(ctid, cfg['user'], cfg['group'])
    end
  end

  def generate_bashrc(usergroup_dir, ct_dir, ct)
    File.write(File.join(ct_dir, '.bashrc'), <<~EOF)
      # Generated by osctld
      # All changes will be lost

      use_osctl () {
        echo "lxc-$1 is disabled on vpsAdmin OS. Use osctl instead." >&2
      }

      lxc_start () {
        echo "osctl will not be able to open tty0 of containers started using"
        echo "lxc-start, i.e. osctl console <ctid> will not work."
        echo -n "continue? [y/N]: "
        read cont

        if [ "$cont" == "y" ] ; then
          cmd=`which lxc-start`
          $cmd -P #{usergroup_dir} -n #{ct.id} $@
        fi
      }

      alias lxc-start='lxc_start'

      alias lxc-attach='lxc-attach -P #{usergroup_dir} -n #{ct.id}'
      alias lxc-cgroup='lxc-cgroup -P #{usergroup_dir} -n #{ct.id}'
      alias lxc-console='lxc-console -P #{usergroup_dir} -n #{ct.id}'
      alias lxc-device='lxc-device -P #{usergroup_dir} -n #{ct.id}'
      alias lxc-execute='lxc-execute -P #{usergroup_dir} -n #{ct.id}'
      alias lxc-info='lxc-info -P #{usergroup_dir} -n #{ct.id}'
      alias lxc-ls='lxc-ls -P #{usergroup_dir} -n #{ct.id}'
      alias lxc-monitor='lxc-monitor -P #{usergroup_dir} -n #{ct.id}'
      alias lxc-stop='lxc-stop -P #{usergroup_dir} -n #{ct.id}'
      alias lxc-top='lxc-top -P #{usergroup_dir} -n #{ct.id}'
      alias lxc-wait='lxc-wait -P #{usergroup_dir} -n #{ct.id}'

      alias lxc-autostart='use_osctl autostart'
      alias lxc-checkpoint='use_osctl checkpoint'
      alias lxc-clone='use_osctl clone'
      alias lxc-copy='use_osctl copy'
      alias lxc-create='use_osctl create'
      alias lxc-destroy='use_osctl destroy'
      alias lxc-freeze='use_osctl freeze'
      alias lxc-snapshot='use_osctl snapshot'
      alias lxc-start-ephemeral='use_osctl start-ephemeral'
      alias lxc-unfreeze='use_osctl unfreeze'
      alias lxc-unshare='use_osctl unshare'

      cd #{usergroup_dir}
      echo "Opened shell for:"
      echo "  User:  #{ct.user}"
      echo "  Group: #{ct.group}"
      echo "  CT:    #{ct.id}"
      echo
      echo "Available LXC utilities:"
      echo "  lxc-attach"
      echo "  lxc-cgroup"
      echo "  lxc-console"
      echo "  lxc-device"
      echo "  lxc-execute"
      echo "  lxc-info"
      echo "  lxc-ls"
      echo "  lxc-monitor"
      echo "  lxc-stop"
      echo "  lxc-top"
      echo "  lxc-wait"
      echo
      echo "Implicit arguments: -P #{usergroup_dir} -n #{ct.id}"
      echo "Do not use this shell to manipulate any other container than #{ct.id}."
    EOF
  end
end

r = Rollback.new
r.run
