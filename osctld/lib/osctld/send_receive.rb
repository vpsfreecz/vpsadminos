require 'etc'
require 'osctld/run_state'

module OsCtld
  module SendReceive
    module Commands ; end

    USER = 'osctl-ct-receive'
    UID = Etc.getpwnam(USER).uid
    SOCKET = File.join(RunState::SEND_RECEIVE_DIR, 'control.sock')
    AUTHORIZED_KEYS = File.join(RunState::SEND_RECEIVE_DIR, 'authorized_keys')
    HOOK = File.join(RunState::SEND_RECEIVE_DIR, 'run')

    def self.setup
      Server.start
      reset

      unless File.symlink?(HOOK)
        File.symlink(OsCtld::hook_src('send-receive'), HOOK)
      end
    end

    def self.stop
      Server.stop
    end

    def self.deploy
      reset
      DB::Pools.get.each { |pool| pool.send_receive_key_chain.deploy }
    end

    def self.reset
      File.open(AUTHORIZED_KEYS, 'w', 0400).close
      File.chown(UID, 0, AUTHORIZED_KEYS)
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
