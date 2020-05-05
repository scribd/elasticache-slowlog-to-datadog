require 'slowlog_check'
require 'timecop'

describe SlowlogCheck do
  let(:ddog) { double() }
  let(:redis) { double() }
  let(:slowlog_check) {
    SlowlogCheck.new(
      ddog: ddog,
      redis: redis,
      metricname: 'rspec.redis.slowlog.micros',
      namespace: 'rspec',
      env: 'test'

    )
  }
  let(:frozen_time) { Time.utc(2020, 4, 20, 4, 20, 45) }
  let(:four_minutes_ago) { Time.utc(2020, 4, 20, 4, 16, 12).to_i * 1000.0 }

  def redis_slowlog(index, time, microseconds, command = 'eval')
    [
      index,
      time.to_i,
      microseconds,
      [
        command,
        "",
        "0"
      ],
      "192.0.2.40:55700",
      ""
    ]
  end

  before(:example) do
    ##
    # redis mock
    allow(redis).to receive(:connection) { {host: 'master.replicationgroup.abcde.use2.cache.amazonaws.com'} }
    allow(redis).to receive(:slowlog).with('get', 128) {
      [
        redis_slowlog(3, Time.utc(2020, 4, 20, 4, 19, 45), 400000),
        redis_slowlog(2, Time.utc(2020, 4, 20, 4, 19, 15), 100000),
        redis_slowlog(1, Time.utc(2020, 4, 20, 4, 18, 45), 100000),
        redis_slowlog(0, Time.utc(2020, 4, 20, 4, 18, 15), 200000),
      ]
    }

    ##
    # ddog mock
    allow(ddog).to receive(:get_points).with(
      'rspec.redis.slowlog.micros.95percentile{replication_group:replicationgroup}',
      Time.now - 7200,
      Time.now
    ) {
      [
        "200",
        {
          "status" => "ok",
          "res_type" => "time_series",
          "series" =>
            [
              {
                "end" => 1587684599000,
                "attributes" => {},
                "metric" => "rspec.redis.slowlog.micros.95percentile",
                "interval" => 300,
                "tag_set" => [],
                "start" => 1587602100000,
                "length" => 3,
                "query_index" => 0,
                "aggr" => nil,
                "scope" => "replication_group:replicationgroup",
                "pointlist" => [[four_minutes_ago, 99994.0], [four_minutes_ago - 5000, 99378.0]],
                "expression" => "rspec.redis.slowlog.micros.95percentile{replication_group:infraeng-dev-redis}",
                "unit" => nil,
                "display_name" => "rspec.redis.slowlog.micros.95percentile"
              }
            ],
          "resp_version" => 1,
          "query" => "rspec.redis.slowlog.micros.95percentile{replication_group:replicationgroup}",
          "message" => "",
          "group_by" => []
        }
      ]
    }

    # Freeze time
    Timecop.freeze(frozen_time)

    # Shhh...
    allow_any_instance_of(Logger).to receive(:info) {}
  end

  describe '#redis_slowlog.length' do
    context 'redis has 4 entries' do
      before(:each) do
        allow(redis).to receive(:slowlog).with('get', 128) {
          [
            redis_slowlog(3, Time.utc(2020, 4, 20, 4, 19, 45), 400000),
            redis_slowlog(2, Time.utc(2020, 4, 20, 4, 19, 15), 100000),
            redis_slowlog(1, Time.utc(2020, 4, 20, 4, 18, 45), 100000),
            redis_slowlog(0, Time.utc(2020, 4, 20, 4, 18, 15), 200000),
          ]
        }
      end

      subject { slowlog_check.redis_slowlog.length }
      it { is_expected.to eq(4) }
    end

    context 'redis has 129 entries and a zeroeth entry' do
      before(:each) do
        allow(redis).to receive(:slowlog).with('get', 128) {
          Array.new(129) { |x|
            redis_slowlog(x, Time.utc(2020, 4, 20, 4, 0, 0) + x, x * 1000)
          }.reverse[0..127]
        }

        allow(redis).to receive(:slowlog).with('get', 256) {
          Array.new(129) { |x|
            redis_slowlog(x, Time.utc(2020, 4, 20, 4, 0, 0) + x, x * 1000)
          }.reverse
        }

      end

      subject { slowlog_check.redis_slowlog.length }
      it { is_expected.to eq(129) }
    end

    context 'redis has 1048576 * 2 + 1 entries and a zeroeth entry' do
      let(:sauce) {
        Array.new(1048576 * 2 + 1) { |x|
          redis_slowlog(x, 1587352800, x) #lettuce not create so many unnecessary Time objects
        }.reverse
      }
      before(:each) do
        allow(redis).to receive(:slowlog) { |_, number|
          sauce[0..number - 1]
        }
      end

      subject { slowlog_check.redis_slowlog.length }
      it { is_expected.to eq(1048576 * 2) } # with the last entry dropped
    end

    context 'redis has 567 entries and no zeroeth entry' do
      let(:sauce) {
        Array.new(567) { |x|
          redis_slowlog(x + 1, Time.utc(2020, 4, 20, 3, 20, 0) + x, x)
        }.reverse
      }
      before(:each) do
        allow(redis).to receive(:slowlog) { |_, number|
          sauce[0..number - 1]
        }
      end

      subject { slowlog_check.redis_slowlog.length }
      it { is_expected.to eq(567) }

    end
  end

  describe '#replication_group' do
    subject { slowlog_check.replication_group }

    context 'valid' do
      it { is_expected.to eq('replicationgroup') }
    end

    context 'invalid' do
      it 'raises an error' do
        allow(redis).to receive(:connection) { {host: 'replicationgroup.example.com'} }
        expect { subject }.to raise_error(RuntimeError, /replicationgroup/)
      end
    end
  end

  describe '#status_or_error' do
    context 'ok' do
      subject { slowlog_check.status_or_error(["200", {"status" => "ok"}]) }
      it { is_expected.to eq('ok') }
    end

    context 'error' do
      subject { slowlog_check.status_or_error(["404", {"errors" => ["error"]}]) }
      it { is_expected.to eq(['error']) }
    end

    context 'otherwise' do
      subject { slowlog_check.status_or_error(["404", {"somenewthing" => ["error"]}]) }
      it { is_expected.to eq(["404", {"somenewthing" => ['error']}]) }
    end

  end

  describe '#last_datadog_metric' do
    subject { slowlog_check.last_datadog_metric }

    context 'first time' do
      it 'returns time an hour ago' do
        allow(ddog).to receive(:get_points) { ["", {"status" => "ok", "series" => []}] }
        expect(subject).to eq(Time.utc(2020, 4, 20, 3, 20))
      end
    end

    context 'nth time' do
      it { is_expected.to eq(Time.utc(2020, 4, 20, 4, 16)) }
    end
  end

  describe '#minute_precision' do
    subject { slowlog_check.minute_precision(Time.now) }
    it { is_expected.to eq(Time.utc(2020, 4, 20, 4, 20, 0)) }
  end

  describe '#reporting_interval' do
    subject { slowlog_check.reporting_interval }
    focus 'generates an array at minute intervals' do
      expect(subject).to eq(
                           Time.utc(2020, 4, 20, 4, 19).localtime => {},
                           Time.utc(2020, 4, 20, 4, 18).localtime => {},
                           Time.utc(2020, 4, 20, 4, 17).localtime => {},
                         )
    end
  end

  describe '#_95percentile' do
    subject { slowlog_check._95percentile((1..100).to_a) }
    it { is_expected.to eq(95) }
  end

  describe '#add_metric_to_bucket' do
    subject { slowlog_check.add_metric_to_bucket(prior, new) }
    let(:prior) {
      {
        values: [10],
        avg: 10,
        count: 1,
        median: 10,
        _95percentile: 10,
        min: 10,
        max: 10,
        sum: 10
      }
    }
    let(:new) { 20 }
    let(:result) {
      {
        values: [10, 20],
        avg: 15,
        count: 2,
        median: 10,
        _95percentile: 10,
        min: 10,
        max: 20,
        sum: 30
      }
    }
    it { is_expected.to eq(result) }
  end

  describe '#pad_results_with_zero' do
    let(:report) {
      {
        Time.utc(2020, 4, 20, 4, 16) => {"a" => {}},
        Time.utc(2020, 4, 20, 4, 17) => {"b" => {}},
        Time.utc(2020, 4, 20, 4, 18) => {},
        Time.utc(2020, 4, 20, 4, 19) => {"a" => {}},
      }

    }
    subject { slowlog_check.pad_results_with_zero(report) }
    it { is_expected.to eq(
                          {
                            Time.utc(2020, 4, 20, 4, 16) => {"a" => {}},
                            Time.utc(2020, 4, 20, 4, 17) => {"b" => {}, "a" => slowlog_check.empty_values},
                            Time.utc(2020, 4, 20, 4, 18) => {"b" => slowlog_check.empty_values},
                            Time.utc(2020, 4, 20, 4, 19) => {"a" => {}},

                          }
                        )
    }

    describe '#new_commands' do
      subject { slowlog_check.new_commands(Time.utc(2020, 4, 20, 4, 16), {"a" => {}}) }
      it { is_expected.to eq({"a" => Time.utc(2020, 4, 20, 4, 16).localtime}) }
    end
  end

  describe '#slowlogs_by_flush_interval' do
    subject { slowlog_check.slowlogs_by_flush_interval }
    let(:bucket18) {
      {
        "eval" =>
          {
            _95percentile: 100000,
            avg: 150000,
            count: 2,
            max: 200000,
            median: 100000,
            min: 100000,
            sum: 300000,
            values: [100000, 200000]
          }
      }
    }
    let(:bucket19) {
      {
        "eval" =>
          {
            _95percentile: 100000,
            avg: 250000,
            count: 2,
            max: 400000,
            median: 100000,
            min: 100000,
            sum: 500000,
            values: [400000, 100000]
          }
      }
    }

    it { is_expected.to eq(
                          {
                            Time.utc(2020, 4, 20, 4, 17).localtime => {},
                            Time.utc(2020, 4, 20, 4, 18).localtime => bucket18,
                            Time.utc(2020, 4, 20, 4, 19).localtime => bucket19,
                          }
                        )
    }

    describe 'remembers commands it has seen' do
      def example_bucket(index)
        value = index + 1000
        collector = {
          index.to_s =>
            {
              _95percentile: value,
              avg: value,
              count: value == 0 ? value : 1,
              max: value,
              median: value,
              min: value,
              sum: value,
              values: value == 0 ? [] : [value]
            }
        }
        if index > 0
          collector.merge!({(index -1).to_s => slowlog_check.empty_values})
        end
        collector
      end

      before(:example) {
        allow(redis).to receive(:slowlog).with('get', 128) {
          Array.new(5) { |x|
            redis_slowlog(x, Time.utc(2020, 04, 20, 04, 15, 10) + (x * 60), x + 1000, x.to_s)
          }.reverse
        }

        allow(slowlog_check).to receive(:last_time_submitted) { Time.utc(2020, 4, 20, 4, 14) }
      }

      it { is_expected.to eq(
                            {
                              Time.utc(2020, 4, 20, 4, 15).localtime => example_bucket(0),
                              Time.utc(2020, 4, 20, 4, 16).localtime => example_bucket(1),
                              Time.utc(2020, 4, 20, 4, 17).localtime => example_bucket(2),
                              Time.utc(2020, 4, 20, 4, 18).localtime => example_bucket(3),
                              Time.utc(2020, 4, 20, 4, 19).localtime => example_bucket(4),
                            }
                          )
      }

    end
  end

  describe '#default_tags' do
    subject { slowlog_check.default_tags }
    it { is_expected.to eq(
                          {
                            aws: 'true',
                            env: 'test',
                            namespace: 'rspec',
                            replication_group: 'replicationgroup',
                            service: 'replicationgroup',
                          }
                        )
    }
  end

  describe '#ship_slowlogs' do
    subject { slowlog_check.ship_slowlogs }
    let(:options) {
      {
        :host => "replicationgroup",
        :interval => 60,
        :type => "gauge",
        :tags =>
          {
            :aws => "true",
            :command => "eval",
            :env => "test",
            :namespace => "rspec",
            :replication_group => "replicationgroup",
            :service => "replicationgroup"
          }
      }
    }

    it 'sends the right data to datadog' do
      allow(ddog).to receive(:emit_points) { ["200", {"status" => "ok"}] }
      subject

      expect(ddog).to have_received(:emit_points).with(
        "rspec.redis.slowlog.micros.avg",
        [[Time.utc(2020, 4, 20, 4, 18), 150000]],
        options
      )

      expect(ddog).to have_received(:emit_points).with(
        "rspec.redis.slowlog.micros.avg",
        [[Time.utc(2020, 4, 20, 4, 19), 250000]],
        options
      )
    end
  end

  describe 'metadata' do
    before(:each) {
      allow(ddog).to receive(:get_metadata) { |name|
        metric = name.split('.').last
        ["200",
         {
           "description" => "slowlog duration #{metric} (µs)",
           "short_name" => "#{metric} (µs)",
           "integration" => nil,
           "statsd_interval" => 60,
           "per_unit" => nil,
           "type" => "gauge",
           "unit" => "microsecond"
         }
        ]
      }
    }

    describe '#diff_metadatas' do
      subject { slowlog_check.diff_metadatas }
      let(:diff) {
        {
          "name" => "rspec.redis.slowlog.micros.count",
          "description" => "slowlog entries per minute",
          "short_name" => "per minute",
          "integration" => nil,
          "statsd_interval" => 60,
          "per_unit" => "minute",
          "type" => "rate",
          "unit" => "entry"
        }
      }
      it { is_expected.to contain_exactly(diff) }
    end

    describe '#update_metadatas' do
      subject { slowlog_check.update_metadatas }
      let(:diff) {
        {
          description: 'slowlog entries per minute',
          integration: nil,
          per_unit: 'minute',
          short_name: 'per minute',
          statsd_interval: 60,
          type: 'rate',
          unit: 'entry'
        }
      }
      it 'sends the right data to datadog' do
        allow(ddog).to receive(:update_metadata) { ["200", {"status" => "ok"}] }
        subject

        expect(ddog).to have_received(:update_metadata).with(
          'rspec.redis.slowlog.micros.count',
          diff
        )
      end
    end
  end
end
