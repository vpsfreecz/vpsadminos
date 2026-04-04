# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Receive do
  def cmd(args: [], opts: {}, gopts: {})
    build_command(described_class, args:, opts:, gopts:)
  end

  it 'lists, adds, and deletes authorized keys' do
    list = cmd(gopts: { pool: 'tank' })
    add = cmd(args: ['main'], opts: { 'from' => '1.2.3.4', 'ctid' => 'ct1', 'passphrase' => 'secret', 'single-use' => true }, gopts: { pool: 'tank' })
    delete = cmd(args: ['main'], gopts: { pool: 'tank' })

    expect(list).to receive(:osctld_fmt).with(:receive_authkey_list, cmd_opts: { pool: 'tank' })
    list.authorized_keys_list

    expect(add).to receive(:osctld_fmt).with(
      :receive_authkey_add,
      cmd_opts: {
        pool: 'tank',
        name: 'main',
        public_key: 'ssh-rsa AAA',
        from: '1.2.3.4',
        ctid: 'ct1',
        passphrase: 'secret',
        single_use: true
      }
    )
    with_stdin("ssh-rsa AAA\n") { add.authorized_keys_add }

    expect(delete).to receive(:osctld_fmt).with(:receive_authkey_delete, cmd_opts: { pool: 'tank', name: 'main' })
    delete.authorized_keys_delete
  end
end
