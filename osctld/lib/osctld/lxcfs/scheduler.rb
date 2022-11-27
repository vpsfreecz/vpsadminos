require 'libosctl'
require 'singleton'

module OsCtld
  # Assigns containers to LXCFS workers
  class Lxcfs::Scheduler
    include Singleton
    include Lockable

    include OsCtl::Lib::Utils::Log
    include OsCtl::Lib::Utils::File

    STATE_FILE = File.join(RunState::LXCFS_DIR, 'scheduler.yml')

    class << self
      %i(
        assets setup stop assign_ctrc remove_ct worker_by_name change_worker
        add_legacy_perct_worker prune_workers export_workers
      ).each do |v|
        define_method(v) do |*args, **kwargs, &block|
          instance.send(v, *args, **kwargs, &block)
        end
      end
    end

    def initialize
      init_lock
      @workers = {}
      @containers = {}
      @worker_id = 0
      @save_queue = OsCtl::Lib::Queue.new
      @gc_queue = OsCtl::Lib::Queue.new
    end

    def assets(add)
      add.directory(
        RunState::LXCFS_DIR,
        desc: 'osctl-lxcfs root directory',
        user: 0,
        group: 0,
        mode: 0711,
      )
      add.directory(
        Lxcfs::Server::RUNDIR_SERVERS,
        desc: 'LXCFS runit services',
        user: 0,
        group: 0,
        mode: 0755,
      )
      add.directory(
        Lxcfs::Server::RUNDIR_RUNSVDIR,
        desc: 'LXCFS runsv directory',
        user: 0,
        group: 0,
        mode: 0755,
      )
      add.directory(
        Lxcfs::Server::RUNDIR_MOUNTROOT,
        desc: 'LXCFS mount root',
        user: 0,
        group: 0,
        mode: 0755,
      )
      add.file(
        STATE_FILE,
        desc: 'Lxcfs scheduler state',
        user: 0,
        group: 0,
        mode: 0400,
      )

      @workers.each_value do |w|
        w.assets(add)
      end
    end

    def setup
      load_state
      @save_thread = Thread.new { run_save }
      @gc_thread = Thread.new { run_gc }
    end

    def stop
      if @save_thread
        @save_queue.clear
        @save_queue << :stop
        @save_thread.join
        @save_thread = nil
      end

      if @gc_thread
        @gc_queue.clear
        @gc_queue << [:stop]
        @gc_thread.join
        @gc_thread = nil
      end
    end

    # Assign container to a LXCFS worker
    #
    # This method blocks until the LXCFS instance is available for use.
    #
    # @param ctrc [Container::RunConfiguration]
    # @raise [Lxcfs::Timeout]
    def assign_ctrc(ctrc)
      return unless ctrc.ct.lxcfs.enable

      worker, created = get_or_create_worker(ctrc)
      worker.start if created
      request_save
      worker.wait
      ctrc.lxcfs_worker = worker
      ctrc.save
      nil
    end

    # @param ct [Container]
    def remove_ct(ct)
      worker = nil

      exclusively do
        worker = @containers[ct.ident]
        return if worker.nil?

        worker.remove_user
        @containers.delete(ct.ident)
      end

      request_save

      nil
    end

    # @param name [String]
    # @return [Lxcfs::Worker, nil]
    def worker_by_name(name)
      inclusively { @workers[name] }
    end

    # @param name [String]
    # @yieldparam [Lxcfs::Worker]
    # @raise [Lxcfs::WorkerNotFound]
    def change_worker(name)
      worker = inclusively { @workers[name] }
      raise Lxcfs::WorkerNotFound, name if worker.nil?
      ret = yield(worker)
      request_save
      ret
    end

    # @param ctrc [Container::RunConfiguration]
    # @return [Lxcfs::Worker]
    def add_legacy_perct_worker(ctrc)
      worker = nil

      exclusively do
        name = "ct.#{ctrc.ident}"
        return @workers[name] if @workers.has_key?(name)

        lxcfs = ctrc.ct.lxcfs

        worker = Lxcfs::Worker.new(
          name,
          max_size: 1,
          loadavg: lxcfs.loadavg,
          cfs: lxcfs.cfs,
          enabled: false,
        )
        worker.add_user

        @workers[worker.name] = worker
        @containers[ctrc.ident] = worker
        @worker_id += 1

        log(:info, "#{ctrc.ident} created legacy worker #{worker.name}")
      end

      worker.adjust_legacy_worker

      request_save
      worker
    end

    def prune_workers
      request_prune
    end

    def export_workers
      inclusively { @workers.each_value.map(&:export) }
    end

    def log_type
      @log_type ||= 'lxcfs-scheduler'
    end

    protected
    def get_or_create_worker(ctrc)
      worker = nil
      existing = false
      created = false

      exclusively do
        existing_worker = @containers[ctrc.ident]

        if existing_worker
          if existing_worker.can_handle_ctrc?(ctrc, check_size: false)
            worker = existing_worker
            existing = true
            log(:info, "#{ctrc.ident} kept on #{worker.name}")
            next
          else
            existing_worker.remove_user
            @containers.delete(ctrc.ident)
            log(:info, "#{ctrc.ident} needs to be reassigned from #{existing_worker.name}")
          end
        end

        worker =
          @workers.each_value.select do |w|
            w.can_handle_ctrc?(ctrc)
          end.sort do |a, b|
            b.size <=> a.size
          end.first

        if worker.nil?
          created = true
          name = nil

          loop do
            name = gen_worker_name(ctrc.cpu_package)
            @worker_id += 1
            break unless @workers.has_key?(name)
          end

          worker = Lxcfs::Worker.new_for_ctrc(name, ctrc)
          @workers[worker.name] = worker

          log(:info, "Creating new worker #{worker.name} for #{ctrc.ident}")
        else
          log(:info, "#{ctrc.ident} assigned to existing #{worker.name}")
        end

        @containers[ctrc.ident] = worker
      end

      worker.add_user unless existing
      [worker, created]
    end

    def gen_worker_name(cpu_package)
      ret = "worker.#{@worker_id}."
      ret << (cpu_package ? "cpu#{cpu_package}" : 'cpuall')
      ret
    end

    def dump_state
      inclusively do
        worker_cts = {}

        @containers.each do |ctid, worker|
          worker_cts[worker.name] ||= []
          worker_cts[worker.name] << ctid
        end

        {
          'worker_id' => @worker_id,
          'workers' => @workers.each_value.map do |w|
            {
              'options' => w.dump,
              'containers' => worker_cts[w.name] || [],
            }
          end,
        }
      end
    end

    def save_state
      data = dump_state

      regenerate_file(STATE_FILE, 0400) do |new|
        new.write(OsCtl::Lib::ConfigFile.dump_yaml(data))
      end

      File.chown(0, 0, STATE_FILE)
    end

    def load_state
      begin
        data = OsCtl::Lib::ConfigFile.load_yaml_file(STATE_FILE)
      rescue Errno::ENOENT
        return
      end

      data['workers'].each do |w_data|
        worker = Lxcfs::Worker.load(w_data['options'])
        @workers[worker.name] = worker

        w_data['containers'].each do |ctid|
          worker.add_user
          @containers[ctid] = worker
        end

        worker.setup
      end

      @worker_id = data.fetch('worker_id', @workers.size)
    end

    def request_destroy(worker)
      @gc_queue << [:destroy, worker]
    end

    def request_prune
      @gc_queue << [:prune]
    end

    def request_save
      @save_queue << :save
    end

    def run_save
      loop do
        cmd = @save_queue.pop
        return if cmd == :stop

        save_state
        sleep(1)
      end
    end

    def run_gc
      loop do
        cmd, *args = @gc_queue.pop(timeout: 60)

        case cmd
        when :stop
          return

        when :destroy
          worker = args[0]
          worker.destroy

        when :prune, nil
          do_prune_workers
        end
      end
    end

    def do_prune_workers
      to_destroy = []

      exclusively do
        now = Time.now

        @workers.each do |name, worker|
          if worker.unused? && (worker.last_used.nil? || worker.last_used + 60 < now)
            log(:info, "Disabling unused #{name}")
            @workers.delete(name)
            to_destroy << worker
          end
        end
      end

      request_save if to_destroy.any?

      to_destroy.each do |worker|
        log(:info, "Destroying unused #{worker.name}")
        worker.destroy
      end
    end
  end
end
