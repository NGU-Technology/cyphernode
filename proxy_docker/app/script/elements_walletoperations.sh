#!/bin/sh

. ./trace.sh
. ./sendtoelementsnode.sh

elements_listunspent() {
  trace "Entering elements_listunspent()..."

  local request=${1}
  local minconf=$(echo "${request}" | jq -r ".minconf // 0")
  trace "[elements_listunspent] minconf=${minconf}"
  local maxconf=$(echo "${request}" | jq -r ".maxconf // null")
  trace "[elements_listunspent] maxconf=${maxconf}"
  local addresses=$(echo "${request}" | jq -r ".addresses // []")
  trace "[elements_listunspent] addresses=${addresses}"

  local minamount=$(echo "${request}" | jq -r ".minamount // 0")
  trace "[elements_listunspent] minamount=${minamount}"
  local maxamount=$(echo "${request}" | jq -r ".maxamount // 9999999")
  trace "[elements_listunspent] maxamount=${maxamount}"
  local maxcount=$(echo "${request}" | jq -r ".maxcount // 9999999")
  trace "[elements_listunspent] maxcount=${maxcount}"
  local asset=$(echo "${request}" | jq -r ".asset // ''")
  trace "[elements_listunspent] asset=${asset}"

  local data='{"method":"listunspent","params":['${minconf}','${maxconf}','${addresses}',false,{"minimumAmount":'${minamount}',"maximumAmount":'${maxamount}',"maximumCount":'${maxcount}',"asset":"'"${asset}"'"}]}'

  local response
  response=$(send_to_elements_spender_node "${data}")

  local returncode=$?
  trace_rc ${returncode}
  trace "[elements_listunspent] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    local utxos=$(echo ${response} | jq -rc ".result")
    trace "[elements_listunspent] utxos=${utxos}"

    data="{\"utxos\":${utxos}}"
  else
    trace "[elements_listunspent] Couldn't get utxos!"
    data=""
  fi

  trace "[elements_listunspent] responding=${data}"
  echo "${data}"

  return ${returncode}
}

elements_spend() {
  trace "Entering elements_spend()..."

  local data
  local request=${1}
  local address=$(echo "${request}" | jq -r ".address")
  trace "[elements_spend] address=${address}"
  local assetid=$(echo "${request}" | jq -r ".assetId")
  trace "[elements_spend] assetId=${assetid}"
  local amount=$(echo "${request}" | jq -r ".amount" | awk '{ printf "%.8f", $0 }')
  trace "[elements_spend] amount=${amount}"
  local conf_target=$(echo "${request}" | jq ".confTarget")
  trace "[elements_spend] confTarget=${conf_target}"
  local replaceable=$(echo "${request}" | jq ".replaceable")
  trace "[elements_spend] replaceable=${replaceable}"
  local subtractfeefromamount=$(echo "${request}" | jq ".subtractfeefromamount")
  trace "[elements_spend] subtractfeefromamount=${subtractfeefromamount}"
  local response
  local id_inserted
  local tx_details
  local tx_raw_details
  local returncode

  if [ "${assetid}" = "null" ]; then
    response=$(send_to_elements_spender_node "{\"method\":\"sendtoaddress\",\"params\":[\"${address}\",${amount},\"\",\"\",${subtractfeefromamount},${replaceable},${conf_target}]}")
  else
    response=$(send_to_elements_spender_node "{\"method\":\"sendtoaddress\",\"params\":[\"${address}\",${amount},\"\",\"\",${subtractfeefromamount},${replaceable},${conf_target},\"UNSET\",null,\"${assetid}\"]}")
  fi

  returncode=$?
  trace_rc ${returncode}
  trace "[elements_spend] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    local txid=$(echo "${response}" | jq -r ".result")
    trace "[elements_spend] txid=${txid}"

    # Let's get transaction details on the spending wallet so that we have fee information
    tx_details=$(elements_get_transaction "${txid}" "spender")
    tx_raw_details=$(elements_get_rawtransaction "${txid}" | tr -d '\n')

    # Amounts and fees are negative when spending so we absolute those fields
    local tx_hash=$(echo "${tx_raw_details}" | jq -r '.result.hash')
    local tx_ts_firstseen=$(echo "${tx_details}" | jq '.result.timereceived')
    local tx_amount=$(echo "${tx_details}" | jq '.result.details[0].amount | fabs' | awk '{ printf "%.8f", $0 }')
    local tx_size=$(echo "${tx_raw_details}" | jq '.result.size')
    local tx_vsize=$(echo "${tx_raw_details}" | jq '.result.vsize')
    local tx_replaceable=$(echo "${tx_details}" | jq -r '.result."bip125-replaceable"')
    tx_replaceable=$([ ${tx_replaceable} = "yes" ] && echo "true" || echo "false")
    local fees=$(echo "${tx_details}" | jq '.result.details[0].fee | fabs' | awk '{ printf "%.8f", $0 }')

    # We need to get the corresponding unblinded address to work around the elements gettransaction bug with blinded addresses
    local unblinded_address=$(elements_getaddressinfo "${address}" true | jq -r ".result.unconfidential")
    trace "[elements_spend] unblinded_address=${unblinded_address}"

    ########################################################################################################
    # Let's publish the event if needed
    local event_message
    event_message=$(echo "${request}" | jq -er ".eventMessage")
    if [ "$?" -ne "0" ]; then
      # event_message tag null, so there's no event_message
      trace "[elements_spend] event_message="
      event_message=
    else
      # There's an event message, let's publish it!

      if [ "${assetid}" = "null" ]; then
        trace "[elements_spend] mosquitto_pub -h broker -t elements_spend -m \"{\"txid\":\"${txid}\",\"address\":\"${address}\",\"unblinded_address\":\"${unblinded_address}\",\"amount\":${tx_amount},\"eventMessage\":\"${event_message}\"}\""
        response=$(mosquitto_pub -h broker -t elements_spend -m "{\"txid\":\"${txid}\",\"address\":\"${address}\",\"unblinded_address\":\"${unblinded_address}\",\"amount\":${tx_amount},\"eventMessage\":\"${event_message}\"}")
      else
        trace "[elements_spend] mosquitto_pub -h broker -t elements_spend -m \"{\"txid\":\"${txid}\",\"address\":\"${address}\",\"unblinded_address\":\"${unblinded_address}\",\"amount\":${tx_amount},\"assetId\":\"${assetid}\",\"eventMessage\":\"${event_message}\"}\""
        response=$(mosquitto_pub -h broker -t elements_spend -m "{\"txid\":\"${txid}\",\"address\":\"${address}\",\"unblinded_address\":\"${unblinded_address}\",\"amount\":${tx_amount},\"assetId\":\"${assetid}\",\"eventMessage\":\"${event_message}\"}")
      fi
      returncode=$?
      trace_rc ${returncode}
    fi
    ########################################################################################################

    # Let's insert the txid in our little DB -- then we'll already have it when receiving confirmation
    id_inserted=$(sql "INSERT INTO elements_tx (txid, hash, confirmations, timereceived, fee, size, vsize, is_replaceable)"\
" VALUES ('${txid}', '${tx_hash}', 0, ${tx_ts_firstseen}, ${fees}, ${tx_size}, ${tx_vsize}, ${tx_replaceable})"\
" RETURNING id" \
    "SELECT id FROM elements_tx WHERE txid='${txid}'")
    trace_rc $?
    sql "INSERT INTO elements_recipient (address, unblinded_address, amount, elements_tx_id, assetid) VALUES ('${address}', '${unblinded_address}', ${amount}, ${id_inserted}, '${assetid}')"\
" ON CONFLICT DO NOTHING"
    trace_rc $?

    data="{\"status\":\"accepted\""
    data="${data},\"txid\":\"${txid}\",\"hash\":\"${tx_hash}\",\"details\":{\"address\":\"${address}\",\"unblindedAddress\":\"${unblinded_address}\",\"amount\":${amount},\"assetId\":\"${assetid}\",\"firstseen\":${tx_ts_firstseen},\"size\":${tx_size},\"vsize\":${tx_vsize},\"replaceable\":${tx_replaceable},\"fee\":${fees},\"subtractfeefromamount\":${subtractfeefromamount}}}"
  else
    local message=$(echo "${response}" | jq -e ".error.message")
    data="{\"message\":${message}}"
  fi

  trace "[elements_spend] responding=${data}"
  echo "${data}"

  return ${returncode}
}

elements_sendmany() {
  trace "Entering elements_sendmany()..."

  local data
  local request=${1}
  local amounts=$(echo "${request}" | jq -r ".amounts")
  trace "[elements_sendmany] amounts=${amounts}"
  local conf_target=$(echo "${request}" | jq ".confTarget")
  trace "[elements_sendmany] confTarget=${conf_target}"
  local replaceable=$(echo "${request}" | jq ".replaceable")
  trace "[elements_sendmany] replaceable=${replaceable}"
  local fee_rate=$(echo "${request}" | jq ".feeRate")
  local output_assets=$(echo "${request}" | jq -r ".outputAssets")
  local response

  local id_inserted
  local tx_details
  local tx_raw_details

  response=$(send_to_elements_spender_node "{\"method\":\"sendmany\",\"params\":[\"\", ${amounts},6,\"\",[],${replaceable},${conf_target},\"unset\",${output_assets},true,${fee_rate}]}")
  local returncode=$?
  trace_rc ${returncode}
  trace "[elements_sendmany] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    local txid=$(echo "${response}" | jq -r ".result")
    trace "[elements_sendmany] txid=${txid}"

    # Let's get transaction details on the spending wallet so that we have fee information
    tx_details=$(elements_get_transaction "${txid}" "spender")
    tx_raw_details=$(elements_get_rawtransaction "${txid}" | tr -d '\n')

    # Amounts and fees are negative when spending so we absolute those fields
    local tx_hash=$(echo "${tx_raw_details}" | jq -r '.result.hash')
    local tx_ts_firstseen=$(echo "${tx_details}" | jq '.result.timereceived')
    # @todo might need to handle other assetIds here
    local tx_amount=$(echo "${tx_details}" | jq '.result.amount.bitcoin | fabs' | awk '{ printf "%.8f", $0 }')
    local tx_size=$(echo "${tx_raw_details}" | jq '.result.size')
    local tx_vsize=$(echo "${tx_raw_details}" | jq '.result.vsize')
    local tx_replaceable=$(echo "${tx_details}" | jq -r '.result."bip125-replaceable"')
    tx_replaceable=$([ ${tx_replaceable} = "yes" ] && echo "true" || echo "false")
    local fees=$(echo "${tx_details}" | jq '.result.fee.bitcoin | fabs' | awk '{ printf "%.8f", $0 }')

    ########################################################################################################
    # Let's publish the event if needed
    local event_message
    event_message=$(echo "${request}" | jq -er ".eventMessage")
    if [ "$?" -ne "0" ]; then
      # event_message tag null, so there's no event_message
      trace "[elements_sendmany] event_message="
      event_message=
    else
      # There's an event message, let's publish it!

      trace "[elements_sendmany] mosquitto_pub -h broker -t elements_sendmany -m \"{\"txid\":\"${txid}\",\"amounts\":${amounts},\"tx_amount\":${tx_amount},\"fees\":\"${fees}\",\"eventMessage\":\"${event_message}\"}\""
      response=$(mosquitto_pub -h broker -t elements_sendmany -m "{\"txid\":\"${txid}\",\"amounts\":${amounts},\"tx_amount\":${tx_amount},\"fees\":\"${fees}\",\"eventMessage\":\"${event_message}\"}")
      returncode=$?
      trace_rc ${returncode}
    fi
    ########################################################################################################

    # Let's insert the txid in our little DB -- then we'll already have it when receiving confirmation
    id_inserted=$(sql "INSERT INTO elements_tx (txid, hash, confirmations, timereceived, fee, size, vsize, is_replaceable, conf_target)"\
" VALUES ('${txid}', '${tx_hash}', 0, ${tx_ts_firstseen}, ${fees}, ${tx_size}, ${tx_vsize}, ${tx_replaceable}, ${conf_target})"\
" RETURNING id" \
    "SELECT id FROM elements_tx WHERE txid='${txid}'")
    trace_rc $?

    echo "${amounts}" | jq -r 'to_entries[] | "\(.key) \(.value)"' | while read -r address amount; do
      sql "INSERT INTO elements_recipient (address, amount, tx_id) VALUES ('${address}', ${amount}, ${id_inserted})"\
" ON CONFLICT DO NOTHING"
      trace_rc $?
    done

    data="{\"status\":\"accepted\""
    data="${data},\"txid\":\"${txid}\",\"hash\":\"${tx_hash}\",\"details\":{\"amounts\":${amounts},\"tx_amount\":${tx_amount},\"firstseen\":${tx_ts_firstseen},\"size\":${tx_size},\"vsize\":${tx_vsize},\"replaceable\":${tx_replaceable},\"fee\":${fees}}}"
  else
    local message=$(echo "${response}" | jq -e ".error.message")
    if [ -n "${message}" ]; then
      data="{\"message\":${message}}"
    else
      data="{\"message\":null}"
    fi
  fi

  trace "[elements_sendmany] responding=${data}"
  echo "${data}"

  return ${returncode}
}

elements_bumpfee() {
  trace "Entering elements_bumpfee()..."

  local request=${1}
  local txid=$(echo "${request}" | jq -r ".txid")
  trace "[elements_bumpfee] txid=${txid}"

  local confTarget
  local response
  local returncode

  # jq -e will have a return code of 1 if the supplied tag is null.
  confTarget=$(echo "${request}" | jq -e ".confTarget")
  if [ "$?" -ne "0" ]; then
    # confTarget tag null, so there's no confTarget
    trace "[elements_bumpfee] confTarget="
    response=$(send_to_elements_spender_node "{\"method\":\"bumpfee\",\"params\":[\"${txid}\"]}")
    returncode=$?
  else
    trace "[elements_bumpfee] confTarget=${confTarget}"
    response=$(send_to_elements_spender_node "{\"method\":\"bumpfee\",\"params\":[\"${txid}\",{\"confTarget\":${confTarget}}]}")
    returncode=$?
  fi

  trace_rc ${returncode}
  trace "[elements_bumpfee] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    trace "[elements_bumpfee] error!"
  else
    trace "[elements_bumpfee] success!"
  fi

  echo "${response}"

  return ${returncode}
}

elements_get_txns_spending() {
  trace "Entering elements_get_txns_spending()... with count: $1 , skip: $2"
  local count="$1"
  local skip="$2"
  local response
  local data="{\"method\":\"listtransactions\",\"params\":[\"*\",${count:-10},${skip:-0}]}"
  response=$(send_to_elements_spender_node "${data}")
  local returncode=$?
  trace_rc ${returncode}
  trace "[elements_get_txns_spending] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    local txns=$(echo ${response} | jq -rc ".result")
    trace "[elements_get_txns_spending] txns=${txns}"

    data="{\"txns\":${txns}}"
  else
    trace "[elements_get_txns_spending] Coudn't get txns!"
    data=""
  fi

  trace "[elements_get_txns_spending] responding=${data}"
  echo "${data}"

  return ${returncode}
}

elements_getbalance() {
  trace "Entering elements_getbalance()..."

  local response
  local data='{"method":"getbalance"}'
  response=$(send_to_elements_spender_node "${data}")
  local returncode=$?
  trace_rc ${returncode}
  trace "[elements_getbalance] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    local balance=$(echo ${response} | jq ".result")
    trace "[elements_getbalance] balance=${balance}"

    data="{\"balance\":${balance}}"
  else
    trace "[elements_getbalance] Coudn't get balance!"
    data=""
  fi

  trace "[elements_getbalance] responding=${data}"
  echo "${data}"

  return ${returncode}
}

elements_getbalances() {
  trace "Entering elements_getbalances()..."

  local response
  local data='{"method":"getbalances"}'
  response=$(send_to_elements_spender_node "${data}")
  local returncode=$?
  trace_rc ${returncode}
  trace "[elements_getbalances] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    local balances=$(echo "${response}" | jq ".result")
    trace "[elements_getbalances] balances=${balances}"

    data="{\"balances\":${balances}}"
  else
    trace "[elements_getbalances] Couldn't get balances!"
    data=""
  fi

  trace "[elements_getbalances] responding=${data}"
  echo "${data}"

  return ${returncode}
}

elements_getbalancebyxpublabel() {
  trace "Entering elements_getbalancebyxpublabel()..."

  local label=${1}
  trace "[elements_getbalancebyxpublabel] label=${label}"
  local xpub

  xpub=$(sql "SELECT pub32 FROM elements_watching_by_pub32 WHERE label='${label}'")
  trace "[elements_getbalancebyxpublabel] xpub=${xpub}"

  elements_getbalancebyxpub "${xpub}" "elements_getbalancebyxpublabel"
  returncode=$?

  return ${returncode}
}

elements_getbalancebyxpub() {
  trace "Entering elements_getbalancebyxpub()..."

  # ./bitcoin-cli -rpcwallet=xpubwatching01.dat listunspent 0 9999999 "$(./bitcoin-cli -rpcwallet=xpubwatching01.dat getaddressesbylabel upub5GtUcgGed1aGH4HKQ3vMYrsmLXwmHhS1AeX33ZvDgZiyvkGhNTvGd2TA5Lr4v239Fzjj4ZY48t6wTtXUy2yRgapf37QHgt6KWEZ6bgsCLpb | jq "keys" | tr -d '\n ')" | jq "[.[].amount] | add"

  local xpub=${1}
  trace "[elements_getbalancebyxpub] xpub=${xpub}"

  # If called from getbalancebyxpublabel, set the correct event for response
  local event=${2:-"elements_getbalancebyxpub"}
  trace "[elements_getbalancebyxpub] event=${event}"
  local addresses
  local balance
  local data
  local returncode

  # addresses=$(./elements-cli -rpcwallet=xpubwatching01.dat getaddressesbylabel upub5GtUcgGed1aGH4HKQ3vMYrsmLXwmHhS1AeX33ZvDgZiyvkGhNTvGd2TA5Lr4v239Fzjj4ZY48t6wTtXUy2yRgapf37QHgt6KWEZ6bgsCLpb | jq "keys" | tr -d '\n ')
  data="{\"method\":\"getaddressesbylabel\",\"params\":[\"${xpub}\"]}"
  trace "[elements_getbalancebyxpub] data=${data}"
  addresses=$(send_to_xpub_elements_watcher_wallet "${data}" | jq ".result | keys" | tr -d '\n ')
  # ./elements-cli -rpcwallet=xpubwatching01.dat listunspent 0 9999999 "$addresses" | jq "[.[].amount] | add"
  data="{\"method\":\"listunspent\",\"params\":[0,9999999,${addresses}]}"
  trace "[elements_getbalancebyxpub] data=${data}"
  balance=$(send_to_xpub_elements_watcher_wallet "${data}" | jq "[.result[].amount // 0 ] | add | . * 100000000 | trunc | . / 100000000")
  returncode=$?
  trace_rc ${returncode}
  trace "[elements_getbalancebyxpub] balance=${balance}"

  data="{\"event\":\"${event}\",\"xpub\":\"${xpub}\",\"balance\":${balance:-0}}"

  echo "${data}"

  return "${returncode}"
}

elements_getnewaddress() {
  trace "Entering elements_getnewaddress()..."

  local address_type=${1}
  trace "[elements_getnewaddress] address_type=${address_type}"

  local label=${2}
  trace "[elements_getnewaddress] label=${label}"

  local response
  local jqop
  local addedfieldstoresponse
  local data='{"method":"getnewaddress"}'
  if [ -n "${address_type}" ] || [ -n "${label}" ]; then
    jqop='. += {"params":{}}'
    if [ -n "${label}" ]; then
      jqop=${jqop}' | .params += {"label":"'${label}'"}'
      addedfieldstoresponse=' | . += {"label":"'${label}'"}'
    fi
    if [ -n "${address_type}" ]; then
      jqop=${jqop}' | .params += {"address_type":"'${address_type}'"}'
      addedfieldstoresponse=' | . += {"address_type":"'${address_type}'"}'
    fi
    trace "[elements_getnewaddress] jqop=${jqop}"
    trace "[elements_getnewaddress] addedfieldstoresponse=${addedfieldstoresponse}"

    data=$(echo "${data}" | jq -rc "${jqop}")
  fi
  trace "[elements_getnewaddress] data=${data}"

  response=$(send_to_elements_spender_node "${data}")
  local returncode=$?
  trace_rc ${returncode}
  trace "[elements_getnewaddress] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    local address=$(echo ${response} | jq ".result")
    trace "[elements_getnewaddress] address=${address}"

    data='{"address":'${address}'}'
    if [ -n "${jqop}" ]; then
      data=$(echo "${data}" | jq -rc ".${addedfieldstoresponse}")
      trace "[elements_getnewaddress] data=${data}"
    fi
  else
    trace "[elements_getnewaddress] Coudn't get a new address!"
    data=""
  fi

  trace "[elements_getnewaddress] responding=${data}"
  echo "${data}"

  return ${returncode}
}

elements_lockunspent() {
  trace "Entering elements_lockunspent()..."

  local request=${1}
  local unlock=$(echo "${request}" | jq -r ".unlock // false")
  local utxos=$(echo "${request}" | jq -r ".utxos")
  local data='{"method":"lockunspent","params":['${unlock}','${utxos}']}'

  local response
  response=$(send_to_elements_spender_node "${data}")
  local returncode=$?

  trace_rc ${returncode}
  trace "[elements_lockunspent] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    local success=$(echo ${response} | jq ".result")
    trace "[elements_lockunspent] success=${success}"

    data="{\"success\":${success}}"
  else
    trace "[elements_lockunspent] Couldn't lock/unlock unspent!"
    local message=$(echo "${response}" | jq -e ".error.message")
    if [ -n "${message}" ]; then
      data="{\"message\":${message}}"
    else
      data="{\"message\":null}"
    fi
  fi

  trace "[elements_lockunspent] responding=${data}"
  echo "${data}"

  return ${returncode}
}

elements_listlockunspent() {
  trace "Entering elements_listlockunspent()..."

  local data='{"method":"listlockunspent"}'

  local response
  response=$(send_to_elements_spender_node "${data}")

  local returncode=$?
  trace_rc ${returncode}
  trace "[elements_listlockunspent] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    local locked_utxos=$(echo ${response} | jq ".result")
    trace "[elements_listlockunspent] locked_utxos=${locked_utxos}"

    data="{\"locked_utxos\":${locked_utxos}}"
  else
    trace "[elements_listlockunspent] Couldn't list locked unspent!"
    local message=$(echo "${response}" | jq -e ".error.message")
    if [ -n "${message}" ]; then
      data="{\"message\":${message}}"
    else
      data="{\"message\":null}"
    fi
  fi

  trace "[elements_listlockunspent] responding=${data}"
  echo "${data}"

  return ${returncode}
}

elements_create_wallet() {
  trace "[Entering elements_create_wallet()]"

  local walletname=${1}

  local rpcstring="{\"method\":\"createwallet\",\"params\":[\"${walletname}\",true]}"
  trace "[elements_create_wallet] rpcstring=${rpcstring}"

  local result
  result=$(send_to_elements_watcher_node "${rpcstring}")
  local returncode=$?

  echo "${result}"

  return ${returncode}
}

elements_getwalletinfo() {
  trace "Entering elements_getwalletinfo()..."

  local data='{"method":"getwalletinfo"}'
  send_to_elements_spender_node "${data}" | jq ".result"
  return $?
}

elements_createrawtransaction() {
  trace "Entering elements_createrawtransaction()..."

  local request=${1}
  local inputs=$(echo "${request}" | jq -r ".inputs")
  trace "[elements_createrawtransaction] inputs=${inputs}"
  local outputs=$(echo "${request}" | jq -r ".outputs")
  trace "[elements_createrawtransaction] outputs=${outputs}"
  local locktime=$(echo "${request}" | jq -r ".locktime // null")
  trace "[elements_createrawtransaction] locktime=${locktime}"
  local replaceable=$(echo "${request}" | jq -r ".replaceable // true")

  local response

  local data='{"method":"createrawtransaction","params":['${inputs}','${outputs}','${locktime}','${replaceable}']}'

  response=$(send_to_elements_spender_node "${data}")

  local returncode=$?
  trace_rc ${returncode}
  trace "[elements_createrawtransaction] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    local rawtx=$(echo ${response} | jq -rc ".result")
    trace "[elements_createrawtransaction] rawtx=${rawtx}"

    data="{\"hex\":\"${rawtx}\"}"
  else
    trace "[elements_createrawtransaction] Couldn't get rawtx!"
    local message=$(echo "${response}" | jq -e ".error.message")
    if [ -n "${message}" ]; then
      data="{\"message\":${message}}"
    else
      data="{\"message\":null}"
    fi
  fi

  trace "[elements_createrawtransaction] responding=${data}"
  echo "${data}"

  return ${returncode}
}

elements_decoderawtransaction() {
  trace "Entering elements_decoderawtransaction()..."

  local request=${1}
  local rawtx=$(echo "${request}" | jq -r ".hex")
  trace "[elements_decoderawtransaction] rawtx=${rawtx}"

  local response

  local data='{"method":"decoderawtransaction","params":["'${rawtx}'"]}'

  response=$(send_to_elements_spender_node "${data}")

  local returncode=$?
  trace_rc ${returncode}
  trace "[elements_decoderawtransaction] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    local tx=$(echo ${response} | jq -rc ".result")
    trace "[elements_decoderawtransaction] tx=${tx}"

    data="{\"tx\":${tx}}"
  else
    trace "[elements_decoderawtransaction] Couldn't decode tx!"
    local message=$(echo "${response}" | jq -e ".error.message")
    if [ -n "${message}" ]; then
      data="{\"message\":${message}}"
    else
      data="{\"message\":null}"
    fi
  fi

  trace "[elements_decoderawtransaction] responding=${data}"
  echo "${data}"

  return ${returncode}
}

elements_fundrawtransaction() {
  trace "Entering elements_fundrawtransaction()..."

  local request=${1}
  local rawtx=$(echo "${request}" | jq -r ".hex")
  trace "[elements_fundrawtransaction] rawtx=${rawtx}"
  local options=$(echo "${request}" | jq -r ".options")
  trace "[elements_fundrawtransaction] options=${options}"

  local response

  local data='{"method":"fundrawtransaction","params":["'${rawtx}'",'${options}']}'

  response=$(send_to_elements_spender_node "${data}")

  local returncode=$?
  trace_rc ${returncode}
  trace "[elements_fundrawtransaction] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    local data=$(echo ${response} | jq -rc ".result")
  else
    local message=$(echo "${response}" | jq -e ".error.message")
    if [ -n "${message}" ]; then
      data="{\"message\":${message}}"
    else
      data="{\"message\":null}"
    fi
  fi

  trace "[elements_fundrawtransaction] responding=${data}"

  echo "${data}"

  return ${returncode}
}

elements_blindrawtransaction() {
  trace "Entering elements__blindrawtransaction()..."

  local request=${1}
  local rawtx=$(echo "${request}" | jq -r ".hex")
  trace "[elements__blindrawtransaction] rawtx=${rawtx}"

  local response

  local params='{"method":"blindrawtransaction","params":["'${rawtx}'"]}'

  local temp_response=$(mktemp)
  send_to_elements_spender_node "${params}" > "${temp_response}"

  local returncode=$?
  trace_rc ${returncode}
  trace "[elements_blindrawtransaction] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    cat "${temp_response}"
  else
    local message=$(echo "${response}" | jq -e ".error.message")
    if [ -n "${message}" ]; then
      data="{\"message\":${message}}"
    else
      data="{\"message\":null}"
    fi

    echo "${data}"
  fi

  rm "${temp_response}"

  return ${returncode}
}

elements_signrawtransaction() {
  trace "Entering elements_signrawtransaction()..."

  local request=${1}
  local rawtx=$(echo "${request}" | jq -r ".hex")
  trace "[elements_signrawtransaction] rawtx=${rawtx}"

  local response

  local data='{"method":"signrawtransactionwithwallet","params":["'${rawtx}'"]}'

  response=$(send_to_elements_spender_node "${data}")

  local returncode=$?
  trace_rc ${returncode}
  trace "[elements_signrawtransaction] response=${response}"

  if [ "${returncode}" -eq 0 ]; then
    local data=$(echo ${response} | jq -rc ".result")
  else
    local message=$(echo "${response}" | jq -e ".error.message")
    if [ -n "${message}" ]; then
      data="{\"message\":${message}}"
    else
      data="{\"message\":null}"
    fi
  fi

  trace "[elements_signrawtransaction] responding=${data}"

  echo "${data}"

  return ${returncode}
}

elements_sendrawtransaction() {
  trace "Entering elements_sendrawtransaction()..."

  local request=${1}
  local rawtx=$(echo "${request}" | jq -r ".hex")
  trace "[elements_sendrawtransaction] rawtx=${rawtx}"
  local maxfeerate=$(echo "${request}" | jq -r ".maxfeerate // 0.1")
  trace "[elements_sendrawtransaction] maxfeerate=${maxfeerate}"

  local response

  local data='{"method":"sendrawtransaction","params":["'${rawtx}'",'${maxfeerate}']}'

  response=$(send_to_elements_spender_node "${data}")

  local returncode=$?
  trace_rc ${returncode}
  trace "[elements_sendrawtransaction] response=${response}"

  echo "${response}"

  return ${returncode}
}