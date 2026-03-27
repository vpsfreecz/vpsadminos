# frozen_string_literal: true

require 'fileutils'

module FakeObjects
  FakeIdMapEntry = Struct.new(:ns_id, :host_id, :id_count, keyword_init: true) do
    def to_a = [ns_id, host_id, id_count]

    def to_h
      {
        ns_id:,
        host_id:,
        id_count:
      }
    end

    def to_s = "#{ns_id}:#{host_id}:#{id_count}"
  end

  class FakeIdMap
    include Enumerable

    def initialize(entries = [
      FakeIdMapEntry.new(ns_id: 0, host_id: 100_000, id_count: 65_536)
    ])
      @entries = entries
    end

    def each(&)
      @entries.each(&)
    end

    def ns_to_host(id)
      @entries.first.host_id + id
    end
  end

  FakePool = Struct.new(
    :name,
    :dataset,
    :conf_path,
    :log_path,
    :repo_path,
    :user_dir,
    keyword_init: true
  )
  FakeNamed = Struct.new(:name)

  class FakeUser
    attr_reader :name, :userdir, :ugid, :uid_map, :gid_map

    def initialize(name:, userdir:, ugid: 1234, uid_map: FakeIdMap.new, gid_map: FakeIdMap.new)
      @name = name
      @userdir = userdir
      @ugid = ugid
      @uid_map = uid_map
      @gid_map = gid_map
    end
  end

  class FakeDataset
    attr_reader :name, :mountpoint, :descendants, :mount_calls, :unmount_calls

    def initialize(name:, mountpoint:, mounted: false, descendants: [])
      @name = name
      @mountpoint = mountpoint
      @mounted = mounted
      @descendants = descendants
      @mount_calls = []
      @unmount_calls = []
    end

    def to_s = name

    def on_pool?(pool_name)
      name == pool_name || name.start_with?("#{pool_name}/")
    end

    def mount(recursive: true)
      @mount_calls << recursive
      @mounted = true
    end

    def unmount(recursive: true)
      @unmount_calls << recursive
      @mounted = false
    end

    def mounted?(recursive: true)
      @mounted
    end
  end

  class FakeGroup
    attr_accessor :memory_limit, :swap_limit, :cpu_limit
    attr_reader :name

    def initialize(name:, cgroup_path: '/osctl/pool.tank/group.default')
      @name = name
      @cgroup_path = cgroup_path
      @memory_limit = nil
      @swap_limit = nil
      @cpu_limit = nil
    end

    def userdir(user)
      parts =
        if name == '/'
          []
        else
          name.split('/').drop(1).map { |v| "group.#{v}" }
        end

      File.join(user.userdir, *parts, 'cts')
    end

    def full_cgroup_path(user)
      File.join(@cgroup_path, "user.#{user.name}")
    end

    def find_memory_limit(parents: true)
      memory_limit
    end

    def find_swap_limit(parents: true)
      swap_limit
    end

    def find_cpu_limit(parents: true)
      cpu_limit
    end
  end

  FakeDbObject = Struct.new(:id, :pool, :send_log, keyword_init: true)

  class FakeContainer
    attr_reader :id, :pool, :group, :user

    def initialize(pool:, group:, user:, id: 'ct1', running: false)
      @pool = pool
      @group = group
      @user = user
      @id = id
      @running = running
    end

    def running?
      @running
    end
  end

  def build_fake_pool(root:, name: 'tank', dataset: nil)
    conf_path = File.join(root, 'conf')
    log_path = File.join(root, 'log')
    repo_path = File.join(root, 'repo')
    user_dir = File.join(root, 'run', 'users')

    [conf_path, log_path, repo_path, user_dir].each { |path| FileUtils.mkdir_p(path) }

    FakePool.new(
      name: name,
      dataset: dataset || name,
      conf_path: conf_path,
      log_path: log_path,
      repo_path: repo_path,
      user_dir: user_dir
    )
  end
end

RSpec.configure do |config|
  config.include FakeObjects
end
