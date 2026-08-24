#!@ruby@/bin/ruby
require 'fileutils'
require 'fiddle/import'
require 'json'
require 'open3'
require 'socket'
require 'timeout'

module LinuxPidfd
  extend Fiddle::Importer

  dlload Fiddle.dlopen(nil)
  extern 'int pidfd_open(int, unsigned int)'
  extern 'int pidfd_send_signal(int, int, void *, unsigned int)'
end

class Configuration
  OUT = '@out@'.freeze
  ETC = File.join(OUT, 'etc')
  CURRENT_SYSTEM = '/run/current-system'.freeze
  CURRENT_BIN = File.join(CURRENT_SYSTEM, 'sw/bin')
  NEW_BIN = File.join(OUT, 'sw', 'bin')
  INSTALL_BOOTLOADER = '@installBootLoader@'.freeze

  class << self
    %i[boot switch test].each do |m|
      define_method(m) { new(dry_run: false).send(m) }
    end
  end

  def self.dry_run
    new(dry_run: true).dry_run
  end

  def initialize(dry_run: true)
    @opts = { dry_run: }
  end

  def dry_run
    puts 'probing runit services...'
    services = Services.new(**opts)

    puts 'probing pools...'
    pools = Pools.new(**opts)
    pools.export
    pools.rollback

    if pools.error.any?
      puts "unable to handle pools: #{pools.error.map(&:name).join(',')}"
    end

    osctld = OsctldRestart.new(services, dry_run: true)
    osctld.prepare

    puts 'would stop deprecated services...'
    services.stop.each(&:stop)

    puts 'would stop changed services...'
    services.restart_before_osctld.each(&:stop)

    puts 'would activate the configuration...'
    activate

    services.switch_runlevel

    osctld_start_config(services)

    osctld.start_and_wait
    osctld.resume_nodectld

    puts 'would reload changed services...'
    services.reload.each(&:reload)

    puts 'would restart changed services...'
    services.deferred_restart_after_osctld(
      nodectld_restarted: osctld.target_nodectld_restarted?
    ).each(&:stop)
    services.restart_after_osctld(
      nodectld_restarted: osctld.target_nodectld_restarted?
    ).each(&:start)

    puts 'runit would start new services...'
    services.start.each(&:start)

    activate_osctl(services)
  end

  def boot
    if INSTALL_BOOTLOADER == 'none'
      puts 'no bootloader active'
      return
    end

    system(INSTALL_BOOTLOADER, OUT) || (raise 'unable to install boot loader')
  end

  def switch
    boot
    test
  end

  def test
    puts 'probing runit services...'
    services = Services.new(**opts)

    puts 'probing pools...'
    pools = Pools.new(**opts)
    pools.export
    pools.rollback

    if pools.error.any?
      puts "unable to handle pools: #{pools.error.map(&:name).join(',')}"
    end

    osctld = OsctldRestart.new(services, dry_run: false)
    osctld.prepare

    puts 'stopping deprecated services...'
    services.stop.each(&:stop)

    puts 'stopping changed services...'
    services.restart_before_osctld.each(&:stop)

    puts 'activating the configuration...'
    activate

    services.switch_runlevel

    osctld_start_config(services)

    osctld.start_and_wait
    osctld.resume_nodectld

    puts 'reloading changed services...'
    services.reload.each(&:reload)

    puts 'restarting changed services...'
    services.deferred_restart_after_osctld(
      nodectld_restarted: osctld.target_nodectld_restarted?
    ).each(&:stop)
    services.restart_after_osctld(
      nodectld_restarted: osctld.target_nodectld_restarted?
    ).each(&:start)

    puts 'runit will start new services...'

    activate_osctl(services)
  end

  def activate
    return if opts[:dry_run]

    system(File.join(OUT, 'activate'))
  end

  protected

  attr_reader :opts

  def osctld_start_config(services)
    return unless services.restart.detect { |s| s.name == 'osctld' && !s.skip? }

    cfg = {}

    puts '> osctld start config:'

    if cfg.empty?
      puts '- no changes'
      return
    end

    return if opts[:dry_run]

    puts '- writing config'

    dir = '/run/osctl/configs/osctld'
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, 'start-config.json'), cfg.to_json)
  end

  def activate_osctl(services)
    # If osctld is restarted, it will regenerate system files by itself
    return if services.restart.detect { |s| s.name == 'osctld' && !s.skip? }

    args = ['--system']

    puts "> osctl activate #{args.join(' ')}"
    return if opts[:dry_run]

    system(File.join(CURRENT_BIN, 'osctl'), 'activate', *args)
  end
end

class OsctldRestart
  HANDOFF_PATH = '/run/osctl/upgrade-handoff.yml'.freeze
  SERVICE_DIR = '/service'.freeze
  PROC_DIR = '/proc'.freeze
  RUNIT_SERVICE_CGROUP_DIR = '/run/runit/cgroup.service'.freeze
  NODECTLD_PAUSE_PATH = '/run/osctl/nodectld-upgrade-pause.json'.freeze
  # Shared with vpsAdmin's NodeCtld::DaemonRestartBarrier. Every marker writer
  # must hold this lock so ordinary hooks cannot replace coordinator ownership.
  NODECTLD_PAUSE_LOCK_PATH = "#{NODECTLD_PAUSE_PATH}.lock".freeze
  NODECTLD_DOWN_PATH = '/etc/runit/services/nodectld/down'.freeze
  NODECTLD_DOWN_CONTENT = "osctld-runtime-upgrade\n".freeze
  NODECTLD_PAUSE_REASONS = %w[
    osctld-restart
    legacy-osctld-runtime-upgrade
  ].freeze
  NODECTLD_LEGACY_PAUSE_PHASES = %w[
    acquiring-supervision
    supervision-held
  ].freeze
  HANDOFF_SOURCE = 'legacy-runtime-upgrade'.freeze
  BOOT_ID_PATH = '/proc/sys/kernel/random/boot_id'.freeze
  LEGACY_SETTLE_TIMEOUT = 300
  LEGACY_STABLE_WINDOW = 60
  SERVICE_STOP_TIMEOUT = 60
  READY_TIMEOUT = 300
  STABLE_STATES = %w[running stopped frozen].freeze
  LEGACY_START_STATES = %w[starting aborting].freeze
  DEAD_PROCESS_STATES = %w[Z X x].freeze

  def initialize(
    services,
    dry_run:,
    legacy_settle_timeout: LEGACY_SETTLE_TIMEOUT,
    legacy_stable_window: LEGACY_STABLE_WINDOW,
    service_stop_timeout: SERVICE_STOP_TIMEOUT,
    ready_timeout: READY_TIMEOUT,
    nodectld_pause_path: NODECTLD_PAUSE_PATH,
    nodectld_pause_lock_path: nil,
    nodectld_down_path: NODECTLD_DOWN_PATH,
    boot_id_path: BOOT_ID_PATH
  )
    @services = services
    @service = services.osctld_restart
    @target_service = services.osctld_target
    @dry_run = dry_run
    @legacy_settle_timeout = legacy_settle_timeout
    @legacy_stable_window = legacy_stable_window
    @service_stop_timeout = service_stop_timeout
    @ready_timeout = ready_timeout
    @nodectld_pause_path = nodectld_pause_path
    @nodectld_pause_lock_path = nodectld_pause_lock_path \
      || "#{nodectld_pause_path}.lock"
    @nodectld_down_path = nodectld_down_path
    @boot_id_path = boot_id_path
    @legacy = false
    @interrupted_restart = false
    pause_cfg = dry_run ? nil : persisted_nodectld_pause
    @legacy_nodectld_paused = !pause_cfg.nil?
    @nodectld_pause_reason = pause_cfg&.fetch('reason', nil)
    @legacy_nodectld_identity = pause_cfg&.fetch('service_process', nil)
    @legacy_nodectld_down_created = pause_cfg&.fetch('service_down_created', false) == true
    @target_nodectld_restarted = false
    @handoff_queues = []
    @handoff_active = []
    @handoff_desired = []
    @handoff_runtime = []
    @handoff_priorities = {}
    @current_handoff_observed = []
    @legacy_cancelled_pools = []
    @legacy_restored_entries = []
    @legacy_restored_intents = []
    @legacy_started_before = {}
  end

  def prepare
    if dry_run
      return unless service

      puts '> osctl daemon prepare-stop (or legacy runtime handoff)'
      puts '> sv stop osctld; wait up to 60 seconds for its supervisor'
      return
    end

    if !service_running?('osctld') \
        && (current_boot_handoff? || legacy_nodectld_paused)
      if current_boot_handoff?
        @legacy = true
        merge_existing_handoff
        puts '> recovering interrupted legacy osctld handoff'
      else
        puts '> recovering interrupted osctld restart'
      end
      @interrupted_restart = true
      return
    end

    return unless service

    daemon_status = osctl_json('daemon', 'status')
    unless daemon_status['initialized']
      raise 'osctld is not initialized, refusing runtime replacement'
    end

    @legacy = daemon_status['legacy'] == true
    if legacy
      prepare_legacy
    elsif !run_osctl('daemon', 'prepare-stop')
      run_osctl('daemon', 'resume')
      raise 'osctld lifecycle drain failed before activation'
    end

    service.stop
    if wait_service_down
      finalize_legacy_handoff if legacy
      return
    end

    service.start
    if legacy
      wait_for_legacy_daemon
      restore_legacy_handoff
    else
      # The configuration has not been activated yet. Restore runit's desired
      # state and reopen admission if the old daemon is still available.
      run_osctl('daemon', 'resume')
    end
    stop_timeout = legacy ? legacy_settle_timeout : service_stop_timeout
    raise "osctld supervisor did not stop within #{stop_timeout} seconds"
  rescue StandardError
    restore_legacy_handoff if legacy
    raise
  end

  def start_and_wait
    return unless service || @interrupted_restart || legacy_nodectld_paused

    if dry_run
      puts '> sv start osctld'
      puts "> osctl daemon wait-ready --timeout #{ready_timeout}"
      return
    end

    if legacy_nodectld_pause?
      restart_target_nodectld
    else
      restore_nodectld_supervision
    end
    target_service&.start
    return if wait_for_target_ready

    raise "target osctld did not become ready within #{ready_timeout} seconds"
  end

  def resume_nodectld
    return unless legacy_nodectld_paused

    if dry_run
      puts '> nodectld remote resume'
    else
      restore_nodectld_supervision
      puts '> nodectld remote resume'
      raise 'unable to resume nodectld after target osctld readiness' \
        unless resume_nodectld_after_barrier

      @legacy_nodectld_paused = false
      @nodectld_pause_reason = nil
    end
  end

  def target_nodectld_restarted?
    @target_nodectld_restarted
  end

  protected

  attr_reader :services, :service, :target_service, :legacy_settle_timeout, :legacy_stable_window, :service_stop_timeout, :ready_timeout, :dry_run, :legacy, :legacy_nodectld_paused, :nodectld_pause_path, :nodectld_pause_lock_path, :nodectld_down_path, :boot_id_path

  def prepare_legacy
    merge_existing_handoff
    nodectld_barrier = pause_legacy_nodectld
    if nodectld_barrier && !wait_for_legacy_nodectld_idle
      raise 'nodectld transactions did not drain before legacy osctld handoff'
    end

    pools = osctl_json('pool', 'list', '-o', 'name').map { |pool| pool.fetch('name') }
    containers = osctl_json(
      'ct', 'list',
      '-o', 'pool,id,runtime_state,autostart,autostart_priority'
    )
    @legacy_started_before = pools.to_h do |pool|
      [pool, legacy_started_containers(pool)]
    end

    pools.each do |pool|
      queue = osctl_json('pool', 'autostart', 'queue', pool)
      queue.each do |entry|
        priority = entry.fetch('priority', 10)
        @handoff_queues << {
          'pool' => pool,
          'id' => entry.fetch('id'),
          'priority' => priority
        }
        remember_handoff_priority(pool, entry.fetch('id'), priority)
        remember_handoff(pool, entry.fetch('id'))
      end
    end

    replace_runtime_handoff(containers)
    containers.each { |ct| remember_legacy_start_handoff(ct) }

    write_handoff
    pools.each do |pool|
      run_osctl!('pool', 'autostart', 'cancel', pool)
      @legacy_cancelled_pools << pool
    end
    wait_for_legacy_stability
  rescue StandardError
    restore_legacy_handoff
    raise
  end

  def pause_legacy_nodectld
    unless service_supervised?('nodectld')
      if legacy_nodectld_paused
        raise 'nodectld restart barrier exists, but its service is not supervised'
      end

      return false
    end

    puts '> nodectld remote pause'
    unless legacy_nodectld_pause?
      @legacy_nodectld_identity = service_process_identity('nodectld')
      unless @legacy_nodectld_identity
        raise 'unable to identify the supervised nodectld process'
      end

      @legacy_nodectld_paused = true
      @nodectld_pause_reason = 'legacy-osctld-runtime-upgrade'
      persist_nodectld_pause(phase: 'acquiring-supervision')
    end
    hold_nodectld_supervision
    persist_nodectld_pause(phase: 'supervision-held')

    raise 'unable to pause nodectld for legacy osctld handoff' \
      unless wait_nodectld_remote(:pause)

    true
  rescue StandardError
    restore_nodectld_supervision if @legacy_nodectld_down_created
    raise
  end

  def hold_nodectld_supervision
    if File.exist?(nodectld_down_path)
      unless File.read(nodectld_down_path) == NODECTLD_DOWN_CONTENT
        raise "refusing to replace unowned nodectld down file at #{nodectld_down_path}"
      end

      # This is the durable residue of an interrupted coordinator. Reclaim
      # ownership so the retry can eventually release the service.
    else
      tmp = "#{nodectld_down_path}.#{$$}.new"
      File.write(tmp, NODECTLD_DOWN_CONTENT)
      File.rename(tmp, nodectld_down_path)
    end
    @legacy_nodectld_down_created = true

    raise 'unable to hold nodectld for legacy osctld handoff' \
      unless run_svc('-o', 'nodectld')
  ensure
    File.unlink(tmp) if tmp && File.exist?(tmp)
  end

  def persist_nodectld_pause(phase:)
    cfg = {
      'schema' => 1,
      'boot_id' => File.read(boot_id_path).strip,
      'created_at' => Time.now.to_f,
      'reason' => 'legacy-osctld-runtime-upgrade',
      'phase' => phase,
      'service_down_created' => @legacy_nodectld_down_created,
      'service_process' => @legacy_nodectld_identity
    }
    with_nodectld_pause_lock { write_nodectld_pause(cfg) }
  end

  def persisted_nodectld_pause
    with_nodectld_pause_lock { read_nodectld_pause }
  end

  def read_nodectld_pause
    cfg = JSON.parse(File.read(nodectld_pause_path))
    unless cfg.is_a?(Hash) && cfg['boot_id'].is_a?(String)
      raise "invalid nodectld restart barrier at #{nodectld_pause_path}"
    end
    return unless cfg['boot_id'] == File.read(boot_id_path).strip

    unless cfg['schema'] == 1 \
        && cfg['reason'].is_a?(String) \
        && NODECTLD_PAUSE_REASONS.include?(cfg['reason']) \
        && [true, false].include?(cfg.fetch('service_down_created', false))
      raise "invalid nodectld restart barrier at #{nodectld_pause_path}"
    end

    if cfg['reason'] == 'legacy-osctld-runtime-upgrade'
      phase = cfg['phase']
      down_created = cfg['service_down_created']
      valid_phase = NODECTLD_LEGACY_PAUSE_PHASES.include?(phase)
      phase_matches_down = (phase == 'supervision-held') == down_created
      unless valid_phase \
          && phase_matches_down \
          && valid_process_identity?(cfg['service_process'])
        raise "invalid nodectld restart barrier at #{nodectld_pause_path}"
      end
    end

    cfg
  rescue Errno::ENOENT
    nil
  rescue JSON::ParserError => e
    raise "invalid nodectld restart barrier at #{nodectld_pause_path}: #{e.message}"
  end

  def wait_for_legacy_stability
    deadline = monotonic_now + legacy_settle_timeout
    stable_since = nil
    previous_signature = nil

    loop do
      containers = osctl_json(
        'ct', 'list',
        '-o', 'pool,id,runtime_state,autostart,autostart_priority'
      )
      nonterminal = containers.reject do |ct|
        STABLE_STATES.include?(ct.fetch('runtime_state'))
      end
      nonterminal.each { |ct| remember_legacy_start_handoff(ct) }
      replace_runtime_handoff(containers)
      write_handoff
      signature = [
        containers.map do |ct|
          [ct['pool'], ct['id'], ct['runtime_state']]
        end.sort,
        legacy_manager_signature
      ]

      if nonterminal.empty? && signature == previous_signature
        stable_since ||= monotonic_now
        return if monotonic_now - stable_since >= legacy_stable_window
      else
        stable_since = nil
        previous_signature = signature
      end

      if monotonic_now >= deadline
        ids = nonterminal.map do |ct|
          "#{ct['pool']}:#{ct['id']}:#{ct['runtime_state']}"
        end
        raise "legacy osctld did not reach a stable lifecycle state: #{ids.join(', ')}"
      end

      sleep(1)
    end
  end

  def finalize_legacy_handoff
    @legacy_started_before.each do |pool, started_before|
      (legacy_started_containers(pool) - started_before).each do |id|
        remember_handoff(pool, id)
      end
    end
    write_handoff
  end

  def legacy_manager_signature
    Dir.glob('/proc/[0-9]*/cmdline').filter_map do |path|
      cmdline = File.binread(path).tr("\0", ' ')
      next unless cmdline.include?('osctld-ct-wrapper') || cmdline.include?('lxc-start')

      pid = path.split('/')[2].to_i
      stat = File.read(File.join('/proc', pid.to_s, 'stat'))
      tail = stat[stat.rindex(')') + 2..]
      [pid, tail.split.fetch(19).to_i, cmdline]
    rescue Errno::ENOENT, Errno::ESRCH
      nil
    end.sort
  end

  def write_handoff
    cfg = {
      'schema' => 1,
      'boot_id' => File.read(boot_id_path).strip,
      'created_at' => Time.now.to_f,
      'containers' => @handoff_desired.map do |pool, id|
        entry = {
          'pool' => pool,
          'id' => id,
          'source' => HANDOFF_SOURCE
        }
        priority = @handoff_priorities[[pool, id]]
        entry['priority'] = priority if priority
        entry
      end,
      'runtime_containers' => @handoff_runtime.map do |pool, id|
        { 'pool' => pool, 'id' => id, 'source' => HANDOFF_SOURCE }
      end
    }
    dir = File.dirname(HANDOFF_PATH)
    FileUtils.mkdir_p(dir)
    tmp = "#{HANDOFF_PATH}.#{$$}.new"
    File.write(tmp, JSON.pretty_generate(cfg))
    File.chmod(0o600, tmp)
    File.rename(tmp, HANDOFF_PATH)
  ensure
    File.unlink(tmp) if tmp && File.exist?(tmp)
  end

  # A coordinator can be killed after cancelling the old daemon's queues but
  # before replacing it. Preserve every current-boot intent already captured
  # by that attempt when the administrator reruns switch-to-configuration.
  def merge_existing_handoff
    cfg = load_current_handoff
    return unless cfg

    cfg['containers'].each do |entry|
      remember_handoff(entry['pool'], entry['id'], current: false)
      priority = entry['priority']
      next unless priority.is_a?(Integer)

      remember_active_handoff(entry['pool'], entry['id'], priority)
    end
    cfg['runtime_containers'].each do |entry|
      remember_runtime(entry['pool'], entry['id'])
    end
  end

  def current_boot_handoff?
    !load_current_handoff.nil?
  end

  def load_current_handoff
    cfg = JSON.parse(File.read(HANDOFF_PATH))
    unless cfg.is_a?(Hash) && cfg['boot_id'].is_a?(String)
      raise "invalid osctld runtime handoff at #{HANDOFF_PATH}"
    end
    return unless cfg['boot_id'] == File.read(boot_id_path).strip

    validate_current_handoff!(cfg)

    cfg
  rescue Errno::ENOENT
    nil
  rescue JSON::ParserError => e
    raise "invalid osctld runtime handoff at #{HANDOFF_PATH}: #{e.message}"
  end

  def validate_current_handoff!(cfg)
    valid_root = cfg.keys.sort == %w[
      boot_id containers created_at runtime_containers schema
    ] \
      && cfg['schema'] == 1 \
      && cfg['created_at'].is_a?(Numeric) \
      && cfg['created_at'].finite? \
      && cfg['created_at'] >= 0
    raise "invalid osctld runtime handoff at #{HANDOFF_PATH}" unless valid_root

    validate_handoff_entries!(cfg.fetch('containers'), runtime: false)
    validate_handoff_entries!(cfg.fetch('runtime_containers'), runtime: true)
  end

  def validate_handoff_entries!(entries, runtime:)
    unless entries.is_a?(Array)
      raise "invalid osctld runtime handoff at #{HANDOFF_PATH}"
    end

    seen = {}
    entries.each do |entry|
      allowed_keys = runtime ? %w[id pool source] : %w[id pool priority source]
      required_keys = %w[id pool source]
      valid = entry.is_a?(Hash) \
        && (entry.keys - allowed_keys).empty? \
        && (required_keys - entry.keys).empty? \
        && entry['pool'].is_a?(String) \
        && !entry['pool'].empty? \
        && entry['id'].is_a?(String) \
        && !entry['id'].empty? \
        && entry['source'] == HANDOFF_SOURCE \
        && (runtime || !entry.has_key?('priority') || entry['priority'].is_a?(Integer))
      raise "invalid osctld runtime handoff at #{HANDOFF_PATH}" unless valid

      key = [entry['pool'], entry['id']]
      value = runtime ? true : [entry.has_key?('priority'), entry['priority']]
      if seen.has_key?(key) && seen[key] != value
        raise "conflicting duplicate in osctld runtime handoff at #{HANDOFF_PATH}"
      end

      seen[key] = value
    end
  end

  def restore_legacy_handoff
    return unless legacy

    failures = []
    restored_intents = []
    @handoff_queues.each do |entry|
      unless @legacy_cancelled_pools.include?(entry.fetch('pool'))
        restored_intents << [entry.fetch('pool'), entry.fetch('id')]
        next
      end

      key = [entry.fetch('pool'), entry.fetch('id'), entry.fetch('priority')]
      next if @legacy_restored_entries.include?(key)

      queued = legacy_queue_contains?(entry.fetch('pool'), entry.fetch('id'))
      restored = queued || run_osctl(
        '--pool', entry.fetch('pool'),
        'ct', 'start', '--queue',
        '--priority', entry.fetch('priority').to_s,
        entry.fetch('id')
      )
      if restored
        @legacy_restored_entries << key
        restored_intents << key.first(2)
      else
        failures << "#{entry.fetch('pool')}:#{entry.fetch('id')}"
      end
    end

    @handoff_active.each do |entry|
      key = [entry.fetch('pool'), entry.fetch('id')]
      next if @legacy_restored_intents.include?(key)

      restored = legacy_started_containers(entry.fetch('pool')).include?(entry.fetch('id')) \
        || legacy_queue_contains?(entry.fetch('pool'), entry.fetch('id')) \
        || run_osctl(
          '--pool', entry.fetch('pool'),
          'ct', 'start', '--queue',
          '--priority', entry.fetch('priority').to_s,
          entry.fetch('id')
        )
      if restored
        @legacy_restored_intents << key
        restored_intents << key
      else
        failures << "#{entry.fetch('pool')}:#{entry.fetch('id')}"
      end
    end

    unless failures.empty?
      raise "unable to restore legacy autostart queue: #{failures.join(', ')}; " \
            "retaining #{HANDOFF_PATH}"
    end

    # Anything observed by this coordinator is owned by the restored legacy
    # daemon again. Keep entries inherited from an earlier interrupted
    # coordinator when they were no longer visible in the legacy queues or
    # process state; only a successful target daemon can persist those.
    @handoff_desired -= restored_intents
    @handoff_queues.clear
    @handoff_active.clear
    @handoff_runtime.clear
    @legacy_cancelled_pools.clear
    @current_handoff_observed.clear
    if @handoff_desired.empty?
      FileUtils.rm_f(HANDOFF_PATH)
    else
      write_handoff
    end

    return unless legacy_nodectld_paused

    restore_nodectld_supervision
    raise 'unable to resume nodectld after legacy handoff rollback' \
      unless resume_nodectld_after_barrier

    @legacy_nodectld_paused = false
    @nodectld_pause_reason = nil
  end

  def nodectld_remote(command)
    reply = nodectld_remote_reply(command)
    reply && reply['status'] == 'ok'
  end

  def nodectld_remote_reply(command)
    Timeout.timeout(5) do
      socket = UNIXSocket.new('/run/nodectl/nodectld.sock')
      greeting = socket.gets
      return unless greeting && JSON.parse(greeting).has_key?('version')

      socket.puts(JSON.generate(command:, params: {}))
      reply = socket.gets
      return unless reply

      JSON.parse(reply)
    ensure
      socket&.close
    end
  rescue StandardError => e
    warn "nodectld remote #{command} failed: #{e.class}: #{e.message}"
    nil
  end

  def target_nodectld_barrier_active?
    reply = nodectld_remote_reply(:status)
    return false unless reply && reply['status'] == 'ok'

    state = reply.dig('response', 'state')
    state.is_a?(Hash) \
      && state['pause'] == true \
      && state['restart_barrier'] == true
  end

  def wait_nodectld_remote(command)
    deadline = monotonic_now + service_stop_timeout

    loop do
      return true if nodectld_remote(command)
      return false if monotonic_now >= deadline

      sleep(0.2)
    end
  end

  def resume_nodectld_after_barrier
    return false unless wait_nodectld_remote(:resume)

    # Once osctld is ready it is safe for a replacement nodectld to start
    # unpaused. Remove the marker, then verify the currently supervised process
    # is also unpaused. If it restarted after acknowledging the first RPC but
    # before marker removal, the verification loop resumes that new process.
    release = release_nodectld_pause(@nodectld_pause_reason)
    return false if release == :deferred
    return true if wait_for_nodectld_unpaused

    persist_nodectld_resume_retry
    false
  end

  def wait_for_nodectld_unpaused
    deadline = monotonic_now + service_stop_timeout

    loop do
      return true if nodectld_unpaused?
      return false if monotonic_now >= deadline

      nodectld_remote(:resume)
      sleep(0.2)
    end
  end

  def nodectld_unpaused?
    reply = nodectld_remote_reply(:status)
    return false unless reply && reply['status'] == 'ok'

    state = reply.dig('response', 'state')
    state.is_a?(Hash) && state.has_key?('pause') && state['pause'] != true
  end

  def persist_nodectld_resume_retry
    cfg = {
      'schema' => 1,
      'boot_id' => File.read(boot_id_path).strip,
      'created_at' => Time.now.to_f,
      'reason' => 'osctld-restart'
    }
    with_nodectld_pause_lock do
      existing = JSON.parse(File.read(nodectld_pause_path))
      current_boot = File.read(boot_id_path).strip
      if !existing.is_a?(Hash) || !existing['boot_id'].is_a?(String) \
          || (existing['boot_id'] == current_boot \
            && (existing['schema'] != 1 \
              || existing['reason'] != 'osctld-restart'))
        return false
      end

      write_nodectld_pause(cfg) if existing['boot_id'] != current_boot
      true
    rescue Errno::ENOENT
      write_nodectld_pause(cfg)
      true
    rescue JSON::ParserError
      false
    end
  end

  def release_nodectld_pause(reason)
    with_nodectld_pause_lock do
      cfg = JSON.parse(File.read(nodectld_pause_path))
      current_boot = File.read(boot_id_path).strip
      return :deferred unless cfg.is_a?(Hash) \
        && cfg['schema'] == 1 \
        && cfg['boot_id'] == current_boot \
        && cfg['reason'] == reason

      File.unlink(nodectld_pause_path)
      :released
    rescue Errno::ENOENT
      :absent
    rescue JSON::ParserError
      :deferred
    end
  end

  def with_nodectld_pause_lock
    FileUtils.mkdir_p(File.dirname(nodectld_pause_lock_path))
    File.open(
      nodectld_pause_lock_path,
      File::RDWR | File::CREAT,
      0o600
    ) do |lock|
      lock.flock(File::LOCK_EX)
      yield
    end
  end

  def write_nodectld_pause(cfg)
    dir = File.dirname(nodectld_pause_path)
    FileUtils.mkdir_p(dir)
    tmp = "#{nodectld_pause_path}.#{$$}.new"
    File.write(tmp, JSON.pretty_generate(cfg))
    File.chmod(0o600, tmp)
    File.rename(tmp, nodectld_pause_path)
  ensure
    File.unlink(tmp) if tmp && File.exist?(tmp)
  end

  def wait_for_legacy_nodectld_idle
    deadline = monotonic_now + legacy_settle_timeout

    loop do
      reply = nodectld_remote_reply(:status)
      return true if reply && nodectld_idle?(reply)
      return false if monotonic_now >= deadline

      sleep(0.2)
    end
  end

  def nodectld_idle?(reply)
    return false unless reply['status'] == 'ok'

    response = reply['response']
    return false unless response.is_a?(Hash)

    queues = response['queues']
    subprocesses = response['subprocesses']
    queues.is_a?(Hash) \
      && queues.values.all? do |queue|
        queue.is_a?(Hash) && queue['workers'].is_a?(Hash) \
          && queue['workers'].empty?
      end \
      && subprocesses.is_a?(Hash) \
      && subprocesses.empty?
  end

  def restore_nodectld_supervision
    return unless @legacy_nodectld_down_created

    if File.exist?(nodectld_down_path)
      content = File.read(nodectld_down_path)
      unless content == NODECTLD_DOWN_CONTENT
        raise "refusing to remove unowned nodectld down file at #{nodectld_down_path}"
      end

      File.unlink(nodectld_down_path)
    end

    raise 'unable to restore nodectld runit supervision' \
      unless run_svc('-u', 'nodectld')

    @legacy_nodectld_down_created = false
  end

  def legacy_nodectld_pause?
    @nodectld_pause_reason == 'legacy-osctld-runtime-upgrade'
  end

  def restart_target_nodectld
    raise 'unable to stop legacy nodectld before replacement' \
      unless run_svc('-d', 'nodectld')
    raise 'recorded legacy nodectld process did not stop before replacement' \
      unless stop_recorded_legacy_nodectld
    raise 'legacy nodectld did not stop before replacement' \
      unless wait_named_service_down('nodectld')

    restore_nodectld_supervision
    raise 'target nodectld did not honor the restart barrier' \
      unless wait_target_nodectld_barrier

    @target_nodectld_restarted = true
  end

  def stop_recorded_legacy_nodectld
    identity = @legacy_nodectld_identity
    signal_process_identity(identity, 'TERM', service: 'nodectld')
    return true if !process_identity_alive?(identity) \
      && service_cgroup_empty?('nodectld')

    deadline = monotonic_now + service_stop_timeout
    loop do
      return true if !process_identity_alive?(identity) \
        && service_cgroup_empty?('nodectld')
      return false if monotonic_now >= deadline

      sleep(0.2)
    end
  end

  def service_process_identity(name)
    pid_path = File.join(SERVICE_DIR, name, 'supervise/pid')
    pid = File.read(pid_path).to_i
    return if pid <= 0

    stat = process_stat(pid)
    return unless stat

    identity = {
      'pid' => pid,
      'start_time_ticks' => stat.fetch(:start_time_ticks)
    }
    return unless runsv_service_process?(name, pid, stat.fetch(:parent_pid))
    return unless File.read(pid_path).to_i == pid

    identity if process_identity_alive?(identity)
  rescue Errno::ENOENT, Errno::ESRCH
    nil
  end

  def runsv_service_process?(name, pid, parent_pid)
    return false if parent_pid <= 0

    cmdline = File.binread(
      File.join(PROC_DIR, parent_pid.to_s, 'cmdline')
    ).split("\0")
    return false unless File.basename(cmdline.fetch(0)) == 'runsv'
    return false unless File.basename(cmdline.fetch(1)) == name

    cgroup_pids = service_cgroup_pids(name)
    return false unless cgroup_pids.include?(pid)

    current_stat = process_stat(pid)
    current_stat && current_stat.fetch(:parent_pid) == parent_pid
  rescue Errno::ENOENT, Errno::ESRCH, IndexError
    false
  end

  def service_cgroup_pids(name)
    File.readlines(
      File.join(RUNIT_SERVICE_CGROUP_DIR, name, 'cgroup.procs')
    ).filter_map do |line|
      Integer(line.strip, 10)
    rescue ArgumentError
      nil
    end
  end

  def service_cgroup_empty?(name)
    cgroup = File.join(RUNIT_SERVICE_CGROUP_DIR, name)
    events_path = File.join(cgroup, 'cgroup.events')
    if File.exist?(events_path)
      events = File.readlines(events_path).map(&:split)
      return false unless events.all? { |fields| fields.length == 2 }

      populated = events.filter_map do |key, value|
        value if key == 'populated'
      end
      return populated == ['0']
    end

    tasks_path = File.join(cgroup, 'tasks')
    return false unless File.exist?(tasks_path)

    File.foreach(tasks_path).none? { |line| !line.strip.empty? }
  rescue Errno::ENOENT, Errno::ESRCH
    false
  end

  def process_stat(pid)
    raw = File.read(File.join(PROC_DIR, pid.to_s, 'stat'))
    closing_parenthesis = raw.rindex(')')
    return unless closing_parenthesis

    fields = raw[closing_parenthesis + 2..].split
    return if fields.length <= 19

    {
      state: fields.fetch(0),
      parent_pid: Integer(fields.fetch(1), 10),
      start_time_ticks: Integer(fields.fetch(19), 10)
    }
  rescue Errno::ENOENT, Errno::ESRCH, ArgumentError
    nil
  end

  def valid_process_identity?(identity)
    identity.is_a?(Hash) \
      && identity['pid'].is_a?(Integer) \
      && identity['pid'] > 0 \
      && identity['start_time_ticks'].is_a?(Integer) \
      && identity['start_time_ticks'] > 0
  end

  def process_identity_alive?(identity)
    return false unless valid_process_identity?(identity)

    stat = process_stat(identity.fetch('pid'))
    return false unless stat
    return false unless stat.fetch(:start_time_ticks) == identity.fetch('start_time_ticks')
    return false if DEAD_PROCESS_STATES.include?(stat.fetch(:state))

    Process.kill(0, identity.fetch('pid'))
    true
  rescue Errno::ENOENT, Errno::ESRCH
    false
  end

  def signal_process_identity(identity, signal, service:)
    pidfd = open_process_identity(identity, service:)
    return false unless pidfd

    ret = LinuxPidfd.pidfd_send_signal(
      pidfd.fileno,
      Signal.list.fetch(signal),
      nil,
      0
    )
    raise SystemCallError.new('pidfd_send_signal', Fiddle.last_error) if ret == -1

    true
  rescue Errno::ESRCH
    false
  ensure
    pidfd&.close
  end

  def open_process_identity(identity, service:)
    return unless valid_process_identity?(identity)

    pid = identity.fetch('pid')
    fd = LinuxPidfd.pidfd_open(pid, 0)
    raise SystemCallError.new('pidfd_open', Fiddle.last_error) if fd == -1

    pidfd = IO.for_fd(fd)
    stat = process_stat(pid)
    return pidfd.close unless stat
    return pidfd.close \
      unless stat.fetch(:start_time_ticks) == identity.fetch('start_time_ticks')
    return pidfd.close if DEAD_PROCESS_STATES.include?(stat.fetch(:state))
    return pidfd.close unless service_cgroup_pids(service).include?(pid)

    pidfd
  rescue Errno::ENOENT, Errno::ESRCH
    pidfd&.close
    nil
  rescue StandardError
    pidfd&.close
    raise
  end

  def wait_named_service_down(name)
    deadline = monotonic_now + service_stop_timeout

    loop do
      return true unless service_running?(name)
      return false if monotonic_now >= deadline

      sleep(0.2)
    end
  end

  def wait_target_nodectld_barrier
    deadline = monotonic_now + service_stop_timeout

    loop do
      return true if target_nodectld_barrier_active?
      return false if monotonic_now >= deadline

      sleep(0.2)
    end
  end

  def remember_handoff(pool, id, current: true)
    key = [pool, id]
    @handoff_desired << key unless @handoff_desired.include?(key)
    return unless current && !@current_handoff_observed.include?(key)

    @current_handoff_observed << key
  end

  def remember_runtime(pool, id)
    key = [pool, id]
    @handoff_runtime << key unless @handoff_runtime.include?(key)
  end

  def replace_runtime_handoff(containers)
    @handoff_runtime = containers.filter_map do |ct|
      next unless %w[running frozen].include?(ct.fetch('runtime_state'))

      [ct.fetch('pool'), ct.fetch('id')]
    end.uniq
  end

  def remember_active_handoff(pool, id, priority)
    remember_handoff_priority(pool, id, priority)
    return if @handoff_active.any? do |entry|
      entry['pool'] == pool && entry['id'] == id
    end

    @handoff_active << { 'pool' => pool, 'id' => id, 'priority' => priority }
  end

  def remember_legacy_start_handoff(ct)
    return unless LEGACY_START_STATES.include?(ct.fetch('runtime_state'))

    pool = ct.fetch('pool')
    id = ct.fetch('id')
    remember_handoff(pool, id)
    return unless ct['autostart'] == true

    priority = ct.fetch('autostart_priority', 10) || 10
    remember_active_handoff(pool, id, priority)
  end

  def remember_handoff_priority(pool, id, priority)
    @handoff_priorities[[pool, id]] = priority
  end

  def legacy_started_containers(pool)
    File.readlines(
      File.join('/run/osctl/pools', pool, 'auto-start', 'started-cts.txt'),
      chomp: true
    ).reject(&:empty?).uniq
  rescue Errno::ENOENT
    []
  end

  def legacy_queue_contains?(pool, id)
    osctl_json('pool', 'autostart', 'queue', pool).any? do |entry|
      entry.fetch('id') == id
    end
  rescue StandardError
    false
  end

  def wait_service_down
    timeout = legacy ? legacy_settle_timeout : service_stop_timeout
    deadline = monotonic_now + timeout

    loop do
      return true unless service.running?
      return false if monotonic_now >= deadline

      sleep(0.2)
    end
  end

  def wait_for_target_ready
    deadline = monotonic_now + ready_timeout

    loop do
      remaining = deadline - monotonic_now
      return false if remaining <= 0
      return true if run_osctl(
        'daemon',
        'wait-ready',
        '--timeout',
        remaining.ceil.to_s
      )

      sleep([0.2, remaining].min)
    end
  end

  def wait_for_legacy_daemon
    deadline = monotonic_now + service_stop_timeout

    loop do
      begin
        status = osctl_json('daemon', 'status')
        return true if status['initialized']
      rescue StandardError
        # The old daemon can be between processes while runit restarts it.
      end

      raise 'legacy osctld did not return after an aborted handoff' \
        if monotonic_now >= deadline

      sleep(0.2)
    end
  end

  def service_running?(name)
    pid = File.read(File.join(SERVICE_DIR, name, 'supervise/pid')).to_i
    return false if pid <= 0

    Process.kill(0, pid)
    true
  rescue Errno::ENOENT, Errno::ESRCH
    false
  end

  def service_supervised?(name)
    File.directory?(File.join(SERVICE_DIR, name))
  end

  def osctl_json(*args)
    output, error, status = Open3.capture3(
      File.join(Configuration::NEW_BIN, 'osctl'),
      '--json',
      *args
    )
    unless status.success?
      raise "osctl #{args.join(' ')} failed: #{error.strip}"
    end

    JSON.parse(output)
  rescue JSON::ParserError => e
    raise "osctl #{args.join(' ')} returned invalid JSON: #{e.message}"
  end

  def run_osctl(*args)
    puts "> osctl #{args.join(' ')}"
    system(File.join(Configuration::NEW_BIN, 'osctl'), *args)
  end

  def run_osctl!(*args)
    return true if run_osctl(*args)

    raise "osctl #{args.join(' ')} failed"
  end

  def run_svc(option, name)
    action = option.delete_prefix('-')
    puts "> sv #{action} #{name}"
    system(File.join(Configuration::CURRENT_BIN, 'sv'), action, name)
  end

  def monotonic_now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end

class Services
  class ServiceNameList
    def initialize(path)
      @services = parse(path)
    end

    def include?(name)
      @services.any? { |v| File.fnmatch?(v, name) }
    end

    protected

    def parse(path)
      ret = []

      File.open(path) do |f|
        f.each_line { |line| ret << line.strip }
      end

      ret
    rescue Errno::ENOENT
      []
    end
  end

  Service = Struct.new(:name, :etc_path, :cfg, :opts) do
    attr_reader :run_path, :on_change, :reload_method, :restart_triggers

    def initialize(*_)
      super
      @run_path = File.realpath(File.join(etc_path, 'runit/services', name, 'run'))
      @on_change = cfg['onChange'].to_sym
      @reload_method = cfg['reloadMethod']
      @restart_triggers = cfg.fetch('restartTriggers', [])
    end

    def ==(other)
      run_path == other.run_path && restart_triggers == other.restart_triggers
    end

    def restart_triggers_changed?(other)
      restart_triggers != other.restart_triggers
    end

    %i[start stop restart].each do |m|
      define_method(m) do
        if opts[:skip]
          puts "> skip service #{name}"
          next
        end

        puts "> sv #{m} #{name}"

        return if opts[:dry_run]

        system(File.join(Configuration::CURRENT_BIN, 'sv'), m.to_s, name)
      end
    end

    def reload
      if opts[:skip]
        puts "> skip service #{name}"
        return
      end

      puts "> sv #{reload_method} #{name}"

      return if opts[:dry_run]

      system(File.join(Configuration::CURRENT_BIN, 'sv'), reload_method, name)
    end

    def skip
      puts "> skipping #{name}"
    end

    def skip?
      opts[:skip]
    end

    def running?
      pid = File.read(File.join('/service', name, 'supervise/pid')).to_i
      return false if pid <= 0

      Process.kill(0, pid)
      true
    rescue Errno::ENOENT, Errno::ESRCH
      false
    end
  end

  def initialize(dry_run: true)
    @opts = { dry_run: }

    @old_cfg = read_cfg(File.join(Configuration::CURRENT_SYSTEM, '/services'))
    @new_cfg = read_cfg(File.join(Configuration::OUT, '/services'))

    @old_runlevel = File.basename(File.realpath('/service'))
    @new_runlevel = get_runlevel(@new_cfg, @old_runlevel)

    @protected_list = ServiceNameList.new('/run/runit/protected-services.txt')

    @old_services = get_services(@old_cfg, @old_runlevel, '/etc')
    @new_services = get_services(@new_cfg, @new_runlevel, Configuration::ETC)
  end

  # Services that are new and should be started
  # @return [Array<Service>]
  def start
    (new_services.keys - old_services.keys).map { |s| new_services[s] }
  end

  # Services that have been removed and should be stopped
  # @return [Array<Service>]
  def stop
    (old_services.keys - new_services.keys).map { |s| old_services[s] }
  end

  # Services that have been changed and should be restarted
  # @return [Array<Service>]
  def restart
    (old_services.keys & new_services.keys).select do |s|
      old_service = old_services[s]
      new_service = new_services[s]

      new_service.restart_triggers_changed?(old_service) \
        || (old_service != new_service && new_service.on_change == :restart)
    end.map { |s| new_services[s] }
  end

  def osctld_restart
    restart.detect { |service| service.name == 'osctld' && !service.skip? }
  end

  # Return the osctld service from the target configuration even when its run
  # script no longer differs. An interrupted legacy handoff can leave runit
  # down after the target configuration was already activated; a retry must be
  # able to start that unchanged target service.
  def osctld_target
    service = new_services['osctld']
    service unless service&.skip?
  end

  def restart_before_osctld
    deferred_nodectld = deferred_nodectld_restart

    restart.reject do |service|
      (service.name == 'osctld' && !service.skip?) \
        || (deferred_nodectld && service == deferred_nodectld)
    end
  end

  # Keep the old nodectld process available while osctld drains and starts. A
  # logical remote pause prevents new transactions without suppressing osctld
  # callbacks. Restart changed nodectld only after osctld is ready again.
  def deferred_restart_after_osctld(nodectld_restarted: false)
    return [] if nodectld_restarted

    [deferred_nodectld_restart].compact
  end

  def restart_after_osctld(nodectld_restarted: false)
    restart.reject do |service|
      (service.name == 'osctld' && !service.skip?) \
        || (nodectld_restarted && service.name == 'nodectld')
    end
  end

  # Services that have been changed and should be reloaded
  # @return [Array<Service>]
  def reload
    services = (old_services.keys & new_services.keys).select do |s|
      old_service = old_services[s]
      new_service = new_services[s]

      !new_service.restart_triggers_changed?(old_service) \
        && old_service != new_service \
        && new_service.on_change == :reload
    end.map { |s| new_services[s] }

    kernel_modules, other = services.partition { |svc| svc.name == 'kernel-modules' }
    kernel_modules + other
  end

  def switch_runlevel
    return if old_runlevel == new_runlevel

    if opts[:dry_run]
      puts 'would switch runlevel...'
    else
      puts 'switching runlevel...'
    end

    puts "> runsvchdir #{new_runlevel}"
    return if opts[:dry_run]

    system(File.join(Configuration::CURRENT_BIN, 'runsvchdir'), new_runlevel)
  end

  protected

  attr_reader :old_cfg, :new_cfg, :protected_list, :old_services, :new_services, :old_runlevel, :new_runlevel, :opts

  def nodectld_restart
    restart.detect { |service| service.name == 'nodectld' && !service.skip? }
  end

  def deferred_nodectld_restart
    osctld_restart && nodectld_restart
  end

  # Parse service config
  # @param path [String]
  # @return [Hash]
  def read_cfg(path)
    JSON.parse(File.read(path))
  end

  # Return services from a selected runlevel
  # @param cfg [Hash] service config
  # @param runlevel [String] include only services from this runlevel
  # @param etc_dir [String] absolute path to a directory containing the system's
  #                          `/etc`
  # @return [Hash<String, Service>]
  def get_services(cfg, runlevel, etc_dir)
    ret = {}

    cfg['services'].each do |name, service|
      next unless service['runlevels'].include?(runlevel)

      begin
        ret[name] = Service.new(
          name,
          etc_dir,
          service,
          opts.merge({ skip: protected_list.include?(name) })
        )
      rescue Errno::ENOENT
        warn "service '#{name}' not found"
        next
      end
    end

    ret
  end

  # Return target runlevel
  def get_runlevel(cfg, old_runlevel)
    if cfg['defaultRunlevel'] == old_runlevel \
        || cfg['services'].map { |_k, v| v['runlevels'] }.flatten.include?(old_runlevel)
      old_runlevel

    else
      cfg['defaultRunlevel']
    end
  end
end

class PoolFlags
  KNOWN_FLAGS = %w[export stop].freeze

  def initialize(string_flags)
    @flags = {}

    KNOWN_FLAGS.each do |flag|
      @flags[flag] = false
    end

    if string_flags.nil?
      set_default_flags
      return
    end

    string_flags.split(',').each do |flag|
      next if flag == '-'

      unless KNOWN_FLAGS.include?(flag)
        warn "unknown pool flag '#{flag}', using safe defaults"
        set_default_flags
        break
      end

      @flags[flag] = true
    end
  end

  KNOWN_FLAGS.each do |flag|
    define_method(:"flag_#{flag}?") { @flags[flag] }
  end

  def export_pool?
    @flags['export']
  end

  def stop_containers?
    @flags['stop']
  end

  protected

  def set_default_flags
    @flags.update({
      'export' => true,
      'stop' => true
    })
  end
end

class Pools
  Pool = Struct.new(:name, :state, :rollback_version, :flags)

  attr_reader :uptodate, :to_upgrade, :to_rollback, :error

  def initialize(dry_run: true)
    @opts = { dry_run: }

    @uptodate = []
    @to_upgrade = []
    @to_rollback = []
    @error = []

    @old_pools = check(Configuration::CURRENT_BIN)
    @new_pools = check(Configuration::NEW_BIN)

    resolve
  end

  # Rollback pools using the current OS version, as the activated OS version
  # is older
  def rollback
    to_rollback.each do |pool|
      puts "> rolling back pool #{pool.name}"
      next if opts[:dry_run]

      ret = system(
        File.join(Configuration::CURRENT_BIN, 'osup'),
        'rollback', pool.name, pool.rollback_version
      )

      unless ret
        raise "rollback of pool #{pool.name} failed, cannot proceed"
      end
    end
  end

  # Export pools from osctld before upgrade
  #
  # Depending on `osup check`, this will stop all containers from outdated pools.
  # We're counting on the fact that if there are new migrations, then osctld has
  # to have changed as well, so it is restarted by {Services}. After restart,
  # osctld will run `osup upgrade` on all imported pools.
  def export
    to_rollback.each do |pool|
      check_rollback = `#{File.join(Configuration::CURRENT_BIN, 'osup')} check-rollback "#{pool.name}" "#{pool.rollback_version}"`
      rollback_flags = PoolFlags.new($?.exitstatus == 0 ? check_rollback.strip : nil)

      export_pool(pool, rollback_flags, 'rollback')
    end

    to_upgrade.each do |pool|
      export_pool(pool, pool.flags, 'upgrade')
    end
  end

  protected

  attr_reader :opts, :old_pools, :new_pools

  def resolve
    new_pools.each do |name, pool|
      case pool.state
      when :ok
        uptodate << pool

      when :outdated
        to_upgrade << pool

      when :incompatible
        if old_pools[name] && old_pools[name].state == :ok
          to_rollback << pool

        else
          error << pool
        end
      end
    end
  end

  def export_pool(pool, flags, action)
    unless flags.export_pool?
      puts "> pool #{pool.name} is ready for #{action}"
      return
    end

    if flags.stop_containers?
      puts "> stopping containers and exporting pool #{pool.name} to #{action}"
    else
      puts "> exporting pool #{pool.name} to #{action}, not stopping containers"
    end

    return if opts[:dry_run]

    # TODO: do not fail if the pool is not imported

    cmd = [
      File.join(Configuration::CURRENT_BIN, 'osctl'),
      'pool',
      'export',
      '-f'
    ]

    cmd << if flags.stop_containers?
             '--stop-containers'
           else
             '--no-stop-containers'
           end

    cmd << pool.name

    ret = system(*cmd)

    return if ret

    raise "export of pool #{pool.name} failed, cannot proceed"
  end

  def check(swbin)
    ret = {}

    IO.popen("#{File.join(swbin, 'osup')} check") do |io|
      io.each_line do |line|
        name, state, version, flags = line.strip.split
        ret[name] = Pool.new(name, state.to_sym, version, PoolFlags.new(flags))
      end
    end

    ret
  rescue Errno::ENOENT
    # osup isn't available in the to-be-replaced OS version
    {}
  end
end

if __FILE__ == $0
  case ARGV[0]
  when 'boot'
    Configuration.boot
  when 'switch'
    Configuration.switch
  when 'test'
    Configuration.test
  when 'dry-activate'
    Configuration.dry_run
  else
    warn "Usage: #{$0} switch|boot|test|dry-activate"
    exit(false)
  end
end
