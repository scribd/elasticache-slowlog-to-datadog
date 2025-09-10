# frozen_string_literal: true

require 'redis'
require 'uri'

class SlowlogCheck
  class Redis
    MAXLENGTH        = 1_048_576
    CONNECT_TIMEOUT  = (ENV['REDIS_CONNECT_TIMEOUT'] || 5).to_i
    RW_TIMEOUT       = (ENV['REDIS_RW_TIMEOUT'] || 5).to_i
    RECONNECT_TRIES  = (ENV['REDIS_RECONNECT_ATTEMPTS'] || 2).to_i

    def initialize(opts)
      @host = opts[:host]
    end

    def params
      base =
        if cluster_mode_enabled?
          { cluster: [uri], port: port, ssl: tls_mode? }
        else
          { host: hostname, port: port, ssl: tls_mode? }
        end

      password = ENV['REDIS_PASSWORD']
      base[:password] = password unless password.nil? || password.empty?

      base[:connect_timeout]    = CONNECT_TIMEOUT
      base[:read_timeout]       = RW_TIMEOUT
      base[:write_timeout]      = RW_TIMEOUT
      base[:reconnect_attempts] = RECONNECT_TRIES
      base
    end

    def redis_rb
      @redis_rb ||= ::Redis.new(params)
    end

    def replication_group
      if tls_mode?
        matches[:second]
      else
        matches[:first]
      end
    end

    # Always returns an Array (possibly empty). Never raises to the caller.
    def slowlog_get(length = 128)
      resp = begin
               redis_rb.slowlog('get', length)
             rescue ::Redis::BaseError, StandardError => e
               LOGGER&.warn("SLOWLOG GET failed (Redis): #{e.class}: #{e.message}") rescue nil
               []
             end

      resp = [] unless resp.is_a?(Array)
      resp = resp.select { |e| e.is_a?(Array) }

      return resp if length >= MAXLENGTH
      return resp if did_i_get_it_all?(resp)

      slowlog_get(length * 2)
    end

    private

    def cluster_mode_enabled?
      return false if matches.nil?
      if tls_mode?
        matches[:first] == 'clustercfg'
      else
        matches[:third].to_s == ''
      end
    end

    # Nil/shape safe
    def did_i_get_it_all?(slowlog)
      entries = Array(slowlog).select { |e| e.is_a?(Array) }
      return true if entries.empty?
      id = entries[-1][0] rescue nil
      return true if id.nil?
      id.to_i.zero?
    end

    def hostname
      URI.parse(@host).hostname || @host
    rescue URI::InvalidURIError
      @host
    end

    def matches
      @matches ||= redis_uri_regex.match(@host)
    end

    def port
      p = matches && matches[:port].to_i
      p.positive? ? p : 6379
    end

    def uri
      scheme = tls_mode? ? 'rediss' : 'redis'
      "#{scheme}://#{hostname}:#{port}"
    end

    def redis_uri_regex
      %r{
        ((?<scheme>redi[s]+)\://){0,1}
        (?<first>[0-9A-Za-z_-]+)\.
        (?<second>[0-9A-Za-z_-]+)\.{0,1}
        (?<third>[0-9A-Za-z_]*)\.
        (?<region>[0-9A-Za-z_-]+)\.cache\.amazonaws\.com
        :{0,1}(?<port>[0-9]*)
      }x
    end

    # TLS required when:
    # - env REDIS_TLS=true, OR
    # - scheme is rediss://, OR
    # - endpoint starts with master./clustercfg. (ElastiCache with in-transit encryption required)
    def tls_mode?
      return true if ENV['REDIS_TLS'].to_s.downcase == 'true'
      m = matches
      return false if m.nil?
      m[:scheme] == 'rediss' || %w[master clustercfg].include?(m[:first])
    end
  end
end
