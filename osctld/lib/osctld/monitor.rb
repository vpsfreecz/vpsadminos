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
    ]
  end
end
