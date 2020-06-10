# Copyright 2020 Scribd, Inc.
require 'logger'

class SlowlogCheck
  require_relative 'slowlog_check/redis'

  ::LOGGER ||= ::Logger.new($stdout)

  def initialize(params = {})
    @ddog = params.fetch(:ddog)
    @redis= SlowlogCheck::Redis.new(params.fetch(:redis))
    @metricname = params.fetch(:metricname)
    @namespace = params.fetch(:namespace)
    @env = params.fetch(:env)
  end

  def status_or_error(resp)
    return resp[1].fetch("status") if resp[1].key?("status")
    return resp[1].fetch("errors") if resp[1].key?("errors")
    return resp
  end

  def last_datadog_metrics_submitted_by_me_in_the_last_2_hours
    resp = @ddog.get_points(
      "#{@metricname}.95percentile{replication_group:#{@redis.replication_group}}",
      Time.now - 7200,
      Time.now
    )

    raise "Error getting last datadog metric submitted by me" unless status_or_error(resp) == "ok"
    resp
  end

  def minute_precision(time)
    Time.at(
      (time.to_i - (time.to_i % 60)).to_i
    )
  end

  def last_datadog_metric
    series = last_datadog_metrics_submitted_by_me_in_the_last_2_hours[1].fetch("series")
    if series == [] # First invocation
      return minute_precision(Time.now - 3600)
    else
      minute_precision(
        Time.at(
          series
            .first
            .fetch("pointlist")
            .map { |x| x[0] }
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
    now_i = minute_precision(Time.now).to_i - 60
    start_time_i = last_time_submitted.to_i + 60
    times = (start_time_i..now_i).step(60).to_a
    Hash[times.collect { |time| [Time.at(time), {}] }]
  end

  def _95percentile(sorted_values)
    index = (sorted_values.length * 0.95) - 1
    sorted_values[index]
  end

  def add_metric_to_bucket(prior, new)
    new_values = prior[:values].push(new)
    new_count = new_values.length
    new_avg = ((prior[:avg] * prior[:count]) + new) / new_count

    sorted_values = new_values.sort
    new_median = sorted_values[(sorted_values.count / 2) - 1]
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


  def empty_values
    {
      values: [],
      avg: 0,
      count: 0,
      median: 0,
      _95percentile: 0,
      min: 0,
      max: 0,
      sum: 0
    }
  end

  def new_commands(timestamp, timebucket)
    result = {}
    timebucket.keys.each do |command|
      result[command] = timestamp
    end
    result
  end

  def pad_results_with_zero(report)
    @seen_commands ||= {}
    report.keys.sort.each do |timebucket|
      # Collect new_commands
      new_commands = new_commands(timebucket, report[timebucket])

      # donut zero existing commands
      commands_to_zero = @seen_commands.keys - new_commands.keys
      commands_to_zero.each do |command|
        # inject_zeroing_commands
        report[timebucket].merge!({command => empty_values})
        # And remove it from the seen_commands queue
        @seen_commands.delete(command)
      end
      # add new_commands to seen_commands queue
      @seen_commands.merge!(new_commands)
    end
    report
  end

  def slowlogs_by_flush_interval
    result = reporting_interval
    @redis.slowlog.each do |slowlog|
      time = slowlog_time(slowlog)
      break if minute_precision(time) <= minute_precision(last_time_submitted)

      command = slowlog[3][0]
      value = slowlog_microseconds(slowlog)
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

    pad_results_with_zero(result)
  end

  def default_tags
    {
      replication_group: @redis.replication_group,
      service: @redis.replication_group,
      namespace: @namespace,
      aws: 'true',
      env: @env
    }
  end

  def emit_point(params)
    metric = @metricname + '.' + params.fetch(:metric)
    type = params.fetch(:type, 'gauge')
    interval = params.fetch(:interval, 60)
    points = params.fetch(:points)
    host = params.fetch(:host, @redis.replication_group)
    tags = params.fetch(:tags, default_tags)

    LOGGER.info "Sending slowlog entry: #{metric}: #{points.first[1]}µs executing #{tags[:command]} at #{points.first[0]}."
    resp = @ddog.emit_points(
      metric,
      points,
      {
        type: type,
        interval: interval,
        host: host,
        tags: tags
      }
    )
    raise "Error submitting metric for #{@redis.replication_group}" unless status_or_error(resp) == "ok"

    # Sigh. After doing all the work to pass around Time objects, dogapi-rb changes this to an integer.
    @last_time_submitted = Time.at(points.first[0])
    LOGGER.info "#{metric} set #{status_or_error(resp)} at #{Time.at(points.first[0])}"
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


  ##
  # Metadata

  def metric_metadatas
    [
      'avg',
      'median',
      'min',
      'max',
      '95percentile'
    ].map { |metric|
      {
        "name" => @metricname + '.' + metric,
        "description" => "slowlog duration #{metric} (µs)",
        "short_name" => "#{metric} (µs)",
        "integration" => nil,
        "statsd_interval" => 60,
        "per_unit" => nil,
        "type" => "gauge",
        "unit" => "microsecond"
      }
    }.push(
      {
        "name" => @metricname + '.count',
        "type" => 'rate',
        "description" => 'slowlog entries per minute',
        "short_name" => 'per minute',
        "per_unit" => 'minute',
        "integration" => nil,
        "unit" => 'entry',
        "statsd_interval" => 60
      }
    )
  end

  def get_metadatas
    [
      'avg',
      'median',
      'min',
      'max',
      '95percentile',
      'count'
    ].map do |metric|
      name = @metricname + '.' + metric
      @ddog.get_metadata(name)[1]
        .merge("name" => name)
    end
  end

  def diff_metadatas
    metric_metadatas - get_metadatas
  end


  def update_metadatas
    diff_metadatas.each do |metadata|
      name = metadata.delete("name")
      resp = @ddog.update_metadata(
        name,
        metadata.transform_keys { |key| key.to_sym }
      )
      LOGGER.info "Updating metadata for #{name} #{status_or_error(resp)}"
    end
  end

end
