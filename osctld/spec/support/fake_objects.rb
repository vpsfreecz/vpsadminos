# frozen_string_literal: true

require 'fileutils'

module FakeObjects
  FakePool = Struct.new(:name, :conf_path, :log_path, :repo_path, keyword_init: true)
  FakeNamed = Struct.new(:name)
  FakeDbObject = Struct.new(:id, :pool, :send_log, keyword_init: true)

  def build_fake_pool(root:, name: 'tank')
    conf_path = File.join(root, 'conf')
    log_path = File.join(root, 'log')
    repo_path = File.join(root, 'repo')

    [conf_path, log_path, repo_path].each { |path| FileUtils.mkdir_p(path) }

    FakePool.new(
      name: name,
      conf_path: conf_path,
      log_path: log_path,
      repo_path: repo_path
    )
  end
end

RSpec.configure do |config|
  config.include FakeObjects
end
