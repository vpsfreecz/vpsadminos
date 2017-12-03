module OsCtld
  module Commands
    module Container ; end
    module User ; end
  end
  module Utils ; end

  POOL = 'lxc'
  USER_DS = "#{POOL}/user"

  def self.root
    File.join(File.dirname(__FILE__), '..')
  end

  def self.bin(name)
    File.absolute_path(File.join(root, 'bin', name))
  end

  def self.tpl(name)
    File.absolute_path(File.join(root, 'templates', "#{name}.erb"))
  end
end

require_relative 'osctld/version'
require_relative 'osctld/template'
require_relative 'osctld/utils/log'
require_relative 'osctld/utils/system'
require_relative 'osctld/utils/zfs'
require_relative 'osctld/utils/switch_user'
require_relative 'osctld/command'
require_relative 'osctld/client_handler'
require_relative 'osctld/container_list'
require_relative 'osctld/container'
require_relative 'osctld/user_list'
require_relative 'osctld/user'
require_relative 'osctld/daemon'
require_relative 'osctld/switch_user'
require_relative 'osctld/switch_user/container_control'

require_relative 'osctld/commands/base'

#require_relative 'osctld/commands/base'
#require_relative 'osctld/commands/user/register'
#require_relative 'osctld/commands/user/subugids'
#require_relative 'osctld/commands/user/create'
#require_relative 'osctld/commands/user/delete'
#require_relative 'osctld/commands/user/list'

Dir.glob(File.join(
  File.dirname(__FILE__),
  'osctld', 'commands', '*', '*.rb'
)).each { |f| require_relative f }
