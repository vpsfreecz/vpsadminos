# frozen_string_literal: true

require 'spec_helper'
require 'shellwords'

RSpec.describe OsCtl::ExportFS::ErbTemplate do
  let(:nfsd) { OsCtl::ExportFS::Config::Nfsd.new('versions' => versions) }
  let(:config) { instance_double(OsCtl::ExportFS::Config::TopLevel, nfsd:, mountd_port: nil) }
  let(:script) { described_class.render('runsvdir/nfsd', config:) }
  let(:arguments) do
    command = script.gsub("\\\n", '').lines.find { |line| line.start_with?('rpc.nfsd ') }
    Shellwords.split(command)
  end

  context 'with all protocol versions' do
    let(:versions) { %w[3 4 4.0 4.1 4.2] }

    it 'passes each version separately, including explicit NFSv4.0 enablement' do
      expected = %w[
        rpc.nfsd --tcp --no-udp
        --nfs-version 3 --nfs-version 4 --nfs-version 4.0
        --nfs-version 4.1 --nfs-version 4.2 -- 8
      ]
      expect(arguments).to eq(expected)
    end
  end

  context 'with aggregate NFSv4 support' do
    let(:versions) { %w[4] }

    it 'does not disable the minor versions implied by NFSv4' do
      expected = %w[
        rpc.nfsd --tcp --no-udp --no-nfs-version 3
        --nfs-version 4 --nfs-version 4.0
        --nfs-version 4.1 --nfs-version 4.2 -- 8
      ]
      expect(arguments).to eq(expected)
    end
  end

  context 'with only NFSv4.1' do
    let(:versions) { %w[4.1] }

    it 'disables unwanted versions before enabling the selected minor version' do
      expected = %w[
        rpc.nfsd --tcp --no-udp
        --no-nfs-version 3 --no-nfs-version 4
        --no-nfs-version 4.0 --no-nfs-version 4.2
        --nfs-version 4.1 -- 8
      ]
      expect(arguments).to eq(expected)
    end
  end
end
