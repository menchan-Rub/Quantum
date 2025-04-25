# src/crystal/utils/logger.cr
require "colorize"
require "logger"

module QuantumUtils
  # カスタムロガー
  # ログレベル、タイムスタンプ、呼び出し元情報を付与
  class Logger < ::Logger
    def initialize(io : IO, level : Level = Level::Info, *, formatter : Formatter? = nil)
      super(io, level, formatter: formatter || default_formatter)
    end

    private def default_formatter
      ->(severity : Level, timestamp : Time, progname : String?, message : String) do
        level_str = severity.to_s.upcase
        level_color = case severity
                      when Level::Debug   then :cyan
                      when Level::Info    then :green
                      when Level::Warn    then :yellow
                      when Level::Error   then :red
                      when Level::Fatal   then :magenta
                      else :default
                      end

        "[#{timestamp.to_s("%Y-%m-%d %H:%M:%S.%L")}][#{level_str.colorize(level_color)}] #{message}\n"
      end
    end

    # 呼び出し元情報を含むログ出力
    macro log(level, message, exception = nil)
      if {{level}} >= @level
        caller_info = "#{__FILE__}:#{__LINE__}"
        formatted_message = "[#{caller_info}] #{{{message}}}"
        if ex = {{exception}}
          formatted_message += "\nException: #{ex.class.name} - #{ex.message}\n#{ex.backtrace.join("\n")}"
        end
        log({{level}}, Time.utc, nil, formatted_message)
      end
    end

    # ログレベルに応じたマクロ定義
    {% for level in %w(Debug Info Warn Error Fatal) %}
      macro {{level.id}}(message, exception = nil)
        log(Level::{{level.id}}, {{message}}, {{exception}})
      end
    {% end %}
  end

  # グローバルロガーインスタンス
  Log = Logger.new(STDOUT, level: Logger::Level::Debug)
end 