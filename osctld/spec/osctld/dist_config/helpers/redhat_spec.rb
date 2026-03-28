# frozen_string_literal: true

require 'osctld/dist_config/helpers/redhat'

RSpec.describe OsCtld::DistConfig::Helpers::RedHat do
  let(:helper_class) do
    Class.new do
      include OsCtld::DistConfig::Helpers::RedHat
      include OsCtld::DistConfig::Helpers::Common
      include OsCtl::Lib::Utils::File
    end
  end

  let(:helper) { helper_class.new }

  it 'creates, updates, and preserves unrelated lines when setting params' do
    with_tmpdir do |dir|
      file = File.join(dir, 'network')
      File.write(file, "KEEP=yes\nIPV6=no\n# comment\n")

      helper.set_params(file, { 'IPV6' => 'yes', 'NETWORKING' => 'yes' })

      expect(File.read(file)).to eq(
        "KEEP=yes\nIPV6=\"yes\"\n# comment\nNETWORKING=\"yes\"\n"
      )
    end
  end

  it 'creates a new file when none exists' do
    with_tmpdir do |dir|
      file = File.join(dir, 'network')

      helper.set_params(file, { 'NETWORKING' => 'yes' })

      expect(File.read(file)).to eq("NETWORKING=\"yes\"\n")
    end
  end
end
