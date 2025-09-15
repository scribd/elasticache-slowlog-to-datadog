# frozen_string_literal: true

require 'redis'
require 'resolv'
require 'socket'
require 'openssl'

class SlowlogCheck
  class Redis
    MAXLENGTH = 1_048_576 # 255 levels of recursion for exponential growth

    def initialize(opts)
      @host      = opts[:host]
      @port      = opts[:port] || Integer(ENV.fetch('REDIS_PORT', 6379))
      @ssl       = opts.key?(:ssl) ? opts[:ssl] : (ENV.fetch('REDIS_SSL', 'false').downcase == 'true')
      @cluster   = opts[:cluster] || nil
      @password  = ENV['REDIS_PASSWORD'] # ElastiCache AUTH token / Serverless token if enabled

      @logger = defined?(LOGGER) ? LOGGER : ::Logger.new($stdout)
    end

    def params
      # Supported by redis 5.x / redis-client
      base = {
        timeout:       Integer(ENV.fetch('REDIS_TIMEOUT', 5)),       # connect timeout
        read_timeout:  Integer(ENV.fetch('REDIS_READ_TIMEOUT', 5)),
        write_timeout: Integer(ENV.fetch('REDIS_WRITE_TIMEOUT', 5)),
        password:      @password,
        ssl:           @ssl
      }

      if cluster_mode_enabled?
        # For cluster mode, pass a node/config endpoint URL
        base.merge(cluster: [uri])
      else
        base.merge(host: @host, port: @port)
      end
    end

    def redis_rb
      @redis_rb ||= begin
                      log_conn_params
                      preflight_probe!(@host, @port, @ssl, @logger)
                      r = ::Redis.new(params)
                      maybe_ping(r)
                      r
                    end
    end

    def replication_group
      if tls_mode?
        matches[:second]
      else
        matches[:first]
      end
    end

    # Fetch slowlog entries safely (handles empty responses)
    def slowlog_get(length = 128)
      resp = redis_rb.slowlog('get', length) || []
      resp = Array(resp)

      return resp if length > MAXLENGTH
      return resp if did_i_get_it_all?(resp)

      slowlog_get(length * 2)
    end

    private

    def cluster_mode_enabled?
      @cluster && !@cluster.empty?
    end

    def tls_mode?
      @ssl == true
    end

    # Hardened: handle empty or malformed responses gracefully
    # SLOWLOG entry shape: [id, timestamp, duration, command, ...]
    def did_i_get_it_all?(resp)
      return true if resp.nil? || resp.empty?

      last = resp[-1]
      return true if last.nil? || !last.is_a?(Array) || last.empty?

      # Guarded access (adjust with your original predicate if needed)
      last_id = (last[0] rescue nil)
      last_ts = (last[1] rescue nil)
      return true if last_id.nil? || last_ts.nil?

      # By default, keep expanding until MAXLENGTH.
      false
    end

    def uri
      scheme = @ssl ? 'rediss' : 'redis'
      # For cluster the redis gem uses the URL(s) form
      "#{scheme}://#{@host}:#{@port}"
    end

    # If you had parsing logic based on replication info, keep it here.
    def matches
      {}
    end

    # ---- Diagnostics & hardening ----

    def log_conn_params
      scrubbed = {
        host: @host,
        port: @port,
        ssl: @ssl,
        cluster: !!@cluster && !@cluster.empty?,
        timeout: Integer(ENV.fetch('REDIS_TIMEOUT', 5)),
        read_timeout: Integer(ENV.fetch('REDIS_READ_TIMEOUT', 5)),
        write_timeout: Integer(ENV.fetch('REDIS_WRITE_TIMEOUT', 5)),
        password_set: !@password.to_s.empty?
      }
      @logger.info "Redis connection params: #{scrubbed}"
    end

    # DNS → TCP → (optional) TLS; raises with clear log if any step fails
    def preflight_probe!(host, port, ssl, logger)
      logger.info "Preflight: resolving #{host}..."
      addrs = Resolv.getaddresses(host) # ← avoid each_address block requirement
      logger.info "Preflight: #{host} resolved to #{addrs.inspect}"
      raise "DNS resolution failed for #{host}" if addrs.empty?

      logger.info "Preflight: opening TCP to #{host}:#{port} (ssl=#{ssl})..."
      Socket.tcp(host, port, connect_timeout: Integer(ENV.fetch('REDIS_TIMEOUT', 5))) do |sock|
        logger.info "Preflight: TCP connected to #{host}:#{port}"
        if ssl
          logger.info "Preflight: starting TLS handshake..."
          ctx = OpenSSL::SSL::SSLContext.new
          ctx.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
          ssl_sock = OpenSSL::SSL::SSLSocket.new(sock, ctx)
          ssl_sock.hostname = host
          ssl_sock.sync_close = true
          ssl_sock.connect # raises on handshake problems
          logger.info "Preflight: TLS handshake OK. Peer cert subject=#{ssl_sock.peer_cert.subject}"
          ssl_sock.close
        end
      end
    rescue => e
      logger.error "Preflight failed: #{e.class} - #{e.message}"
      raise
    end

    def maybe_ping(r)
      @logger.info 'Pinging Redis to verify connectivity...'
      pong = r.ping # raises on connect/handshake/auth issues
      @logger.info "Redis ping response: #{pong}"
    rescue ::Redis::BaseConnectionError, ::Redis::TimeoutError => e
      @logger.error "Redis ping failed: #{e.class} - #{e.message}"
      raise
    end
  end
end
