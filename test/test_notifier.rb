require 'helper'

RANDOM_DATA = ('A'..'Z').to_a

class TestNotifier < Test::Unit::TestCase
  should "allow access to host, port and default_options" do
    Socket.expects(:gethostname).returns('default_hostname')
    n = SyslogSD::Notifier.new
    assert_equal [['localhost', 514]], n.addresses
    assert_equal( { 'level' => SyslogSD::UNKNOWN,
                    'host' => 'default_hostname', 'facility' => 'syslog-sd-rb',
                    'procid' => Process.pid },
                  n.default_options )
    n.addresses, n.default_options = [['graylog2.org', 7777]], {:host => 'grayhost'}
    assert_equal [['graylog2.org', 7777]], n.addresses
    assert_equal({'host' => 'grayhost'}, n.default_options)
  end

  context "with notifier with mocked sender" do
    setup do
      Socket.stubs(:gethostname).returns('stubbed_hostname')
      @notifier = SyslogSD::Notifier.new('host', 12345)
      @sender = mock
      @notifier.instance_variable_set('@sender', @sender)
    end

    context "extract_hash" do
      should "check arguments" do
        assert_raise(ArgumentError) { @notifier.__send__(:extract_hash) }
        assert_raise(ArgumentError) { @notifier.__send__(:extract_hash, 1, 2, 3) }
      end

      should "work with hash" do
        hash = @notifier.__send__(:extract_hash, { 'version' => '1.0', 'short_message' => 'message' })
        assert_equal '1.0', hash['version']
        assert_equal 'message', hash['short_message']
      end

      should "work with any object which responds to #to_hash" do
        o = Object.new
        o.expects(:to_hash).returns({ 'version' => '1.0', 'short_message' => 'message' })
        hash = @notifier.__send__(:extract_hash, o)
        assert_equal '1.0', hash['version']
        assert_equal 'message', hash['short_message']
      end

      should "work with exception with backtrace" do
        e = RuntimeError.new('message')
        e.set_backtrace(caller)
        hash = @notifier.__send__(:extract_hash, e)
        assert_equal 'RuntimeError: message', hash['short_message']
        assert_equal 'RuntimeError', hash['error_class']
        assert_equal 'message', hash['error_message']
        assert_match /shoulda/, hash['file']
        assert       hash['line'] > 300  # 382 in shoulda 2.11.3
        assert_match /Backtrace/, hash['full_message']
        assert_equal SyslogSD::ERROR, hash['level']
      end

      should "work with exception without backtrace" do
        e = RuntimeError.new('message')
        hash, line = @notifier.__send__(:extract_hash, e), __LINE__
        assert_equal __FILE__, hash['file']
        assert_equal line, hash['line']
        assert_match /Backtrace is not available/, hash['full_message']
      end

      should "work with exception and hash" do
        e, h = RuntimeError.new('message'), {'param' => 1, 'level' => SyslogSD::FATAL, 'short_message' => 'will be hidden by exception'}
        hash, line = @notifier.__send__(:extract_hash, e, h), __LINE__
        assert_equal 'RuntimeError: message', hash['short_message']
        assert_equal 'RuntimeError', hash['error_class']
        assert_equal 'message', hash['error_message']
        assert_equal __FILE__, hash['file']
        assert_equal line, hash['line']
        assert_equal SyslogSD::FATAL, hash['level']
        assert_equal 1, hash['param']
      end

      should "work with plain text" do
        hash = @notifier.__send__(:extract_hash, 'message')
        assert_equal 'message', hash['short_message']
        assert_equal SyslogSD::INFO, hash['level']
      end

      should "work with plain text and hash" do
        hash = @notifier.__send__(:extract_hash, 'message', 'level' => SyslogSD::WARN)
        assert_equal 'message', hash['short_message']
        assert_equal SyslogSD::WARN, hash['level']
      end

      should "covert hash keys to strings" do
        hash = @notifier.__send__(:extract_hash, :short_message => :message)
        assert hash.has_key?('short_message')
        assert !hash.has_key?(:short_message)
      end

      should "not overwrite keys on convert" do
        assert_raise(ArgumentError) { @notifier.__send__(:extract_hash, :short_message => :message1, 'short_message' => 'message2') }
      end

      should "use default_options" do
        @notifier.default_options = {:foo => 'bar', 'short_message' => 'will be hidden by explicit argument', 'host' => 'some_host'}
        hash = @notifier.__send__(:extract_hash, { 'version' => '1.0', 'short_message' => 'message' })
        assert_equal 'bar', hash['foo']
        assert_equal 'message', hash['short_message']
      end

      should "be compatible with Airbrake" do
        # https://github.com/airbrake/airbrake/blob/master/README.md, section Going beyond exceptions
        hash = @notifier.__send__(:extract_hash, :error_class => 'Class', :error_message => 'Message')
        assert_equal 'Class: Message', hash['short_message']
        assert_equal 'Class',   hash['error_class']
        assert_equal 'Message', hash['error_message']
      end

      should "set file and line" do
        line = __LINE__
        hash = @notifier.__send__(:extract_hash, { 'version' => '1.0', 'short_message' => 'message' })
        assert_match /test_notifier.rb/, hash['file']
        assert_equal line + 1, hash['line']
      end

      should "set timestamp to current time if not set" do
        hash = @notifier.__send__(:extract_hash, { 'version' => '1.0', 'short_message' => 'message' })
        assert_instance_of Float, hash['timestamp']
        now = Time.now.utc.to_f
        assert ((now - 1)..(now + 1)).include?(hash['timestamp'])
      end

      should "set timestamp to specified time" do
        timestamp = 1319799449.13765
        hash = @notifier.__send__(:extract_hash, { 'version' => '1.0', 'short_message' => 'message', 'timestamp' => timestamp })
        assert_equal timestamp, hash['timestamp']
      end
    end

    context "serialize_hash" do
      setup do
        @notifier.level_mapping = :direct
        Timecop.freeze(Time.utc(2010, 5, 16, 12, 13, 14))
      end

      expected = {
        {'short_message' => 'message', 'level' => SyslogSD::WARN,
         'host' => 'host', 'facility' => 'facility', 'procid' => 123,
         'msgid' => 'msgid'} => '<132>1 2010-05-16T12:13:14.0Z host facility 123 msgid - message',
        {'short_message' => 'message', 'level' => SyslogSD::WARN,
         'host' => 'host', 'facility' => 'facility', 'procid' => 123,
         'msgid' => 'msgid', 'user_id' => 123} => '<132>1 2010-05-16T12:13:14.0Z host facility 123 msgid [_@37797 user_id="123"] message',
        {'short_message' => 'message', 'level' => SyslogSD::WARN,
         'host' => 'host', 'facility' => 'facility', 'procid' => 123,
         'msgid' => 'msgid', 'user_id' => '\\"]'} => '<132>1 2010-05-16T12:13:14.0Z host facility 123 msgid [_@37797 user_id="\\\\\"\]"] message'
      }

      expected.each_pair do |key, value|
        should "be as #{value}" do
          assert_equal value, @notifier.__send__(:serialize_hash, key)
        end
      end

      should "send timestamp as float if desired" do
        @notifier.timestamp_as_float = true
        hash = { 'short_message' => 'message', 'level' => SyslogSD::WARN, 'host' => 'host', 'facility' => 'facility', 'procid' => 123,
                 'msgid' => 'msgid', 'user_id' => 123 }
        expected = '<132>1 1274011994.0 host facility 123 msgid [_@37797 user_id="123"] message'
        assert_equal expected, @notifier.__send__(:serialize_hash, hash)
      end

      teardown do
        Timecop.return
      end
    end

    context "level threshold" do
      setup do
        @notifier.level = SyslogSD::WARN
        @hash = { 'version' => '1.0', 'short_message' => 'message' }
      end

      ['debug', 'DEBUG', :debug].each do |l|
        should "allow to set threshold as #{l.inspect}" do
          @notifier.level = l
          assert_equal SyslogSD::DEBUG, @notifier.level
        end
      end

      should "not send notifications with level below threshold" do
        @sender.expects(:send_datagram).never
        assert_nil @notifier.notify!(@hash.merge('level' => SyslogSD::DEBUG))
      end

      should "not notifications with level equal or above threshold" do
        @sender.expects(:send_datagram).once
        assert_kind_of String, @notifier.notify!(@hash.merge('level' => SyslogSD::WARN))
      end
    end

    context "when disabled" do
      setup do
        @notifier.disable
      end

      should "not send datagram" do
        @sender.expects(:send_datagram).never
        @notifier.expects(:extract_hash).never
        assert_nil @notifier.notify!({ 'version' => '1.0', 'short_message' => 'message' })
      end

      context "and enabled again" do
        setup do
          @notifier.enable
        end

        should "send datagram" do
          @sender.expects(:send_datagram)
          assert_kind_of String, @notifier.notify!({ 'version' => '1.0', 'short_message' => 'message' })
        end
      end
    end

    should "pass valid data to sender" do
      @sender.expects(:send_datagram).with do |datagram|
        datagram.is_a?(String)
      end
      assert_kind_of String, @notifier.notify!({ 'version' => '1.0', 'short_message' => 'message' })
    end

    SyslogSD::Levels.constants.each do |const|
      should "call notify with level #{const} from method name" do
        @notifier.expects(:notify_with_level).with(SyslogSD.const_get(const), { 'version' => '1.0', 'short_message' => 'message' })
        @notifier.__send__(const.downcase, { 'version' => '1.0', 'short_message' => 'message' })
      end
    end

    should "not rescue from invalid invocation of #notify!" do
      assert_raise(ArgumentError) { @notifier.notify!(:no_short_message => 'too bad') }
    end

    should "rescue from invalid invocation of #notify" do
      @notifier.expects(:notify_with_level!).with(nil, instance_of(Hash)).raises(ArgumentError)
      @notifier.expects(:notify_with_level!).with(SyslogSD::UNKNOWN, instance_of(ArgumentError))
      assert_kind_of ArgumentError, @notifier.notify(:no_short_message => 'too bad')
    end
  end

  context "with notifier with real sender" do
    setup do
      @notifier = SyslogSD::Notifier.new('no_such_host_321')
    end

    should "raise exception" do
      assert_raise(SocketError) { @notifier.notify('Hello!') }
    end

    should "not raise exception if asked" do
      @notifier.rescue_network_errors = true
      assert_nothing_raised { @notifier.notify('Hello!') }
    end
  end
end
