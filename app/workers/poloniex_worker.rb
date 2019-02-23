class PoloniexWorker
  require 'uri'
  require 'net/http'
  require 'net/https'
  require 'json'
  include Sidekiq::Worker

  def perform(group_id)
    # Do something
    begin
      group = Group.find(group_id)
      if group.poloniex_key.present? && group.poloniex_secret.present?
        if group.nounce.present?
            nounce = group.nounce+1
        else
            nounce = 0
        end
        group.update(nounce:nounce)
        private_key = group.poloniex_secret
        data = URI.encode_www_form({"command" => "returnBalances", "nonce" => nounce})
        digest = OpenSSL::Digest.new('sha512')
        signature = OpenSSL::HMAC.hexdigest(digest, private_key, data)
        uri = URI.parse('https://poloniex.com/tradingApi')
        https = Net::HTTP.new(uri.host,uri.port)
        https.use_ssl = true
        header = {"Sign": signature, "Key": group.poloniex_key, 
        'Content-Type': 'application/x-www-form-urlencoded'}
        req = https.post(uri.path, data, header)
        poloniex_resp = req.body
        if JSON.parse(poloniex_resp).has_key?("error")
          new_nounce = JSON.parse(poloniex_resp)["error"].split('.')[0].scan(/\d/).join('').to_i
          group.update(nounce: new_nounce)
          PoloniexWorker.perform_in(10.seconds, group_id)
        else
          btc_balance = JSON.parse(poloniex_resp, symbolize_names: true)[:BTC].to_f
          ltc_balance = JSON.parse(poloniex_resp, symbolize_names: true)[:LTC].to_f
          accu_btc = group.accubtc
          accu_ltc = group.accultc
          users = User.where(group_id: group_id, active: true)
          array = []
          total_btc_hash = 0
          total_ltc_hash = 0
          total_btc_payout = 0
          total_ltc_payout = 0
          if btc_balance > accu_btc
            btc_before = accu_btc
            btc_after = btc_balance
            total_btc_payout = (BigDecimal.new(btc_balance.to_s)-BigDecimal.new(accu_btc.to_s)).to_s.to_f
            group.update(accubtc: btc_balance)
          end
          if ltc_balance > accu_ltc
            ltc_before = accu_ltc
            ltc_after = ltc_balance
            total_ltc_payout = (BigDecimal.new(ltc_balance.to_s)-BigDecimal.new(accu_ltc.to_s)).to_s.to_f
            group.update(accultc: ltc_balance)
          end
          users.each do |t|
            ltc_hash = 0
            btc_hash = 0
            t.miners.each do |a|
              if a.algorithm == "Scrypt"
                if ltc_balance > accu_ltc
                  ltc_hash = BigDecimal.new(ltc_hash.to_s)+BigDecimal.new(a.accuhash.to_s)
                  prevhash = a.accuhash
                  a.update(accuhash: 0, prevhash: prevhash)
                end
              elsif a.algorithm == "SHA256"
                if btc_balance > accu_btc
                  btc_hash = BigDecimal.new(btc_hash.to_s)+BigDecimal.new(a.accuhash.to_s)
                  prevhash = a.accuhash
                  a.update(accuhash: 0, prevhash: prevhash)
                end
              end
            end
            total_ltc_hash = (BigDecimal.new(total_ltc_hash.to_s)+BigDecimal.new(ltc_hash.to_s)).to_s.to_f
            total_btc_hash = (BigDecimal.new(total_btc_hash.to_s)+BigDecimal.new(btc_hash.to_s)).to_s.to_f
            array.push({user: t.id, ltc_hash: ltc_hash, btc_hash: btc_hash})
          end
          payouts = []
          array.each do |t|
            user = User.find(t[:user])
            if user.user_balance.present?
              usr_cur_btc = user.user_balance.cur_btc
              usr_cur_ltc = user.user_balance.cur_ltc
            else
              usr_cur_btc = 0
              usr_cur_ltc = 0
            end
            if user.percent_fee.present?
              percent_fee = user.percent_fee.to_i/100
            else
              percent_fee = 0
            end
            user_btc_hash = (BigDecimal.new(t[:btc_hash].to_s)-BigDecimal.new(t[:btc_hash].to_s)*percent_fee).to_s.to_f
            user_ltc_hash = (BigDecimal.new(t[:ltc_hash].to_s)-BigDecimal.new(t[:ltc_hash].to_s)*percent_fee).to_s.to_f
            new_btc = usr_cur_btc
            new_ltc = usr_cur_ltc
            if btc_balance > accu_btc && total_btc_hash > 0
              btc_amount = BigDecimal.new(((BigDecimal.new(btc_balance.to_s)-BigDecimal.new(accu_btc.to_s))*user_btc_hash/total_btc_hash).to_s).floor(6)
              new_btc = BigDecimal.new(usr_cur_btc.to_s)+BigDecimal(btc_amount.to_s)
              btc_payout = btc_amount.to_s.to_f
            end
            if ltc_balance > accu_ltc && total_ltc_hash > 0
              ltc_amount = BigDecimal.new(((BigDecimal.new(ltc_balance.to_s)-BigDecimal.new(accu_ltc.to_s))*user_ltc_hash/total_ltc_hash).to_s).floor(6)
              new_ltc = BigDecimal.new(usr_cur_ltc.to_s)+BigDecimal(ltc_amount.to_s)
              ltc_payout = ltc_amount.to_s.to_f
            end
            if user.user_balance.present?
              user.user_balance.update(cur_ltc: new_ltc.to_s.to_f, cur_btc: new_btc.to_s.to_f)
            else
              UserBalance.create(cur_ltc: new_ltc.to_s.to_f, cur_btc: new_btc.to_s.to_f, user_id: user.id)
            end
            payouts.push({user: user.id, btc_payout: btc_payout, ltc_payout: ltc_payout, btc_hash: user_btc_hash, ltc_hash: user_ltc_hash})
          end
          if total_ltc_payout > 0 || total_btc_payout > 0
            GroupPayoutHistory.create(group_id: group.id, btc_before: btc_before, btc_after: btc_after, btc_total_payout: total_btc_payout, ltc_before: ltc_before, ltc_after: ltc_after, ltc_total_payout: total_ltc_payout, total_btc_hash: total_btc_hash, total_ltc_hash: total_ltc_hash, payouts: payouts)
          end
          PoloniexWorker.perform_in(5.minutes, group_id)
        end
      end
    rescue => error
      logger.info 'Error happened in Poloniex background job and the proccess restarted.'
      PoloniexWorker.perform_in(30.seconds, group_id)
      puts error
      puts error.backtrace
    end
  end

end
