# frozen_string_literal: true

require 'spec_helper'

# rubocop:disable RSpec/DescribeClass
RSpec.describe '20180825200854-set-ct-dataset-canmount-noauto migration' do
  let(:rel_prefix) { 'migrations/20180825200854-set-ct-dataset-canmount-noauto' }

  def run_script(rel_path, setting)
    calls = []
    zfs = proc do |cmd, opts, target|
      case [cmd, opts, target]
      when [:list, '-Hr -o name', 'tank/osctl/ct']
        command_result("tank/osctl/ct\ntank/osctl/ct/100\ntank/osctl/ct/100/root\n")
      else
        raise "unexpected zfs call: #{[cmd, opts, target].inspect}" unless cmd == :set && opts == setting

        calls << target
        command_result

      end
    end

    load_migration_script(rel_path, globals: { DATASET: 'tank/osctl' }, zfs:)
    calls
  end

  it 'sets canmount=noauto on child container datasets during upgrade' do
    expect(run_script("#{rel_prefix}/up.rb", 'canmount=noauto')).to eq([
                                                                         'tank/osctl/ct/100',
                                                                         'tank/osctl/ct/100/root'
                                                                       ])
  end

  it 'sets canmount=on on child container datasets during rollback' do
    expect(run_script("#{rel_prefix}/down.rb", 'canmount=on')).to eq([
                                                                       'tank/osctl/ct/100',
                                                                       'tank/osctl/ct/100/root'
                                                                     ])
  end
end
# rubocop:enable RSpec/DescribeClass
