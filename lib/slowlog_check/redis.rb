# frozen_string_literal: true

require 'redis'
require 'uri'

class SlowlogCheck
  class Redis
    MAXLENGTH = 1_048_576 # 255 levels of recursion for #

    def initialize(opts)
      @host = opts[:host]
    end

    def params
      if cluster_mode_enabled?
        {
          cluster: [uri],
          port: port,
          ssl: tls_mode?
        }
      else
        {
          host: hostname,
          port: port,
          ssl: tls_mode?
        }
      end
    end

    def redis
      @redis ||= Redis.new(params)
    end

    def replication_group
      if tls_mode?
        matches[:second]
      else
        matches[:first]
      end
    end

    def slowlog(length = 128)
      resp = redis.slowlog('get', length)

      return resp if length > MAXLENGTH
      return resp if did_i_get_it_all?(resp)

      slowlog(length * 2)
    end

    private

    def cluster_mode_enabled?
      if tls_mode?
        matches[:first] == 'clustercfg'
      else
        matches[:third] == ''
      end
    end

    def did_i_get_it_all?(slowlog)
      slowlog[-1][0].zero?
    end

    def hostname
      URI.parse(@host).hostname or
        @host
    end

    def matches
      redis_uri_regex.match(@host)
    end

    def port
      regex_port = matches[:port].to_i
      if regex_port.positive?
        regex_port
      else
        6379
      end
    end

    def uri
      'redis' +
        -> { tls_mode? ? 's' : '' }.call +
        '://' +
        hostname +
        ':' +
        port.to_s
    end

    def redis_uri_regex
      %r{((?<scheme>redi[s]+)\://){0,1}(?<first>[0-9A-Za-z_-]+)\.(?<second>[0-9A-Za-z_-]+)\.{0,1}(?<third>[0-9A-Za-z_]*)\.(?<region>[0-9A-Za-z_-]+)\.cache\.amazonaws\.com:{0,1}(?<port>[0-9]*)}
    end

    def tls_mode?
      matches[:scheme] == 'rediss' or
        %w[master clustercfg].include?(matches[:first])
    end
  end
end
