# frozen_string_literal: true

module MigrationScriptHelpers
  MIGRATION_CONSTANTS = %i[
    Rollback
    RenameMigration
    Pool
    GroupConfig
    DeviceList
    Device
  ].freeze

  # rubocop:disable Style/DocumentDynamicEvalDefinition
  def with_global_vars(vars)
    previous = {}

    vars.each do |name, value|
      gvar = "$#{name}"
      previous[gvar] = TOPLEVEL_BINDING.eval(
        "defined?(#{gvar}) ? #{gvar} : :__undefined__"
      )
      TOPLEVEL_BINDING.eval("#{gvar} = #{value.inspect}")
    end

    yield
  ensure
    previous.each do |gvar, value|
      TOPLEVEL_BINDING.eval("#{gvar} = #{value == :__undefined__ ? 'nil' : value.inspect}")
    end
  end
  # rubocop:enable Style/DocumentDynamicEvalDefinition

  def with_stubbed_system(zfs: nil, syscmd: nil)
    system_mod = OsCtl::Lib::Utils::System
    original_zfs = system_mod.instance_method(:zfs)
    original_syscmd = system_mod.instance_method(:syscmd)

    system_mod.module_eval do
      define_method(:zfs) { |*args| zfs.call(*args) } if zfs
      define_method(:syscmd) { |*args| syscmd.call(*args) } if syscmd
    end

    yield
  ensure
    system_mod.module_eval do
      define_method(:zfs, original_zfs)
      define_method(:syscmd, original_syscmd)
    end
  end

  def load_migration_script(rel_path, globals:, zfs: nil, syscmd: nil)
    path = File.join(REPO_ROOT, 'osup', rel_path)
    common_path = File.join(File.dirname(path), 'common.rb')

    if File.exist?(common_path)
      $".delete_if { |feature| feature == common_path }
    end

    with_global_vars(globals) do
      with_stubbed_system(zfs: zfs, syscmd: syscmd) do
        load path
      end
    end
  ensure
    if defined?(common_path) && File.exist?(common_path)
      $".delete_if { |feature| feature == common_path }
    end

    # rubocop:disable RSpec/RemoveConst
    MIGRATION_CONSTANTS.each do |const|
      Object.send(:remove_const, const) if Object.const_defined?(const)
    end
    # rubocop:enable RSpec/RemoveConst
  end
end

RSpec.configure do |config|
  config.include MigrationScriptHelpers
end
