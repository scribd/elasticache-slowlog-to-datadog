# frozen_string_literal: true

require 'spec_helper'

describe SlowlogCheck::Redis do
  before(:example) { allow(Redis).to receive(:new) }

  ##
  # Shared Contexts
  #
  # See https://docs.aws.amazon.com/AmazonElastiCache/latest/red-ug/Endpoints.html
  #  for the four permutations of host strings

  # Cluster Mode Disabled or Enabled : TLS or not : hostname form or uri form

  shared_context 'CMD:no TLS' do
    let(:redis) { described_class.new(host: 'replication-group-123_abc.xxxxxx.nodeId.us-example-3x.cache.amazonaws.com') }
  end
  shared_context 'CMD:no TLS:uri' do
    let(:redis) { described_class.new(host: 'redis://replication-group-123_abc.xxxxxx.nodeId.us-example-3x.cache.amazonaws.com:42') }
  end
  shared_context 'CMD:TLS' do
    let(:redis) { described_class.new(host: 'master.replication-group-123_abc.xxxxxx.us-example-3x.cache.amazonaws.com') }
  end
  shared_context 'CMD:TLS:uri' do
    let(:redis) { described_class.new(host: 'rediss://master.replication-group-123_abc.xxxxxx.us-example-3x.cache.amazonaws.com:42') }
  end

  # cluster Mode Enabled

  shared_context 'CME:no TLS' do
    let(:redis) { described_class.new(host: 'replication-group-123_abc.xxxxxx.us-example-3x.cache.amazonaws.com') }
  end
  shared_context 'CME:no TLS:uri' do
    let(:redis) { described_class.new(host: 'redis://replication-group-123_abc.xxxxxx.us-example-3x.cache.amazonaws.com:42') }
  end
  shared_context 'CME:TLS' do
    let(:redis) { described_class.new(host: 'clustercfg.replication-group-123_abc.xxxxxx.us-example-3x.cache.amazonaws.com') }
  end
  shared_context 'CME:TLS:uri' do
    let(:redis) { described_class.new(host: 'rediss://clustercfg.replication-group-123_abc.xxxxxx.us-example-3x.cache.amazonaws.com:42') }
  end

  describe 'Parsing parameters' do
    describe '#params' do
      context 'REDIS_HOST' do
        context 'Cluster mode disabled' do
          context 'CMD:no TLS' do
            include_context 'CMD:no TLS'
            subject { redis.params }

            it {
              is_expected.to eq(
                host: 'replication-group-123_abc.xxxxxx.nodeId.us-example-3x.cache.amazonaws.com',
                port: 6379,
                ssl: false
              )
            }
          end

          context 'CMD:no TLS:uri' do
            include_context 'CMD:no TLS:uri'
            subject { redis.params }

            it {
              is_expected.to eq(
                host: 'replication-group-123_abc.xxxxxx.nodeId.us-example-3x.cache.amazonaws.com',
                port: 42,
                ssl: false
              )
            }
          end

          context 'CMD:TLS' do
            include_context 'CMD:TLS'
            subject { redis.params }

            it {
              is_expected.to eq(
                host: 'master.replication-group-123_abc.xxxxxx.us-example-3x.cache.amazonaws.com',
                port: 6379,
                ssl: true
              )
            }
          end

          context 'CMD:TLS:uri' do
            include_context 'CMD:TLS:uri'
            subject { redis.params }

            it {
              is_expected.to eq(
                host: 'master.replication-group-123_abc.xxxxxx.us-example-3x.cache.amazonaws.com',
                port: 42,
                ssl: true
              )
            }
          end
        end

        context 'Cluster mode enabled' do
          context 'CME:no TLS' do
            include_context 'CME:no TLS'
            subject { redis.params }

            it {
              is_expected.to eq(
                cluster: ['redis://replication-group-123_abc.xxxxxx.us-example-3x.cache.amazonaws.com:6379'],
                port: 6379,
                ssl: false
              )
            }
          end

          context 'CME:no TLS:uri' do
            include_context 'CME:no TLS:uri'
            subject { redis.params }

            it {
              is_expected.to eq(
                cluster: ['redis://replication-group-123_abc.xxxxxx.us-example-3x.cache.amazonaws.com:42'],
                port: 42,
                ssl: false
              )
            }
          end

          context 'CME:TLS' do
            include_context 'CME:TLS'
            subject { redis.params }

            it {
              is_expected.to eq(
                cluster: ['rediss://clustercfg.replication-group-123_abc.xxxxxx.us-example-3x.cache.amazonaws.com:6379'],
                port: 6379,
                ssl: true
              )
            }
          end

          context 'CME:TLS:uri' do
            include_context 'CME:TLS:uri'
            subject { redis.params }

            it {
              is_expected.to eq(
                cluster: ['rediss://clustercfg.replication-group-123_abc.xxxxxx.us-example-3x.cache.amazonaws.com:42'],
                port: 42,
                ssl: true
              )
            }
          end
        end
      end
    end

    describe '#replication_group' do
      context 'Cluster mode disabled' do
        context 'CMD:no TLS' do
          include_context 'CMD:no TLS'
          subject { redis.replication_group }

          it { is_expected.to eq('replication-group-123_abc') }
        end

        context 'CMD:TLS' do
          include_context 'CMD:TLS'
          subject { redis.replication_group }

          it { is_expected.to eq('replication-group-123_abc') }
        end
      end

      context 'Cluster mode enabled' do
        context 'CME:no TLS' do
          include_context 'CME:no TLS'
          subject { redis.replication_group }

          it { is_expected.to eq('replication-group-123_abc') }
        end

        context 'CME:TLS' do
          include_context 'CME:TLS'
          subject { redis.replication_group }

          it { is_expected.to eq('replication-group-123_abc') }
        end
      end
    end
  end

  describe '#slowlog_get' do
    include_context 'CME:TLS' # which context doesn't matter, so pick any one

    # mock the redis-rb gem
    let(:redis_rb) { double }
    before(:example) { allow(redis).to receive(:redis_rb).and_return(redis_rb) }

    describe '#slowlog_get.length' do
      context 'redis has 4 entries' do
        before(:each) do
          # see spec_helper for redis_slowlog definition
          allow(redis_rb).to receive(:slowlog).with('get', 128) {
            [
              redis_slowlog(3, Time.utc(2020, 4, 20, 4, 19, 45), 400_000),
              redis_slowlog(2, Time.utc(2020, 4, 20, 4, 19, 15), 100_000),
              redis_slowlog(1, Time.utc(2020, 4, 20, 4, 18, 45), 100_000),
              redis_slowlog(0, Time.utc(2020, 4, 20, 4, 18, 15), 200_000)
            ]
          }
        end

        subject { redis.slowlog_get.length }
        it { is_expected.to eq(4) }
      end

      context 'redis has 129 entries and a zeroeth entry' do
        before(:each) do
          allow(redis_rb).to receive(:slowlog).with('get', 128) {
            Array.new(129) do |x|
              redis_slowlog(x, Time.utc(2020, 4, 20, 4, 0, 0) + x, x * 1000)
            end.reverse[0..127]
          }

          allow(redis_rb).to receive(:slowlog).with('get', 256) {
            Array.new(129) do |x|
              redis_slowlog(x, Time.utc(2020, 4, 20, 4, 0, 0) + x, x * 1000)
            end.reverse
          }
        end

        subject { redis.slowlog_get.length }
        it { is_expected.to eq(129) }
      end

      context 'redis has 1048576 * 2 + 1 entries and a zeroeth entry' do
        let(:sauce) do
          Array.new(1_048_576 * 2 + 1) do |x|
            redis_slowlog(x, 1_587_352_800, x) # lettuce not create so many unnecessary Time objects
          end.reverse
        end
        before(:each) do
          allow(redis_rb).to receive(:slowlog) { |_, number|
            sauce[0..number - 1]
          }
        end

        subject { redis.slowlog_get.length }
        it { is_expected.to eq(1_048_576 * 2) } # with the last entry dropped
      end

      context 'redis has 567 entries and no zeroeth entry' do
        let(:sauce) do
          Array.new(567) do |x|
            redis_slowlog(x + 1, Time.utc(2020, 4, 20, 3, 20, 0) + x, x)
          end.reverse
        end
        before(:each) do
          allow(redis_rb).to receive(:slowlog) { |_, number|
            sauce[0..number - 1]
          }
        end

        subject { redis.slowlog_get.length }
        it { is_expected.to eq(567) }
      end
    end
  end
end
