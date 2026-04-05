# frozen_string_literal: true

require 'spec_helper'
require 'yaml'
require 'vpsadminos-converter/exporter'

RSpec.describe VpsAdminOS::Converter::Exporter::Mixin do
  before do
    stub_const('TestExporterContainer', Class.new)
    stub_const('TestExporterUser', Class.new)
    stub_const('TestExporterGroup', Class.new)
  end

  let(:tar_class) do
    Class.new do
      attr_reader :mkdir_calls, :files

      def initialize
        @mkdir_calls = []
        @files = {}
      end

      def mkdir(path, mode)
        mkdir_calls << [path, mode]
      end

      def add_file(path, mode)
        io = StringIO.new
        yield(io)
        files[path] = {
          mode:,
          content: io.string
        }
      end
    end
  end

  let(:exporter_class) do
    Class.new do
      include VpsAdminOS::Converter::Exporter::Mixin

      attr_reader :ct, :tar

      def initialize(ct, tar)
        @ct = ct
        @tar = tar
      end
    end
  end

  it 'dumps user, group, and container configs into the tar archive' do
    tar = tar_class.new
    ct = instance_double(
      TestExporterContainer,
      user: instance_double(TestExporterUser, dump_config: { 'ugid' => 1000 }),
      group: instance_double(TestExporterGroup, dump_config: { 'path' => 'default' }),
      dump_config: { 'hostname' => 'ct101' }
    )
    exporter = exporter_class.new(ct, tar)

    exporter.dump_configs

    expect(tar.mkdir_calls).to eq(
      [['config', OsCtl::Lib::Exporter::Base::DIR_MODE]]
    )
    expect(YAML.safe_load(tar.files['config/user.yml'][:content])).to eq(
      'ugid' => 1000
    )
    expect(YAML.safe_load(tar.files['config/group.yml'][:content])).to eq(
      'path' => 'default'
    )
    expect(YAML.safe_load(tar.files['config/container.yml'][:content])).to eq(
      'hostname' => 'ct101'
    )
  end
end
