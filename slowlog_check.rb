#!/usr/bin/env ruby
# Copyright 2020 Scribd, Inc.

require 'logger'
require 'date'
require 'redis'
require 'dogapi'

LOGGER = Logger.new($stdout)
LOGGER.level = Logger::INFO

REDIS = Redis.new(
  host: ENV.fetch('REDIS_HOST'),
  ssl: :true
  )

DDOG = Dogapi::Client.new(
  ENV.fetch('DATADOG_API_KEY'),
  ENV.fetch('DATADOG_APP_KEY')
)

def log_context
  LOGGER.debug('## ENVIRONMENT VARIABLES')
  LOGGER.debug(ENV.to_a)
  LOGGER.debug('## EVENT')
  LOGGER.debug(@event)
end

def time
  # DateTime because Time does not natively parse AWS CloudWatch Event time
  DateTime.rfc3339(@event.fetch("time", DateTime.now.rfc3339))
end

def replication_group
  matches = /\w\.(?<replication_group>[\w-]+)\.\w+\.\w+\.cache\.amazonaws\.com/.match(ENV.fetch('REDIS_HOST'))
  if matches
    matches[:replication_group]
  else
    raise "Unable to parse REDIS_HOST. Is #{ENV.fetch('REDIS_HOST','NO REDIS_HOST DEFINED')} a valid elasticache endpoint?"
  end
end

def last_datadog_metrics_submitted_by_me_in_the_last_day
  resp = DDOG.get_points(
    "scribd.slowlog_check.slowlog{replication_group:#{replication_group}}",
    Time.now - 86400,
    Time.now
  )

  raise "Error getting last datadog metric submitted by me" unless resp[0] == "200"
  resp
end

def last_datadog_metric
  Time.at(
    last_datadog_metrics_submitted_by_me_in_the_last_day[1]
      .fetch("series")
      .first
      .fetch("pointlist")
      .map {|x| x[0]}
      .max
      .to_i / 1000
  )
end

def last_time_submitted
  return @last_time_submitted if defined? @last_time_submitted
  @last_time_submitted = last_datadog_metric
end

def emit_point(time, value, tags)
  LOGGER.info "Sending slowlog entry: #{value}µs executing #{tags[:command]} at #{time}."
  resp = DDOG.emit_points(
    'redis.slowlog.micros.avg',
    [[time, value]],
    {
      host: replication_group,
      tags: tags
    }
  )
  raise "Error submitting metric for #{replication_group}" unless resp[0] == "202"
  @last_time_submitted = time
  resp
end

def slowlog_time(slowlog)
  Time.at slowlog[1]
end

def slowlog_microseconds(slowlog)
  slowlog[2]
end

def client_ip(ip_and_port)
  ip_and_port.split(':')[0]
end

def slowlog_tags(slowlog)
  {
    command: slowlog[3][0],
    client: client_ip(slowlog[4]),
    client_name: slowlog[5],
    replication_group: replication_group,
    service: replication_group,
    namespace: ENV.fetch('NAMESPACE'),
    aws: 'true',
    env: ENV.fetch('ENV')
  }
end

def ship_slowlogs
  REDIS.slowlog('get').each do |slowlog|
    break if slowlog_time(slowlog) <= last_time_submitted
    emit_point(
      slowlog_time(slowlog),
      slowlog_microseconds(slowlog),
      slowlog_tags(slowlog)
    )
  end
end


def lambda_handler(event: {}, context: {})
  @event = event

  log_context
  LOGGER.info "Event time: #{time}."
  begin
    REDIS.ping
    ship_slowlogs
  rescue StandardError => e
    LOGGER.error e.inspect
    # => #<Redis::CannotConnectError: Timed out connecting to Redis on 10.0.1.1:6380>
    LOGGER.error e.message
    # => Timed out connecting to Redis on 10.0.1.1:6380
  end

  nil
end

if __FILE__ == $0
  lambda_handler
end
