#!/usr/bin/env ruby
# WARNING: This will lock up CPU on the target Redis instance. Never run against production.
#
# Copyright 2020 Scribd, Inc.

require 'logger'
require 'redis'

LOGGER = Logger.new($stdout)
LOGGER.level = Logger::WARN

REDIS = Redis.new(
  host: ENV.fetch('REDIS_HOST'),
  ssl: :true
  )

if ARGV[0].nil?
  raise "Specify milliseconds to inject as the first positional argument to `#{__FILE__}`"
else
  milliseconds = ARGV[0].to_i
end

SCRIPT =<<HEREDOC
-- From https://medium.com/@stockholmux/simulating-a-slow-command-with-node-redis-and-lua-efadbf913cd9
local aTempKey = "a-temp-key"
local cycles
redis.call("SET",aTempKey,"1")
redis.call("PEXPIRE",aTempKey, #{milliseconds})
for i = 0, #{15000 * milliseconds}, 1 do
	local apttl = redis.call("PTTL",aTempKey)
	cycles = i;
	if apttl == 0 then
		break;
	end
end
return cycles
HEREDOC

LOGGER.info REDIS.eval(SCRIPT)
