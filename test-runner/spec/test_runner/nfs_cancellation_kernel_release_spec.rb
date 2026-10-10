# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'open3'
require 'shellwords'

# This regression's subject is a Nix-generated shell assertion, not a Ruby class.
RSpec.describe 'NFS cancellation running kernel assertion' do # rubocop:disable RSpec/DescribeClass
  shared_examples 'an exact release assertion' do |suite_name, baseline, expected_release|
    let(:guard) do
      source = File.join(REPO_ROOT, 'tests/suite/osctl/nfs-cancellation-common.nix')
      expression = <<~NIX
        (import (builtins.toPath #{source.to_json}) {
          name = #{suite_name.to_json};
          baseline = #{baseline};
          description = "";
          machine = {};
          pkgs = {
            pkgsStatic.stdenv.mkDerivation = _: "/unused-dirty-init";
            writeScript = _: _: "/unused-dirty-init-script";
            lib.optionalString = condition: value: if condition then value else "";
          };
        }).testScript
      NIX
      output, error, status = Open3.capture3('nix-instantiate', '--eval', '--strict', '--json', '--expr', expression)
      raise "NFS test script evaluation failed: #{error}" unless status.success?

      JSON.parse(output).match(/machine\.succeeds\('([^']*uname -r[^']*)'\)/)[1]
    end

    %w[6.12.95 6.12.95.6 6.12.95.7 6.12.109 6.12.110].each do |release|
      it "#{release == expected_release ? 'accepts' : 'rejects'} #{release}" do
        command = "uname() { printf '%s\\n' #{release.shellescape}; }; #{guard}"
        output, error, status = Open3.capture3('sh', '-c', command)

        expect(error).to eq('')
        expect(status.success?).to eq(release == expected_release)
        expect(output).to eq(release == expected_release ? "#{release}\n" : '')
      end
    end
  end

  context 'with cumulative livepatch v7' do
    it_behaves_like 'an exact release assertion', 'osctl-nfs-cancellation', false, '6.12.95.7'
  end

  context 'with the unpatched baseline' do
    it_behaves_like 'an exact release assertion', 'osctl-nfs-cancellation-baseline', true, '6.12.95'
  end

  context 'with the native candidate' do
    it_behaves_like 'an exact release assertion', 'osctl-nfs-cancellation-native110', false, '6.12.110'
  end
end
