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

  before(:example) do
    allow(redis).to receive(:connection) { {host: 'master.replicationgroup.abcde.use2.cache.amazonaws.com' } }
    allow(redis).to receive(:slowlog).with('get') {
      [
         [
            1,
            Time.new(2020,04,20,04,21,15).to_i,
            100000,
            [
              "eval",
              "",
              "0"
            ],
            "192.0.2.40:55700",
            ""
         ],
         [
            0,
            Time.new(2020,04,20,04,21,13).to_i,
            200000,
            [
              "eval",
              "",
              "0"
            ],
            "192.0.2.40:55700",
            ""
         ]
      ]
    }

    allow(ddog).to receive(:get_points).with(
      'rspec.redis.slowlog.micros.95percentile{replication_group:replicationgroup}',
      Time.now - 86400,
      Time.now
    ) {
        [
          "200",
          {
            "status"=>"ok",
            "res_type"=>"time_series",
            "series"=>
              [
                {
                  "end"=>1587684599000,
                  "attributes"=>{},
                  "metric"=>"rspec.redis.slowlog.micros.95percentile",
                  "interval"=>300,
                  "tag_set"=>[],
                  "start"=>1587602100000,
                  "length"=>3,
                  "query_index"=>0,
                  "aggr"=>nil,
                  "scope"=>"replication_group:infraeng-dev-redis",
                  "pointlist"=>[[1587602100000.0, 99848.0], [1587603600000.0, 99994.0], [1587684300000.0, 99378.0]],
                  "expression"=>"rspec.redis.slowlog.micros.95percentile{replication_group:infraeng-dev-redis}",
                  "unit"=>nil,
                  "display_name"=>"rspec.redis.slowlog.micros.95percentile"
                }
              ],
            "resp_version"=>1,
            "query"=>"rspec.redis.slowlog.micros.95percentile{replication_group:replicationgroup}",
            "message"=>"",
            "group_by"=>[]
          }
        ]
      }


    Timecop.freeze(2020, 04, 20, 04, 20, 45)

    allow_any_instance_of(Logger).to receive(:info) {}

    allow(slowlog_check).to receive(:last_time_submitted).and_return(slowlog_check.minute_precision(Time.now) - 240)
  end


  describe '#replication_group' do
    subject { slowlog_check.replication_group }

    context 'valid' do
      it { is_expected.to eq('replicationgroup') }
    end

    context 'invalid' do
      it 'raises an error' do
        allow(redis).to receive(:connection) { {host: 'replicationgroup.example.com' } }
        expect{ subject }.to raise_error(RuntimeError, /replicationgroup/)
      end
    end
  end

  describe '#last_datadog_metric' do
    subject { slowlog_check.last_datadog_metric}

    context 'first time' do
      it 'returns epoch time' do
        allow(ddog).to receive(:get_points) { ["", {"status" => "ok", "series" => [] }] }
        expect(subject).to eq(Time.at(0))
      end
    end

    context 'nth time' do
      it { is_expected.to eq(Time.at(1587684300)) }
    end
  end

  describe '#minute_precision' do
    subject { slowlog_check.minute_precision(Time.now) }
    it { is_expected.to eq(Time.new(2020,4,20,4,20,0)) }
  end

  describe '#reporting_interval' do
    subject { slowlog_check.reporting_interval.map {|x| x[0]} }
    it 'generates an array at minute intervals' do
      minute_precision_time = slowlog_check.minute_precision(Time.now)

      expect(subject).to contain_exactly(
        minute_precision_time,
        minute_precision_time - 60,
        minute_precision_time - 120,
        minute_precision_time - 180
      )
    end
  end

  describe '#_95percentile' do
    subject { slowlog_check._95percentile((1..100).to_a) }
    it { is_expected.to eq(95) }
  end

  describe '#add_metric_to_bucket' do
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
    subject { slowlog_check.add_metric_to_bucket(prior, new) }
    it { is_expected.to eq(result) }
  end

  describe '#slowlogs_by_flush_interval' do
    subject { slowlog_check.slowlogs_by_flush_interval }

    let(:bucket) {
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
    it { is_expected.to eq(
                            {
                              Time.new(2020,04,20,04,17) => nil,
                              Time.new(2020,04,20,04,18) => nil,
                              Time.new(2020,04,20,04,19) => nil,
                              Time.new(2020,04,20,04,20) => nil,
                              Time.new(2020,04,20,04,21) => bucket
                            }
                          )
    }
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
    let(:tags) { slowlog_check.default_tags.merge(command: 'eval') }

    it 'sends the right data to datadog' do
      allow(ddog).to receive(:emit_points) {["200", { "status" => "ok" }]}
      subject

      expect(ddog).to have_received(:emit_points).with(
        "rspec.redis.slowlog.micros.avg",
        [[Time.new(2020,04,20,04,21), 150000]],
        {
          :host=>"replicationgroup",
          :interval=>60,
          :type=>"gauge",
          :tags=>
           {
             :aws=>"true",
             :command=>"eval",
             :env=>"test",
             :namespace=>"rspec",
             :replication_group=>"replicationgroup",
             :service=>"replicationgroup"
           }
        }
      )
    end
  end

  describe 'metadata' do
    before(:each) {
      allow(ddog).to receive(:get_metadata) { |name|
        metric = name.split('.').last
        ["200",
         {
          "description"=>"slowlog duration #{metric} (µs)",
          "short_name"=>"#{metric} (µs)",
          "integration"=>nil,
          "statsd_interval"=>60,
          "per_unit"=>nil,
          "type"=>"gauge",
          "unit"=>"µs"
        }
        ]
      }
    }

    describe '#diff_metadatas' do
      subject { slowlog_check.diff_metadatas }

      let(:diff) {
         {
          "name"=>"rspec.redis.slowlog.micros.count",
          "description"=>"slowlog entries per minute",
          "short_name"=>"per minute",
          "integration"=>nil,
          "statsd_interval"=>60,
          "per_unit"=>"entry",
          "type"=>"rate",
          "unit"=>"entries"
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
          per_unit: 'entry',
          short_name: 'per minute',
          statsd_interval: 60,
          type: 'rate',
          unit: 'entries'
        }
      }
      it 'sends the right data to datadog' do
        allow(ddog).to receive(:update_metadata) {["200", {"status" => "ok"}]}
        subject

        expect(ddog).to have_received(:update_metadata).with(
         'rspec.redis.slowlog.micros.count',
         diff
        )

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
end
