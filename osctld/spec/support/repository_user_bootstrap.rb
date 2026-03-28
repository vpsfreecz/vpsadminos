# frozen_string_literal: true

require 'etc'

fake_entries = {}

{
  'repository' => 12_345,
  'osctl-ct-receive' => 23_456
}.each do |name, uid|
  Etc.getpwnam(name)
rescue ArgumentError
  fake_entries[name] = Struct.new(:uid).new(uid)
end

if fake_entries.any?
  class << Etc
    alias __osctld_spec_original_getpwnam getpwnam unless method_defined?(:__osctld_spec_original_getpwnam)
  end

  Etc.define_singleton_method(:getpwnam) do |name|
    return fake_entries[name] if fake_entries.has_key?(name)

    __osctld_spec_original_getpwnam(name)
  end
end
