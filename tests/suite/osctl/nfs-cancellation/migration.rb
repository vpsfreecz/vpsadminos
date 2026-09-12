describe 'NFSv4 server migration', order: :defined do
  it 'preserves the payload and refreshes RPC links when replacing the server' do
    source_ns = nil
    mounted = tracing = false
    export_options = 'fsid=4321,rw,insecure,no_root_squash,no_subtree_check'

    machine.all_succeed(
      'mkdir -p /srv/nfs-migration',
      'chmod 0777 /srv/nfs-migration',
      'dd if=/dev/urandom of=/srv/nfs-migration/payload bs=1M count=2',
      'osctl-exportfs export add --directory /srv/nfs-migration ' \
      "--host 192.168.1.0/24 --options #{export_options} server1",
      'osctl-exportfs server new --address 10.0.0.11 --nfs-versions 4,4.1,4.2 server2',
      'osctl-exportfs export add --directory /srv/nfs-migration ' \
      "--host 192.168.1.0/24 --options #{export_options} server2",
      'osctl-exportfs server start server2'
    )
    machine.wait_until_succeeds('test -s /run/osctl/exportfs/servers/server2/pid', timeout: 60)
    source_pid = Integer(machine.succeeds('cat /run/osctl/exportfs/servers/server1/pid')[1].strip)
    target_pid = Integer(machine.succeeds('cat /run/osctl/exportfs/servers/server2/pid')[1].strip)
    # PID namespace entry makes /proc/net/rpc visible to exportfs cache flushes.
    source_ns = "nsenter -t #{source_pid} -m -n -u -p --root --wdns=/"
    target_ns = "nsenter -t #{target_pid} -m -n -u -p --root --wdns=/"
    machine.wait_until_succeeds(
      "#{target_ns} sh -c 'test $(cat /proc/fs/nfsd/threads) -gt 0'", timeout: 60
    )
    # Distinct server_owner/scope forces migration instead of trunking. Updating
    # the thread count refreshes NFSD's identity without restarting its service.
    machine.succeeds("#{target_ns} sh -c 'hostname server2; echo 8 > /proc/fs/nfsd/threads'")
    machine.all_succeed(
      'osctl ct exec nfs1 mkdir -p /mnt/migration',
      'osctl ct exec nfs1 mount -t nfs -o vers=4.2,proto=tcp,actimeo=0,timeo=10,retrans=2 ' \
      '10.0.0.10:/srv/nfs-migration /mnt/migration'
    )
    mounted = true
    payload_hash = machine.succeeds('sha256sum /srv/nfs-migration/payload')[1].split.first
    expect(machine.succeeds('osctl ct exec nfs1 sha256sum /mnt/migration/payload')[1].split.first)
      .to eq(payload_hash)

    mount_info = machine.succeeds('osctl ct exec nfs1 cat /proc/self/mountinfo')[1]
                        .lines.map(&:split).find { |fields| fields[4] == '/mnt/migration' }
    sysfs_dir = "/sys/fs/nfs/#{mount_info.fetch(2)}"
    links = %w[nfs_client nfs_state_client]
    previous_targets = links.to_h do |name|
      [name, machine.succeeds("osctl ct exec nfs1 readlink -e #{sysfs_dir}/#{name}")[1].strip]
    end
    machine.all_succeed(
      'mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing',
      "echo 'r:nfs_cancel_migrate nfs4_update_server result=$retval:s32' >> /sys/kernel/tracing/kprobe_events",
      'echo 1 > /sys/kernel/tracing/events/kprobes/nfs_cancel_migrate/enable',
      'echo > /sys/kernel/tracing/trace'
    )
    tracing = true
    # Both servers bind the same filesystem and explicit fsid, preserving file
    # handles. Allow unprivileged ports: the existing transport replacement path
    # does not preserve the initial transport's reserved-port setting.
    machine.all_succeed(
      "#{source_ns} exportfs -i -o #{export_options},refer=/srv/nfs-migration@10.0.0.11 " \
      '192.168.1.0/24:/srv/nfs-migration',
      "#{source_ns} exportfs -f",
      'echo migrated > /srv/nfs-migration/after-migration'
    )
    expect(machine.succeeds('osctl ct exec nfs1 cat /mnt/migration/after-migration', timeout: 90)[1].strip)
      .to eq('migrated')
    trace = machine.succeeds('cat /sys/kernel/tracing/trace')[1]
    expect(trace).to match(/nfs_cancel_migrate:.*result=0/)
    expect(machine.succeeds('osctl ct exec nfs1 sha256sum /mnt/migration/payload')[1].split.first)
      .to eq(payload_hash)
    machine.succeeds('osctl ct exec nfs1 sh -c "echo target-write > /mnt/migration/target-write; sync"')
    expect(machine.succeeds('cat /srv/nfs-migration/target-write')[1].strip).to eq('target-write')
    links.each do |name|
      target = machine.succeeds("osctl ct exec nfs1 readlink -e #{sysfs_dir}/#{name}")[1].strip
      # The mount client retains its id, but its sysfs target is recreated.
      # readlink -e must resolve it; the state client receives a different id.
      if name == 'nfs_state_client'
        expect(target).not_to eq(previous_targets.fetch(name))
      else
        expect(target).to eq(previous_targets.fetch(name))
      end
    end
  ensure
    if source_ns
      machine.execute(
        "#{source_ns} exportfs -i -o #{export_options} 192.168.1.0/24:/srv/nfs-migration; " \
        "#{source_ns} exportfs -f", timeout: 30
      )
    end
    if tracing
      machine.execute('cat /sys/kernel/tracing/trace', timeout: 15)
      machine.execute('echo 0 > /sys/kernel/tracing/events/kprobes/nfs_cancel_migrate/enable', timeout: 15)
      machine.execute("echo '-:nfs_cancel_migrate' >> /sys/kernel/tracing/kprobe_events", timeout: 15)
    end
    machine.execute('osctl ct exec nfs1 umount /mnt/migration', timeout: 30) if mounted
  end
end
