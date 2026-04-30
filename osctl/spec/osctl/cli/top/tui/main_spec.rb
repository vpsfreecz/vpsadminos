# frozen_string_literal: true

require 'spec_helper'

RSpec.describe OsCtl::Cli::Top::Tui::Main do
  subject(:screen) { described_class.allocate }

  describe '#view_window' do
    it 'paginates when only one container row fits' do
      expect(screen.send(:view_window, 10, 1, 99)).to eq([9, 1, 9, 9])
    end

    it 'does not paginate when no container row fits' do
      expect(screen.send(:view_window, 10, 0, 3)).to eq([0, 0, 0, 0])
    end

    it 'does not create a negative page maximum when all containers fit' do
      expect(screen.send(:view_window, 3, 10, 2)).to eq([0, 10, 0, 0])
    end
  end
end
