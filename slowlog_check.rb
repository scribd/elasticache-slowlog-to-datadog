#!/usr/bin/env ruby
# Copyright 2020 Scribd, Inc.

require 'logger'
require 'date'
require 'redis'
require 'dogapi'

LOGGER = Logger.new($stdout)
LOGGER.level = Logger::DEBUG

METRICNAME = 'scribddev.redis.slowlog.micros'

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

def event_time
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

# TODO: Rather than hard code a day lookback,
# look back at an increasing increment until hitting some max value
def last_datadog_metrics_submitted_by_me_in_the_last_day
  resp = DDOG.get_points(
    "#{METRICNAME}{replication_group:#{replication_group}}",
    Time.now - 86400,
    Time.now
  )

  raise "Error getting last datadog metric submitted by me" unless resp[1].fetch("status") == "ok"
  resp
end

def minute_precision(time)
  Time.at(
    time.to_i - (time.to_i % 60)
  )
end

def last_datadog_metric
  series = last_datadog_metrics_submitted_by_me_in_the_last_day[1].fetch("series")
  if series == [] # First invocation
    return Time.at(0)
  else
    minute_precision(
      Time.at(
        series
          .first
          .fetch("pointlist")
          .map {|x| x[0]}
          .max
          .to_i / 1000
      )
    )
  end
end

def last_time_submitted
  return @last_time_submitted if defined? @last_time_submitted
  @last_time_submitted = last_datadog_metric
end

def slowlog_time(slowlog)
  Time.at slowlog[1]
end

def slowlog_microseconds(slowlog)
  slowlog[2]
end

def reporting_interval
  now_i = Time.now.to_i
  start_time_i = last_time_submitted.to_i + 60
  times = (start_time_i..now_i).step(60).to_a
  Hash[times.collect {|time| [Time.at(time), nil]}]
end

def _95percentile(sorted_values)
  index = (sorted_values.length * 0.95) - 1
  sorted_values[index]
end

def add_metric_to_bucket(prior, new)
  new_values = prior[:values].push(new)
  new_count = prior[:count] += 1
  new_avg  = (prior[:avg] * prior[:count] + new) / new_count

  sorted_values = new_values.sort
  new_median = sorted_values[sorted_values.count / 2]
  new_95percentile = _95percentile(sorted_values)
  new_min = sorted_values[0]
  new_max = sorted_values[-1]
  new_sum = sorted_values.reduce(:+)

  {
    values: new_values,
    avg: new_avg,
    count: new_count,
    median: new_median,
    _95percentile: new_95percentile,
    min: new_min,
    max: new_max,
    sum: new_sum
  }
end

def slowlogs_by_flush_interval
  result = reporting_interval
  REDIS.slowlog('get').each do |slowlog|
    time = slowlog_time(slowlog)
    break if minute_precision(time) <= minute_precision(last_time_submitted)

    command = slowlog[3][0]
    value =  slowlog_microseconds(slowlog)
    bucket = minute_precision(time)

    if result[bucket].nil?
      result[bucket] = {
        command => {
          values: [value],
          avg: value,
          count: 1,
          median: value,
          _95percentile: value,
          min: value,
          max: value,
          sum: value
        }
      }
    elsif result[bucket][command].nil?
      result[bucket][command] = {
          values: [value],
          avg: value,
          count: 1,
          median: value,
          _95percentile: value,
          min: value,
          max: value,
          sum: value
        }
    else
      result[bucket][command] = add_metric_to_bucket(result[bucket][command], value)
    end
  end

  result
end

def default_tags
  {
    replication_group: replication_group,
    service: replication_group,
    namespace: ENV.fetch('NAMESPACE'),
    aws: 'true',
    env: ENV.fetch('ENV')
  }
end

def emit_point(params)
  metric = METRICNAME + '.' + params.fetch(:metric)
  type = params.fetch(:type, 'gauge')
  interval = params.fetch(:interval, 60)
  points = params.fetch(:points)
  host = params.fetch(:host, replication_group)
  tags = params.fetch(:tags, default_tags)

  LOGGER.info "Sending slowlog entry: #{points.first[1]}µs executing #{tags[:command]} at #{points.first[0]}."
  resp = DDOG.emit_points(
    metric,
    points,
    {
      type: type,
      interval: interval,
      host: host,
      tags: tags
    }
  )
  raise "Error submitting metric for #{replication_group}" unless resp[1].fetch("status") == "ok"
  @last_time_submitted = Time.at(points.first[0])
  resp
end

def ship_slowlogs
  slowlogs = slowlogs_by_flush_interval
  slowlogs.keys.sort.each do |timestamp|
    timebucket = slowlogs.fetch(timestamp)
    next if timebucket.nil?

    timebucket.keys.each do |command|
      all_metrics = timebucket.fetch(command)

      # Emit most metrics
      [:avg, :count, :median, :min, :max].each do |metric|
        emit_point(
          metric: metric.to_s,
          type: metric == :count ? 'rate' : 'gauge',
          points: [[timestamp, all_metrics.fetch(metric)]],
          tags: default_tags.merge(command: command)
        )
      end

      # Stupid symbol's cannot start with a number
      emit_point(
        metric: '95percentile',
        points: [[timestamp, all_metrics.fetch(:_95percentile)]],
        tags: default_tags.merge(command: command)
      )

    end
  end
end



def lambda_handler(event: {}, context: {})
  @event = event

  log_context
  LOGGER.info "Event time: #{event_time}."
  begin
    REDIS.ping
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

  require 'pry'
  binding.pry

end
