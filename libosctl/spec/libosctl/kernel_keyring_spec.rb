# frozen_string_literal: true

require 'spec_helper'
require 'libosctl/id_map'
require 'libosctl/kernel_keyring'

RSpec.describe OsCtl::Lib::KernelKeyring do
  it 'parses key users, filters by uid and id maps, sorts entries, and reads system limits' do
    with_tmpdir do |dir|
      key_users = File.join(dir, 'key-users')
      File.write(key_users, <<~KEYS)
        1000: 1 2/3 4/5 6/7
        1001: 2 8/9 1/10 11/12
      KEYS

      allow(File).to receive(:read).and_wrap_original do |method, path, *args|
        case path
        when '/proc/sys/kernel/keys/maxkeys'
          "123\n"
        when '/proc/sys/kernel/keys/maxbytes'
          "456\n"
        else
          method.call(path, *args)
        end
      end

      keyring = described_class.new(key_users:)
      id_map = OsCtl::Lib::IdMap.from_string_list(['0:1000:2'])

      expect(keyring.for_uid(1000)).to have_attributes(
        uid: 1000,
        usage: 1,
        nkeys: 2,
        nikeys: 3,
        qnkeys: 4,
        maxkeys: 5,
        qnbytes: 6,
        maxbytes: 7
      )
      expect(keyring.for_id_map(id_map).map(&:uid)).to eq([1000, 1001])
      expect(keyring.sort.map(&:uid)).to eq([1001, 1000])
      expect(keyring.maxkeys).to eq(123)
      expect(keyring.maxbytes).to eq(456)
    end
  end
end
