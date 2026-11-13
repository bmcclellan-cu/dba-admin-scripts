#!/usr/bin/env bash
# AvailabilityFlag: Public
#
# Purpose: This script subscribes a comma separated list of email addresses to both
#           the daily and weekly cost report SNS topics created by the BillingReport
#           SAM application. The list can be passed directly or as a path to a CSV file.
#           Emails already subscribed to a topic are skipped.
#
# Note: Quoted local parts and spaces within email addresses are not supported by this script.
#
#####################################################################################

usage="Usage: SubscribeEmailsToBillingReport.sh [ -s stack_name (optional, default BillingReport) ] [ -r region (optional) ] [ email_csv_list | csv_file ]"
example="Example: SubscribeEmailsToBillingReport.sh -r us-east-1 \"user1@example.com,user2@example.com\""

stack_name="BillingReport"
# Process input options
while getopts ":hs:r:" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    s)
        stack_name=$OPTARG
        ;;
    r)
        export AWS_REGION="$OPTARG"
        ;;
    :)
        echo "Error: Option -$OPTARG requires an argument"
        exit 1
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done
shift "$((OPTIND - 1))"

if [ $# -ne 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Call helper script to verify AWS credentials
VerifyAWSLoginCredentials.sh
if [ $? -ne 0 ]; then
    # Error message will be displayed by calling script.
    exit 1
fi

# Accept either a CSV file or a comma separated string of emails
if [ -f "$1" ]; then
    email_input=$(cat "$1")
else
    email_input=$1
fi

# Split on commas and newlines, trim whitespace, strip quotes, drop empty entries and duplicates
emails=()
while IFS= read -r email; do
    [ -z "$email" ] && continue
    if [[ ! "$email" =~ ^[^@[:space:]\;]+@[^@[:space:]\;]+\.[^@[:space:]\;]+$ ]]; then
        echo "Error: '$email' is not a valid email address. Exiting..."
        exit 1
    fi
    emails+=("$email")
done < <(echo "$email_input" | tr ',' '\n' | sed -E 's/^[[:space:]"]+//; s/[[:space:]"]+$//' | sort -fu)

if [ ${#emails[@]} -eq 0 ]; then
    echo "No email addresses provided. Exiting..."
    exit 1
fi

echo
echo "Looking up SNS topic ARNs from stack $stack_name..."
outputs=$(aws cloudformation describe-stacks --stack-name "$stack_name")
if [ $? -ne 0 ]; then
    echo "An error occurred while describing stack $stack_name. Make sure you are in the same region as the stack or use the region option. Exiting..."
    echo "$outputs"
    exit 1
fi

daily_topic_arn=$(echo "$outputs" | jq -r '.Stacks[0].Outputs[]? | select(.OutputKey == "DailyCostReportTopicArn") | .OutputValue')
weekly_topic_arn=$(echo "$outputs" | jq -r '.Stacks[0].Outputs[]? | select(.OutputKey == "WeeklyCostReportTopicArn") | .OutputValue')
if [ -z "$daily_topic_arn" ] || [ -z "$weekly_topic_arn" ]; then
    echo "Could not find the daily and weekly topic ARNs in the outputs of stack $stack_name. Exiting..."
    exit 1
fi
echo "Daily topic:  $daily_topic_arn"
echo "Weekly topic: $weekly_topic_arn"
echo

failures=0
for topic_arn in "$daily_topic_arn" "$weekly_topic_arn"; do
    existing=$(aws sns list-subscriptions-by-topic --topic-arn "$topic_arn" \
        --query "Subscriptions[?Protocol=='email'].Endpoint" --output text 2>&1)
    if [ $? -ne 0 ]; then
        echo "An error occurred while listing subscriptions for $topic_arn. Exiting..."
        echo "$existing"
        exit 1
    fi
    existing_lower=$(echo "$existing" | tr '[:upper:]' '[:lower:]' | tr '\t' '\n')

    echo "Subscribing emails to ${topic_arn##*:}..."
    for email in "${emails[@]}"; do
        email_lower=$(echo "$email" | tr '[:upper:]' '[:lower:]')
        if echo "$existing_lower" | grep -Fxq "$email_lower"; then
            echo "  $email is already subscribed (or pending confirmation). Skipping."
            continue
        fi
        res=$(aws sns subscribe --protocol email --topic-arn "$topic_arn" \
            --notification-endpoint "$email" 2>&1)
        if [ $? -ne 0 ]; then
            echo "  Failed to subscribe $email:"
            echo "  $res"
            failures=$((failures + 1))
        else
            echo "  Subscribed $email."
        fi
    done
    echo
done

if [ $failures -gt 0 ]; then
    echo "$failures subscription(s) failed. See errors above."
    exit 1
fi

echo "Done. Each new subscriber must confirm the subscription from the AWS confirmation email"
echo "(check the Outlook 'Other' inbox if it does not appear)."
exit 0
