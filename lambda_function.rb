#!/usr/bin/env ruby
# Copyright 2020 Scribd, Inc.

require 'logger'
require 'date'
require 'dogapi'
require_relative 'lib/slowlog_check'

LOGGER = Logger.new($stdout)
LOGGER.level = Logger::INFO

def event_time
  # DateTime because Time does not natively parse AWS CloudWatch Event time
  DateTime.rfc3339(@event.fetch("time", DateTime.now.rfc3339))
end

def log_context
  LOGGER.debug('## ENVIRONMENT VARIABLES')
  LOGGER.debug(ENV.to_a)
  LOGGER.debug('## EVENT')
  LOGGER.debug(@event)
  LOGGER.info "Event time: #{event_time}."
end


def lambda_handler(event: {}, context: {})
  @event = event
  log_context

  ssm_path = ENV.fetch('SSM_PATH', false)
  if ssm_path
    require 'aws-sdk-ssm'
    resp = Aws::SSM::Client.new().get_parameters_by_path(
      path: "/#{ssm_path}/",
      recursive: true,
      with_decryption: true
    )
    resp.parameters.each do |parameter|
      name = File.basename(parameter.name)
      LOGGER.info "Setting parameter: #{name} from SSM."
      ENV[name] = parameter.value
    end
  end

  unless defined? @slowlog_check
    @slowlog_check = SlowlogCheck.new(
      ddog: Dogapi::Client.new(
        ENV.fetch('DATADOG_API_KEY'),
        ENV.fetch('DATADOG_APP_KEY')
      ),
      redis: {
        host: ENV.fetch('REDIS_HOST')
      },
      namespace: ENV.fetch('NAMESPACE'),
      env: ENV.fetch('ENV'),
      metricname: ENV.fetch('METRICNAME', 'elasticache.slowlog')
    )

    @slowlog_check.update_metadatas
  end

  @slowlog_check.ship_slowlogs

  nil
end

if __FILE__ == $0
  lambda_handler
end
