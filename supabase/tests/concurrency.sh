#!/usr/bin/env bash
# Parallel sessions race for the same slot / webhook. Runs against the already-migrated test DB.
set -euo pipefail
DB="${DB:-skillconnect_test}"
P="psql -qXtA -v ON_ERROR_STOP=0 -d $DB"
N=8
$P -c "insert into auth.users (id,email) select ('99999999-0000-0000-0000-00000000000'||g)::uuid, 'race'||g||'@example.test' from generate_series(1,$N) g;
       insert into public.customer_addresses (user_id,line1,city,area_id) select id,'Race Tower','Dubai','a0000000-0000-0000-0000-000000000001' from auth.users where email like 'race%';" >/dev/null
race() { # $1 = worker uuid or NULL ; $2 = days ahead
  local out; out=$(mktemp -d)
  for i in $(seq 1 $N); do
    ( $P -c "set role authenticated; select set_config('request.jwt.claim.sub','99999999-0000-0000-0000-00000000000$i',false), set_config('request.jwt.claim.role','authenticated',false);
             select 'OK' from public.reserve_slot('d0000000-0000-0000-0000-000000000001','a0000000-0000-0000-0000-000000000001',
               ((current_date + $2) + interval '10 hours') at time zone 'Asia/Dubai', null, $1);" 2>&1 | grep -E "^OK|slot_unavailable" | head -1 > "$out/$i" ) &
  done
  wait
  cat "$out"/* | grep -c '^OK' || true
  rm -rf "$out"
}
ok1=$(race "'22222222-0000-0000-0000-000000000001'::uuid" 20)
ok2=$(race "null" 21)
echo "single-worker race: $ok1 success(es) of $N (expected 1)"
echo "two-worker race:    $ok2 success(es) of $N (expected 2)"
$P -c "select count(*) from (select worker_id from public.booking_slot_reservations where status='active' and start_at >= now() group by worker_id, start_at having count(*) > 1) d" | grep -qx 0 && echo "no duplicate live holds in table" || { echo "DUPLICATE HOLDS"; exit 1; }

# Webhook redelivery race: same event id delivered concurrently
$P -c "select tests.new_booking('c1','svc_elec',tests.slot(30,10),'w1')" > /tmp/race_booking_id.txt
BID=$(head -1 /tmp/race_booking_id.txt)
PID=$($P -c "set role authenticated; select set_config('request.jwt.claim.sub','11111111-0000-0000-0000-000000000001',false); select id from public.prepare_payment('$BID', null, 'race-pay-key-1');" | tail -1)
$P -c "set role service_role; select public.attach_provider_ref('$PID','sandbox','sbx_race',false)" >/dev/null
out=$(mktemp -d)
for i in $(seq 1 $N); do
  ( $P -c "set role service_role; select public.process_payment_event('sandbox','evt_race','payment.succeeded','sbx_race',15750,'AED',false)" | grep -o '"result": "[a-z_]*"' > "$out/$i" ) &
done
wait
processed=$(cat "$out"/* | grep -c '"processed"' || true); dups=$(cat "$out"/* | grep -c '"duplicate"' || true)
echo "webhook race: processed=$processed duplicate=$dups (expected 1 / $((N-1)))"
tx=$($P -c "select count(*) from public.ledger_transactions where payment_id='$PID'")
echo "ledger transactions for payment: $tx (expected 1)"
[ "$ok1" = 1 ] && [ "$ok2" = 2 ] && [ "$processed" = 1 ] && [ "$tx" = 1 ]
