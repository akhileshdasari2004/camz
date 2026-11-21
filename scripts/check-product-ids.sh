#!/bin/bash
# Checks that the Cam Z Pro product IDs are the same in Info.plist, project.yml and the local StoreKit configuration.
# Run from the repository root. Exit code 1 on any mismatch.
set -u
plist_monthly=$(plutil -extract CamZProMonthlyProductID raw -o - CamZ/Info.plist)
plist_annual=$(plutil -extract CamZProAnnualProductID raw -o - CamZ/Info.plist)
yaml_monthly=$(awk -F': *' '/CamZProMonthlyProductID:/ {print $2}' project.yml | tr -d '"' | tr -d ' ')
yaml_annual=$(awk -F': *' '/CamZProAnnualProductID:/ {print $2}' project.yml | tr -d '"' | tr -d ' ')
store_monthly=$(jq -r '.subscriptionGroups[].subscriptions[] | select(.recurringSubscriptionPeriod == "P1M") | .productID' StoreKit/CamZ.storekit)
store_annual=$(jq -r '.subscriptionGroups[].subscriptions[] | select(.recurringSubscriptionPeriod == "P1Y") | .productID' StoreKit/CamZ.storekit)
status=0
check() {
  if [ "$2" = "$3" ] && [ -n "$2" ]; then echo "ok    $1 = $2"; else echo "MISMATCH $1: Info.plist=$2 project.yml=$3 StoreKit=$4"; status=1; fi
}
check monthly "$plist_monthly" "$yaml_monthly" "$store_monthly"
check annual "$plist_annual" "$yaml_annual" "$store_annual"
exit $status
