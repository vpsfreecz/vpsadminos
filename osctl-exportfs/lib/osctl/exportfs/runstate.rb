module OsCtl::ExportFS
  module RunState
    # Root directory for osctl-exportfs
    DIR = '/run/osctl-exportfs'

    # Directory that the host's runsvdir is run with, used for NFS server
    # services
    RUNSVDIR = File.join(DIR, 'runsvdir')

    # Template files reused by servers
    TPL_DIR = File.join(DIR, 'template')
    TPL_RUNIT_DIR = File.join(TPL_DIR, 'runit')
    TPL_RUNIT_RUNSVDIR = File.join(TPL_RUNIT_DIR, 'runsvdir')

    # Directory with the current server, available only in the server namespace
    CURRENT_SERVER = File.join(DIR, 'current-server')

    # Directory with all servers, available only in the host namespace
    SERVERS = File.join(DIR, 'servers')

    # Directory where each servers' rootfs is prepared, always empty on the host
    ROOTFS = File.join(DIR, 'rootfs')
  end
end
