# frozen_string_literal: true

module DbRegistryHelpers
  def stub_containers_registry(containers)
    stub_const('OsCtld::DB::Containers', Object.new.tap do |registry|
      registry.define_singleton_method(:get) do |&block|
        block ? block.call(containers) : containers
      end

      registry.define_singleton_method(:each) do |&block|
        containers.each(&block)
      end
    end)
  end

  def stub_groups_registry(groups, root: nil)
    root_group = root || groups.find { |grp| grp.name == '/' }

    stub_const('OsCtld::DB::Groups', Object.new.tap do |registry|
      registry.define_singleton_method(:get) do |&block|
        block ? block.call(groups) : groups
      end

      registry.define_singleton_method(:root) do |_pool|
        root_group
      end

      registry.define_singleton_method(:by_path) do |_pool, path|
        groups.find { |grp| grp.name == path }
      end

      registry.define_singleton_method(:find) do |name, _pool|
        groups.find { |grp| grp.name == name }
      end
    end)
  end
end

RSpec.configure do |config|
  config.include DbRegistryHelpers
end
