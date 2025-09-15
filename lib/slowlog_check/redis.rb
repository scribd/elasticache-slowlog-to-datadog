# frozen_string_literal: true

require 'redis'
require 'uri'

class SlowlogCheck
  class Redis
    MAXLENGTH = 1_048_576 # 255 levels of recursion for exponential growth

    def initialize(opts)
      raw_host = opts[:host].to_s
      parsed   = parse_host_port(raw_host)

      @host = parsed[:host]
      @port = (opts[:port] || parsed[:port] || Integer(ENV.fetch('REDIS_PORT', 6379)))

      # SSL precedence: explicit opts[:ssl] → URI scheme rediss → truthy ENV REDIS_SSL → false
      @ssl =
        if opts.key?(:ssl)
          to_bool(opts[:ssl])
        elsif parsed[:scheme] == 'rediss'
          true
        else
          env_truthy?(ENV['REDIS_SSL'])
        end

      # Cluster mode: honor explicit flag if provided, else infer from hostname
      @cluster =
        if opts.key?(:cluster)
          to_bool(opts[:cluster])
        else
          infer_cluster_from_host(@host)
        end
    end

    # -------- Public API expected by specs --------

    # EXACT shapes required by specs:
    # - Non-cluster: { host:, port:, ssl: }
    # - Cluster:     { cluster: ["redis://host:port"|"rediss://host:port"], port:, ssl: }
    def params
      if cluster_mode_enabled?
        { cluster: [cluster_url(@host, @port, @ssl)], port: @port, ssl: @ssl }
      else
        { host: @host, port: @port, ssl: @ssl }
      end
    end

    def redis_rb
      @redis_rb ||= ::Redis.new(params)
    end

    # Parse replication group from common ElastiCache hostnames
    def replication_group
      h = @host.to_s
      return nil if h.empty?

      labels = h.split('.')
      return nil if labels.empty?

      first = labels[0]

      rg =
        case first
        when 'master', 'clustercfg'
          labels[1]
        else
          first
        end

      return nil unless rg

      unless rg.start_with?('replication-group-') || rg == 'replicationgroup'
        candidate = labels.find { |lbl| lbl.start_with?('replication-group-') || lbl == 'replicationgroup' }
        rg = candidate if candidate
      end

      rg
    end

    # Keep doubling until Redis returns fewer than requested (we got it all) or we hit 2*MAXLENGTH
    # Also expands once immediately if we spot a "zeroeth entry" sentinel.
    def slowlog_get(length = 128)
      # Hard cap per spec expectation (they assert 2*MAXLENGTH at the extreme)
      max_cap = MAXLENGTH * 2

      req_len = length
      resp    = Array(redis_rb.slowlog('get', req_len) || [])

      # If first page shows "zeroeth entry", force an expansion pass
      force_expand_once = zeroeth_entry?(resp) && req_len < max_cap

      if force_expand_once
        req_len = [req_len * 2, max_cap].min
        resp    = Array(redis_rb.slowlog('get', req_len) || [])
      end

      # Continue expanding while the page is full (== requested) and we haven't hit the cap
      while resp.length == req_len && req_len < max_cap
        req_len = [req_len * 2, max_cap].min
        resp    = Array(redis_rb.slowlog('get', req_len) || [])
      end

      resp
    end

    # -------- Private helpers --------
    private

    def cluster_mode_enabled?
      !!@cluster
    end

    def cluster_url(host, port, ssl)
      "#{ssl ? 'rediss' : 'redis'}://#{host}:#{port}"
    end

    def parse_host_port(raw)
      out = { scheme: nil, host: nil, port: nil }

      if raw.include?('://')
        uri = URI.parse(raw)
        out[:scheme] = uri.scheme
        out[:host]   = (uri.host || '').dup
        out[:port]   = uri.port
      else
        host_part, port_part = raw.split(':', 2)
        out[:host] = host_part
        out[:port] = Integer(port_part) if port_part && port_part =~ /^\d+$/
      end

      out
    rescue
      { scheme: nil, host: raw, port: nil }
    end

    # Cluster when hostname begins with "clustercfg." or with "replication-group-" and isn't a nodeId leaf
    def infer_cluster_from_host(host)
      return false if host.to_s.empty?
      first = host.split('.').first
      return true if first == 'clustercfg'
      return true if first&.start_with?('replication-group-') && !host.include?('.nodeId.')
      false
    end

    # A “zeroeth entry” (id==0) suggests more data; tests refer to this case explicitly
    def zeroeth_entry?(resp)
      first = resp.first
      return false unless first.is_a?(Array) && first.size >= 1
      first[0] == 0
    rescue
      false
    end

    def to_bool(val)
      case val
      when true, false then val
      when Integer     then val != 0
      else
        env_truthy?(val)
      end
    end

    def env_truthy?(v)
      %w[true 1 yes on y].include?(v.to_s.strip.downcase)
    end
  end
end
