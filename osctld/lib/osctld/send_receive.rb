require 'etc'
require 'libosctl'
require 'osctld/run_state'

module OsCtld
  module SendReceive
    module Commands ; end

    extend OsCtl::Lib::Utils::File

    USER = 'osctl-ct-receive'
    UID = Etc.getpwnam(USER).uid
    SOCKET = File.join(RunState::SEND_RECEIVE_DIR, 'control.sock')
    AUTHORIZED_KEYS = File.join(RunState::SEND_RECEIVE_DIR, 'authorized_keys')
    HOOK = File.join(RunState::SEND_RECEIVE_DIR, 'run')

    def self.setup
      Server.start

      replace_symlink(HOOK, OsCtld::hook_src('send-receive'))
    end

    def self.stop
      Server.stop
    end

    def self.deploy
      regenerate_file(AUTHORIZED_KEYS, 0400) do |new, old|
        DB::Pools.get.each { |pool| pool.send_receive_key_chain.deploy(new) }
      end

      File.chown(UID, 0, AUTHORIZED_KEYS)
    end

    def self.started_using_key(pool, name)
      if pool.send_receive_key_chain.started_using_key(name)
        pool.send_receive_key_chain.save
      end
    end

    def self.stopped_using_key(pool, name)
      if pool.send_receive_key_chain.stopped_using_key(name)
        pool.send_receive_key_chain.save
        deploy
      end
    end

    def self.assets(add)
      add.symlink(
        HOOK,
        desc: 'Command run by remote node'
      )
      add.file(
        AUTHORIZED_KEYS,
        desc: 'Keys that are authorized to send containers to this node',
        user: UID,
        group: 0,
        mode: 0400
      )

      Server.assets(add)
    end
  end
end
