# frozen_string_literal: true

require 'fileutils'

module FakeObjects
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
  FakeUser = Struct.new(:name, :userdir, :ugid, keyword_init: true)
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
