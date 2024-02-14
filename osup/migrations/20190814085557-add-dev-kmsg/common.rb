require 'libosctl'
require 'yaml'

class Pool
  include OsCtl::Lib::Utils::Log
  include OsCtl::Lib::Utils::System

  attr_reader :conf_dir

  def initialize
    @conf_dir = zfs(
      :get,
      '-Hp -o value mountpoint',
      File.join($DATASET, 'conf')
    ).output.strip
  end
end

class GroupConfig
  include OsCtl::Lib::Utils::File

  attr_reader :cfg_path, :cfg, :device_list

  def initialize(pool, name)
    @cfg_path = File.join(pool.conf_dir, 'group', name, 'config.yml')
    @cfg = YAML.load_file(cfg_path)
    @device_list = DeviceList.new(cfg['devices'])
  end

  def ensure_device(dev)
    device_list.ensure(dev)
  end

  def save
    regenerate_file(cfg_path, 0o400) do |new|
      cfg['devices'] = device_list.dump
      new.write(YAML.dump(cfg))
    end
  end
end

class DeviceList < Array
  attr_reader :devices

  def initialize(cfg)
    super()
    @devices = cfg.map { |d| Device.new(d) }
  end

  def ensure(dev)
    found = devices.detect { |d| d.include?(dev) }

    if found
      if found.major == '*' || found.minor == '*'
        insert(dev) unless found.inherit === dev.inherit
      elsif !(found.inherit === dev.inherit)
        found.inherit = true
      end
    else
      insert(dev)
    end
  end

  def insert(dev)
    index = nil

    devices.each_with_index do |d, i|
      next if d.major == '*' || d.minor == '*'

      if d.major.to_i > dev.major.to_i || d.minor.to_i > dev.minor.to_i
        index = i
        break
      end
    end

    if index
      devices.insert(index, dev)
    else
      devices << dev
    end
  end

  def dump
    devices.map(&:dump)
  end
end

class Device
  attr_reader :type, :major, :minor, :mode, :name, :inherit, :inherited

  def initialize(cfg)
    @type = cfg['type']
    @major = cfg['major']
    @minor = cfg['minor']
    @mode = cfg['mode']
    @name = cfg['name']
    @inherit = cfg['inherit']
    @inherited = cfg['inherited']
  end

  def include?(dev)
    (major == dev.major && minor == dev.minor) \
      || ( \
        (major == '*' && minor == '*' && mode_include?(mode, dev.mode)) \
        || (major == '*' && minor == dev.minor && mode_include?(mode, dev.mode)) \
        || (major == dev.major && minor == '*' && mode_include?(mode, dev.mode)) \
      )
  end

  # True if m1 includes m2
  def mode_include?(m1, m2)
    m2.each_char do |c|
      return false unless m1.include?(c)
    end

    true
  end

  def dump
    {
      'type' => type,
      'major' => major,
      'minor' => minor,
      'mode' => mode,
      'name' => name,
      'inherit' => inherit,
      'inherited' => inherited
    }
  end
end
