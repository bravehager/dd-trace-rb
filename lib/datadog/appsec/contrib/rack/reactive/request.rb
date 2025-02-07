# frozen_string_literal: true

module Datadog
  module AppSec
    module Contrib
      module Rack
        module Reactive
          # Dispatch data from a Rack request to the WAF context
          module Request
            ADDRESSES = [
              'request.headers',
              'request.uri.raw',
              'request.query',
              'request.cookies',
              'request.client_ip',
              'server.request.method'
            ].freeze
            private_constant :ADDRESSES

            def self.publish(op, gateway_request)
              catch(:block) do
                op.publish('request.query', gateway_request.query)
                op.publish('request.headers', gateway_request.headers)
                op.publish('request.uri.raw', gateway_request.fullpath)
                op.publish('request.cookies', gateway_request.cookies)
                op.publish('request.client_ip', gateway_request.client_ip)
                op.publish('server.request.method', gateway_request.method)

                nil
              end
            end

            # rubocop:disable Metrics/MethodLength
            def self.subscribe(op, waf_context)
              op.subscribe(*ADDRESSES) do |*values|
                Datadog.logger.debug { "reacted to #{ADDRESSES.inspect}: #{values.inspect}" }
                headers = values[0]
                headers_no_cookies = headers.dup.tap { |h| h.delete('cookie') }
                uri_raw = values[1]
                query = values[2]
                cookies = values[3]
                client_ip = values[4]
                request_method = values[5]

                waf_args = {
                  'server.request.cookies' => cookies,
                  'server.request.query' => query,
                  'server.request.uri.raw' => uri_raw,
                  'server.request.headers' => headers,
                  'server.request.headers.no_cookies' => headers_no_cookies,
                  'http.client_ip' => client_ip,
                  'server.request.method' => request_method,
                }

                waf_timeout = Datadog::AppSec.settings.waf_timeout
                result = waf_context.run(waf_args, waf_timeout)

                Datadog.logger.debug { "WAF TIMEOUT: #{result.inspect}" } if result.timeout

                case result.status
                when :match
                  Datadog.logger.debug { "WAF: #{result.inspect}" }

                  block = result.actions.include?('block')

                  yield [result, block]

                  throw(:block, [result, true]) if block
                when :ok
                  Datadog.logger.debug { "WAF OK: #{result.inspect}" }
                when :invalid_call
                  Datadog.logger.debug { "WAF CALL ERROR: #{result.inspect}" }
                when :invalid_rule, :invalid_flow, :no_rule
                  Datadog.logger.debug { "WAF RULE ERROR: #{result.inspect}" }
                else
                  Datadog.logger.debug { "WAF UNKNOWN: #{result.status.inspect} #{result.inspect}" }
                end
              end
              # rubocop:enable Metrics/MethodLength
            end
          end
        end
      end
    end
  end
end
