module OsCtld
  module Monitor
    STATES = %i[
      stopped
      starting
      running
      stopping
      aborting
      freezing
      frozen
      thawed
    ].freeze
  end
end
