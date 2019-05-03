class SlushpoolWorker
  include Sidekiq::Worker

  def perform(group_id)
    slush_api = Group.find(group_id).slushpool_api_key
    uri = URI.parse("https://slushpool.com/accounts/profile/json/btc/")
    req = Net::HTTP::Get.new(uri)
    req['SlushPool-Auth-Token'] = slush_api

    res = Net::HTTP.start(uri.hostname, uri.port, {use_ssl: true}) {|http|
        http.request(req)
    }
    btc = JSON.parse(res.body, :symbolize_names => true)[:btc]
    total_hashrate = (btc[:hash_rate_scoring].to_f/1000).round(2)
    confirmed_reward = btc[:confirmed_reward].to_f.round(6)
    unconfirmed_reward = btc[:unconfirmed_reward].to_f.round(6)
    estimated_reward = btc[:estimated_reward].to_f.round(6)
    #btc_workers = btc[:workers]
    Slushpoolstat.find_or_create_by(group_id: group_id).update(
      total_hashrate: total_hashrate,
      confirmed_reward: confirmed_reward,
      unconfirmed_reward: unconfirmed_reward,
      estimated_reward: estimated_reward,
      #hashrate_distribution: btc_workers.to_json
    )
    SlushpoolWorker.perform_in(15.seconds, group_id)
  end
end
