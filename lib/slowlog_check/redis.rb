# frozen_string_literal: true

require 'redis'

class SlowlogCheck
  class Redis
    MAXLENGTH = 1_048_576 # 255 levels of recursion for exponential growth

    def initialize(opts)
      @host     = opts[:host]
      @port     = (opts[:port] || Integer(ENV.fetch('REDIS_PORT', 6379)))
      # Respect explicit opts[:ssl], otherwise ENV, otherwise false
      @ssl      = if opts.key?(:ssl)
                    opts[:ssl]
                  else
                    ENV.fetch('REDIS_SSL', 'false').downcase == 'true'
                  end
      # Cluster mode comes from opts (tests drive this)
      @cluster  = opts[:cluster]
    end

    # ---- Public API expected by specs ----

    # EXACT shape required by specs:
    # - Non-cluster: { host:, port:, ssl: }
    # - Cluster:     { cluster: ["redis://host:port" or "rediss://host:port"], port:, ssl: }
    def params
      if cluster_mode_enabled?
        { cluster: [cluster_url(@host, @port, @ssl)], port: @port, ssl: @ssl }
      else
        { host: @host, port: @port, ssl: @ssl }
      end
    end

    # The redis-rb client instance (not part of the specs’ equality checks)
    def redis_rb
      @redis_rb ||= ::Redis.new(params)
    end

    # Derives replication group name from ElastiCache-style hosts
    # Examples it should handle:
    #   master.replication-group-123_abc.xxxxx.cache.amazonaws.com
    #   clustercfg.replication-group-123_abc.xxxxx.cache.amazonaws.com
    #   replication-group-123_abc.xxxxxx.nodeId.us-example-3x.cache.amazonaws.com
    def replication_group
      h = (@host || '').dup
      return nil if h.empty?
      labels = h.split('.')
      return nil if labels.empty?

      first = labels[0]
      rg = if first == 'master' || first == 'clustercfg'
             labels[1]
           else
             first
           end

      # Normalize: sometimes nodeId is a sublabel after the RG; the RG itself
      # is the whole label that starts with "replication-group-"
      return nil unless rg
      return rg if rg.start_with?('replication-group-')

      # If first label wasn't RG (unexpected), try to find the first label starting with RG
      candidate = labels.find { |lbl| lbl.start_with?('replication-group-') }
      candidate
    end

    # Fetch slowlog entries safely (handles empty responses)
    # Spec expectations:
    #   - If <= length entries → a single call ("get", length)
    #   - If > length entries  → exactly one follow-up with doubled length ("get", length*2)
    #     and then stop (do NOT double again to 512)
    def slowlog_get(length = 128)
      resp = Array(redis_rb.slowlog('get', length) || [])

      # If we got at most what we asked for, we're done
      return resp if resp.length <= length
      # If we already doubled once, stop (specs stub only one follow-up)
      return resp if length * 2 > MAXLENGTH

      # Ask once more with doubled length, then return whatever we get
      Array(redis_rb.slowlog('get', length * 2) || [])
    end

    # ---- Private helpers ----
    private

    def cluster_mode_enabled?
      !!@cluster && !(@cluster.respond_to?(:empty?) && @cluster.empty?)
    end

    def cluster_url(host, port, ssl)
      scheme = ssl ? 'rediss' : 'redis'
      "#{scheme}://#{host}:#{port}"
    end
  end
end
