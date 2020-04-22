#!/usr/bin/env ruby
# Copyright 2020 Scribd, Inc.

require 'logger'
require 'redis'

LOGGER = Logger.new($stdout)
LOGGER.level = Logger::WARN

REDIS = Redis.new(
  host: ENV.fetch('REDIS_HOST'),
  ssl: :true
  )

SCRIPT =<<END
-- From https://medium.com/@stockholmux/simulating-a-slow-command-with-node-redis-and-lua-efadbf913cd9
local aTempKey = "a-temp-key"
local cycles
redis.call("SET",aTempKey,"1")
redis.call("PEXPIRE",aTempKey, 100)
for i = 0, 1500000, 1 do
	local apttl = redis.call("PTTL",aTempKey)
	cycles = i;
	if apttl == 0 then
		break;
	end
end
return cycles
END

LOGGER.info REDIS.eval(SCRIPT)
