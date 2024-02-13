require_relative 'common'

pool = Pool.new
root_group = GroupConfig.new(pool, '/')
root_group.ensure_device(Device.new({
  'type' => 'char',
  'major' => '1',
  'minor' => '11',
  'mode' => 'rwm',
  'name' => '/dev/kmsg',
  'inherit' => true,
  'inherited' => false
}))
root_group.save
