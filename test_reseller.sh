#!/bin/bash
# Test script for M0: Connect, Promotion Codes, Customer Balance

set -eux

HOST=http://localhost:8420
SK=sk_test_12345

# Flush store to start clean
curl -sSfg -X DELETE $HOST/_config/data

# ============================================================
# test_create_connect_account
# ============================================================

acct=$(curl -sSfg -u $SK: $HOST/v1/accounts \
           -d type=express \
           -d email=connected@example.com \
           -d country=US \
      | tee /dev/stderr | grep -oE 'acct_\w+' | head -n 1)
[ -n "$acct" ]

# Verify charges_enabled and payouts_enabled
charges_enabled=$(curl -sSfg -u $SK: $HOST/v1/accounts/$acct \
                  | grep -oE '"charges_enabled": true')
[ -n "$charges_enabled" ]
payouts_enabled=$(curl -sSfg -u $SK: $HOST/v1/accounts/$acct \
                  | grep -oE '"payouts_enabled": true')
[ -n "$payouts_enabled" ]

echo "PASS: test_create_connect_account"

# ============================================================
# test_account_links_onboarding
# ============================================================

link_url=$(curl -sSfg -u $SK: $HOST/v1/account_links \
               -d account=$acct \
               -d type=account_onboarding \
               -d refresh_url=https://example.com/refresh \
               -d return_url=https://example.com/return \
          | tee /dev/stderr | grep -oE '"url": "https://connect.stripe.com/setup/s/test_[^"]*"')
[ -n "$link_url" ]

echo "PASS: test_account_links_onboarding"

# ============================================================
# Setup: create customer, payment method, and token for charges
# ============================================================

tok=$(curl -sSfg -u $SK: $HOST/v1/tokens \
          -d card[number]=4242424242424242 \
          -d card[exp_month]=12 \
          -d card[exp_year]=2030 \
          -d card[cvc]=123 \
     | grep -oE 'tok_\w+' | head -n 1)

cus=$(curl -sSfg -u $SK: $HOST/v1/customers \
          -d email=platform@example.com \
          -d source=$tok \
     | grep -oE 'cus_\w+' | head -n 1)

# ============================================================
# test_create_transfer_to_connected_account
# ============================================================

tr=$(curl -sSfg -u $SK: $HOST/v1/transfers \
         -d amount=5000 \
         -d currency=usd \
         -d destination=$acct \
         -d description='Transfer to connected account' \
    | tee /dev/stderr | grep -oE 'tr_\w+' | head -n 1)
[ -n "$tr" ]

# Verify amount and destination
tr_amount=$(curl -sSfg -u $SK: $HOST/v1/transfers/$tr \
            | grep -oE '"amount": 5000')
[ -n "$tr_amount" ]
tr_dest=$(curl -sSfg -u $SK: $HOST/v1/transfers/$tr \
          | grep -oE "\"destination\": \"$acct\"")
[ -n "$tr_dest" ]

echo "PASS: test_create_transfer_to_connected_account"

# ============================================================
# test_reverse_transfer
# ============================================================

reversal=$(curl -sSfg -u $SK: $HOST/v1/transfers/$tr/reversals \
               -d amount=2000 \
          | tee /dev/stderr | grep -oE '"amount": 2000')
[ -n "$reversal" ]

# Verify amount_reversed on the transfer
amount_reversed=$(curl -sSfg -u $SK: $HOST/v1/transfers/$tr \
                  | grep -oE '"amount_reversed": 2000')
[ -n "$amount_reversed" ]

echo "PASS: test_reverse_transfer"

# ============================================================
# test_destination_charge_with_application_fee
# ============================================================

charge=$(curl -sSfg -u $SK: $HOST/v1/charges \
              -d amount=10000 \
              -d currency=usd \
              -d customer=$cus \
              -d destination[account]=$acct \
              -d application_fee_amount=1500 \
        | tee /dev/stderr)
charge_id=$(echo "$charge" | grep -oE 'ch_\w+' | head -n 1)
[ -n "$charge_id" ]
app_fee=$(echo "$charge" | grep -oE '"application_fee_amount": 1500')
[ -n "$app_fee" ]

echo "PASS: test_destination_charge_with_application_fee"

# ============================================================
# test_create_promotion_code
# ============================================================

# First create a coupon
curl -sSfg -u $SK: $HOST/v1/coupons \
     -d id=SUMMER20 \
     -d percent_off=20.0 \
     -d duration=forever

promo=$(curl -sSfg -u $SK: $HOST/v1/promotion_codes \
             -d code=SUMMER2024 \
             -d coupon=SUMMER20 \
             -d metadata[campaign]=summer \
        | tee /dev/stderr | grep -oE 'promo_\w+' | head -n 1)
[ -n "$promo" ]

# GET to verify
promo_code=$(curl -sSfg -u $SK: $HOST/v1/promotion_codes/$promo \
             | grep -oE '"code": "SUMMER2024"')
[ -n "$promo_code" ]

# List by code
promo_list=$(curl -sSfg -u $SK: "$HOST/v1/promotion_codes?code=SUMMER2024" \
             | grep -oE '"total_count": 1')
[ -n "$promo_list" ]

echo "PASS: test_create_promotion_code"

# ============================================================
# test_promotion_code_redemption_on_subscription
# ============================================================

# Create a plan for subscription
curl -sSfg -u $SK: $HOST/v1/plans \
     -d id=pro-monthly \
     -d product[name]='Pro Monthly' \
     -d amount=5000 \
     -d currency=usd \
     -d interval=month

sub=$(curl -sSfg -u $SK: $HOST/v1/subscriptions \
           -d customer=$cus \
           -d items[0][plan]=pro-monthly \
           -d promotion_code=SUMMER2024 \
     | tee /dev/stderr)
sub_id=$(echo "$sub" | grep -oE 'sub_\w+' | head -n 1)
[ -n "$sub_id" ]

# Verify discount is present
discount=$(echo "$sub" | grep -oE '"discount"')
[ -n "$discount" ]

# Verify times_redeemed incremented
times_redeemed=$(curl -sSfg -u $SK: $HOST/v1/promotion_codes/$promo \
                 | grep -oE '"times_redeemed": 1')
[ -n "$times_redeemed" ]

echo "PASS: test_promotion_code_redemption_on_subscription"

# ============================================================
# test_deactivate_promotion_code
# ============================================================

deactivated=$(curl -sSfg -u $SK: $HOST/v1/promotion_codes/$promo \
                   -d active=false \
              | grep -oE '"active": false')
[ -n "$deactivated" ]

echo "PASS: test_deactivate_promotion_code"

# ============================================================
# test_customer_balance_transaction
# ============================================================

# Create a fresh customer for balance tests
tok2=$(curl -sSfg -u $SK: $HOST/v1/tokens \
           -d card[number]=4242424242424242 \
           -d card[exp_month]=12 \
           -d card[exp_year]=2030 \
           -d card[cvc]=123 \
      | grep -oE 'tok_\w+' | head -n 1)

bal_cus=$(curl -sSfg -u $SK: $HOST/v1/customers \
               -d email=balance@example.com \
               -d source=$tok2 \
          | grep -oE 'cus_\w+' | head -n 1)

# Credit the customer (negative = credit in Stripe's convention for balance_transactions)
cbtxn=$(curl -sSfg -u $SK: $HOST/v1/customers/$bal_cus/balance_transactions \
             -d amount=-5000 \
             -d currency=usd \
             -d description='Initial credit' \
        | tee /dev/stderr | grep -oE 'cbtxn_\w+' | head -n 1)
[ -n "$cbtxn" ]

# Verify customer balance updated (account_balance should be -5000)
bal=$(curl -sSfg -u $SK: $HOST/v1/customers/$bal_cus \
     | grep -oE '"account_balance": -5000')
[ -n "$bal" ]

# List balance transactions
bt_list=$(curl -sSfg -u $SK: $HOST/v1/customers/$bal_cus/balance_transactions \
          | grep -oE '"total_count": 1')
[ -n "$bt_list" ]

echo "PASS: test_customer_balance_transaction"

# ============================================================
# test_invoice_balance_credit_application
# ============================================================

# Customer has -5000 credit (account_balance = -5000)
# Create an invoice item and invoice; the balance should be applied
curl -sSfg -u $SK: $HOST/v1/invoiceitems \
     -d customer=$bal_cus \
     -d amount=3000 \
     -d currency=usd

inv=$(curl -sSfg -u $SK: $HOST/v1/invoices \
           -d customer=$bal_cus \
      | tee /dev/stderr)
inv_id=$(echo "$inv" | grep -oE 'in_\w+' | head -n 1)
[ -n "$inv_id" ]

# starting_balance should be -5000 (credit available)
starting=$(echo "$inv" | grep -oE '"starting_balance": -5000')
[ -n "$starting" ]

echo "PASS: test_invoice_balance_credit_application"

# ============================================================
# test_invoice_days_until_due
# ============================================================

# Create another invoice item for a new invoice
curl -sSfg -u $SK: $HOST/v1/invoiceitems \
     -d customer=$bal_cus \
     -d amount=1000 \
     -d currency=usd

inv2=$(curl -sSfg -u $SK: $HOST/v1/invoices \
            -d customer=$bal_cus \
            -d days_until_due=30 \
       | tee /dev/stderr)
inv2_id=$(echo "$inv2" | grep -oE 'in_\w+' | head -n 1)
[ -n "$inv2_id" ]

# Verify days_until_due
days=$(echo "$inv2" | grep -oE '"days_until_due": 30')
[ -n "$days" ]

# Verify due_date exists and is set
due_date=$(echo "$inv2" | grep -oE '"due_date": [0-9]+')
[ -n "$due_date" ]

echo "PASS: test_invoice_days_until_due"

# ============================================================
# test_connect_webhook_events
# ============================================================

# Look for transfer.created event in the events list
events=$(curl -sSfg -u $SK: "$HOST/v1/events?type=transfer.created" \
         | tee /dev/stderr)
event_count=$(echo "$events" | grep -oE '"type": "transfer.created"' | head -n 1)
[ -n "$event_count" ]

echo "PASS: test_connect_webhook_events"

echo ""
echo "=========================================="
echo "ALL TESTS PASSED"
echo "=========================================="
