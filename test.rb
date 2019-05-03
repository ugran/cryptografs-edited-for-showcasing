require 'net/http'
require 'JSON'

uri = URI.parse("https://slushpool.com/accounts/profile/json/btc/")
req = Net::HTTP::Get.new(uri)
req['SlushPool-Auth-Token'] = 'uhtCfPqlXCs7zpkt'

res = Net::HTTP.start(uri.hostname, uri.port, {use_ssl: true}) {|http|
    http.request(req)
}
btc = JSON.parse(res.body, :symbolize_names => true)[:btc]

puts btc