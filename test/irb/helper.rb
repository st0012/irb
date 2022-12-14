# frozen_string_literal: true

require "pty" unless RUBY_ENGINE == 'truffleruby'

require "test/unit"
require "pathname"
require "tempfile"
require "tmpdir"
require "envutil"

begin
  require_relative "../lib/helper"
rescue LoadError # ruby/ruby defines helpers differently
end

module IRB
  class InputMethod; end
end

module TestIRB
  class TestCase < Test::Unit::TestCase
    class TestInputMethod < ::IRB::InputMethod
      attr_reader :list, :line_no

      def initialize(list = [])
        super("test")
        @line_no = 0
        @list = list
      end

      def gets
        @list[@line_no]&.tap {@line_no += 1}
      end

      def eof?
        @line_no >= @list.size
      end

      def encoding
        Encoding.default_external
      end

      def reset
        @line_no = 0
      end
    end

    def ruby_core?
      !Pathname(__dir__).join("../../", "irb.gemspec").exist?
    end

    def save_encodings
      @default_encoding = [Encoding.default_external, Encoding.default_internal]
      @stdio_encodings = [STDIN, STDOUT, STDERR].map {|io| [io.external_encoding, io.internal_encoding] }
    end

    def restore_encodings
      EnvUtil.suppress_warning do
        Encoding.default_external, Encoding.default_internal = *@default_encoding
        [STDIN, STDOUT, STDERR].zip(@stdio_encodings) do |io, encs|
          io.set_encoding(*encs)
        end
      end
    end

    def without_rdoc(&block)
      ::Kernel.send(:alias_method, :old_require, :require)

      ::Kernel.define_method(:require) do |name|
        raise LoadError, "cannot load such file -- rdoc (test)" if name.match?("rdoc") || name.match?(/^rdoc\/.*/)
        ::Kernel.send(:old_require, name)
      end

      yield
    ensure
      begin
        require_relative "../lib/envutil"
      rescue LoadError # ruby/ruby defines EnvUtil differently
      end
      EnvUtil.suppress_warning { ::Kernel.send(:alias_method, :require, :old_require) }
    end
  end

  class IntegrationTestCase < TestCase
    IRB_ENVS = { "NO_COLOR" => "true" }.freeze
    TIMEOUT_SEC = 3
    LIB = File.expand_path("../../lib", __dir__)

    def setup
      if ruby_core?
        omit "This test works only under ruby/irb"
      end

      if RUBY_ENGINE == 'truffleruby'
        omit "This test requires the `pty` library, which doesn't work with truffleruby"
      end

      @irb_envs = IRB_ENVS
    end

    private

    def run_ruby_file(&block)
      cmd = [EnvUtil.rubybin, "-I", LIB, @ruby_file.to_path]
      tmp_dir = Dir.mktmpdir
      rc_file = File.open(File.join(tmp_dir, ".irbrc"), "w+")
      rc_file.write("IRB.conf[:USE_SINGLELINE] = true")
      rc_file.close

      @commands = []
      lines = []

      yield

      PTY.spawn(@irb_envs.merge("IRBRC" => rc_file.to_path), *cmd) do |read, write, pid|
        Timeout.timeout(TIMEOUT_SEC) do
          while line = safe_gets(read)
            lines << line

            # means the breakpoint is triggered
            if line.match?(/binding\.irb/)
              while command = @commands.shift
                write.puts(command)
              end
            end
          end
        end
      ensure
        read.close
        write.close
        kill_safely(pid)
      end

      lines.join
    rescue Timeout::Error
      message = <<~MSG
      Test timedout.

      #{'=' * 30} OUTPUT #{'=' * 30}
        #{lines.map { |l| "  #{l}" }.join}
      #{'=' * 27} END OF OUTPUT #{'=' * 27}
      MSG
      assert_block(message) { false }
    ensure
      File.unlink(@ruby_file) if @ruby_file
      FileUtils.remove_entry tmp_dir
    end

    # read.gets could raise exceptions on some platforms
    # https://github.com/ruby/ruby/blob/master/ext/pty/pty.c#L729-L736
    def safe_gets(read)
      read.gets
    rescue Errno::EIO
      nil
    end

    def kill_safely pid
      return if wait_pid pid, TIMEOUT_SEC

      Process.kill :TERM, pid
      return if wait_pid pid, 0.2

      Process.kill :KILL, pid
      Process.waitpid(pid)
    rescue Errno::EPERM, Errno::ESRCH
    end

    def wait_pid pid, sec
      total_sec = 0.0
      wait_sec = 0.001 # 1ms

      while total_sec < sec
        if Process.waitpid(pid, Process::WNOHANG) == pid
          return true
        end
        sleep wait_sec
        total_sec += wait_sec
        wait_sec *= 2
      end

      false
    rescue Errno::ECHILD
      true
    end

    def type(command)
      @commands << command
    end

    def write_ruby(program)
      @ruby_file = Tempfile.create(%w{irb- .rb})
      @ruby_file.write(program)
      @ruby_file.close
    end
  end
end
