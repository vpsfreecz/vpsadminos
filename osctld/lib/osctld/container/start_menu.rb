require 'fileutils'
require 'libosctl'

module OsCtld
  class Container::StartMenu
    CT_START_MENU = ENV['OSCTLD_CT_START_MENU']

    def self.load(ct, cfg)
      new(ct, cfg['timeout'] || 5)
    end

    include OsCtl::Lib::Utils::Log

    attr_reader :ct, :timeout

    def initialize(ct, timeout)
      @ct = ct
      @timeout = timeout
    end

    def deploy
      FileUtils.copy_file(CT_START_MENU, host_path, preserve: true)
    rescue SystemCallError => e
      log(:fatal, "Unable to deploy start menu: #{e.message} (#{e.class})")
    end

    def unlink
      File.unlink(host_path)
    rescue Errno::ENOENT
    end

    def init_cmd(cmd)
      [ct_path, '-timeout', timeout.to_s].concat(cmd)
    end

    def host_path
      File.join(ct.mounts.shared_dir.path, 'ctstartmenu')
    end

    def ct_path
      File.join('/', ct.mounts.shared_dir.mountpoint, 'ctstartmenu')
    end

    def dump
      {
        'timeout' => timeout,
      }
    end

    def dup(new_ct)
      ret = super()
      ret.instance_variable_set('@ct', new_ct)
      ret
    end

    def log_type
      ct.log_type
    end
  end
end
