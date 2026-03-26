# frozen_string_literal: true

require 'etc'

begin
  Etc.getpwnam('repository')
rescue ArgumentError
  fake_entry = Struct.new(:uid).new(12_345)

  class << Etc
    alias __osctld_spec_original_getpwnam getpwnam unless method_defined?(:__osctld_spec_original_getpwnam)
  end

  Etc.define_singleton_method(:getpwnam) do |name|
    return fake_entry if name == 'repository'

    __osctld_spec_original_getpwnam(name)
  end
end
