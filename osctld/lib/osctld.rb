require 'require_all'
require 'osctld/native'

module OsCtld
  module AutoStart ; end
  module AutoStop ; end
  module Commands
    module Container ; end
    module CpuScheduler ; end
    module Dataset ; end
    module Debug ; end
    module Event ; end
    module Group ; end
    module History ; end
    module IdRange ; end
    module NetInterface ; end
    module Pool ; end
    module Receive ; end
    module Repository ; end
    module Self ; end
    module Send ; end
    module TrashBin ; end
    module User ; end
  end
  module DB ; end
  module Devices
    module V1 ; end
    module V2 ; end
  end
  module Generic ; end
  module Hook ; end
  module Mount ; end
  module PrLimits ; end
  module Routing ; end
  module Utils ; end
  module UserControl
    module Commands ; end
  end
  module ContainerControl
    module Commands ; end
    module Utils ; end
  end

  def self.root
    File.join(__dir__, '..')
  end

  def self.bin(name)
    File.absolute_path(File.join(root, 'bin', name))
  end

  def self.hook_src(name)
    File.absolute_path(File.join(root, 'hooks', name))
  end

  def self.hook_run(name, pool)
    File.join(pool.hook_dir, name)
  end

  def self.script(name)
    File.absolute_path(File.join(root, 'scripts', name))
  end

  def self.template_dir
    File.absolute_path(File.join(root, 'templates'))
  end
end

require_rel 'osctld/utils'
require_rel 'osctld/*.rb'
require_rel 'osctld/assets'
require_rel 'osctld/auto_start'
require_rel 'osctld/auto_stop'
require_rel 'osctld/cgroup'
require_rel 'osctld/console'
require_rel 'osctld/container'
require_rel 'osctld/pool'
require_rel 'osctld/db'
require_rel 'osctld/devices'
require_rel 'osctld/dist_config'
require_rel 'osctld/eventd'
require_rel 'osctld/generic'
require_rel 'osctld/hook'
require_rel 'osctld/id_range'
require_rel 'osctld/monitor'
require_rel 'osctld/mount'
require_rel 'osctld/net_interface'
require_rel 'osctld/prlimits'
require_rel 'osctld/repository'
require_rel 'osctld/routing'
require_rel 'osctld/run_state'
require_rel 'osctld/switch_user'

require_rel 'osctld/commands'
require_rel 'osctld/send_receive'
require_rel 'osctld/user_control'
require_rel 'osctld/container_control'
