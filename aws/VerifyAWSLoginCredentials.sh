#!/usr/bin/env bash
# AvailabilityFlag: Public
#
# Purpose: This script will verify that an AWS_PROFILE is set,
#          the aws cli is in the PATH, and a user can establish
#          a connection to AWS.
#
#          This script can be used as a helper script, called by other
#          AWS CLI scripts.
#
# Note:    This script will only print output if an error is identified.
#          Non-critical warnings are only output if given the -v verbose option.
#
#####################################################################################

usage="Usage: VerifyAWSLoginCredentials.sh [ -v (optional, verbose warning output)]"
example="Example: VerifyAWSLoginCredentials.sh"

# Process input options
verbose=false
while getopts ":hv" option; do
    case $option in
    h)
        echo "$usage"
        echo "$example"
        exit 0
        ;;
    v)
        verbose=true
        ;;
    \?)
        echo "Error: Invalid option"
        exit 1
        ;;
    esac
done

if [ $# -gt 1 ]; then
    echo "$usage"
    echo "$example"
    exit 1
fi

# Check that an AWS_PROFILE is set
if [ -z "$AWS_PROFILE" ]; then
    echo "\$AWS_PROFILE not set. Exiting..."
    exit 1
# Check that the AWS CLI is in the current $PATH
elif
    which aws >/dev/null
    test $? -ne 0
then
    echo "AWS CLI not set in \$PATH" && exit 1
# Check that jq is in the current $PATH
elif
    which jq >/dev/null
    test $? -ne 0
then
    echo "jq not set in \$PATH" && exit 1
# Check that the AWS CLI is version 2
# Take the major version from the leading 'aws-cli/<major>.<minor>...' token.
# 2>&1 because aws-cli v1 writes --version to stderr while v2 writes to stdout.
# Compared as a string so an unparseable version fails the check rather than
# erroring out of 'test' with "integer expected".
elif
    awsVersion=$(aws --version 2>&1 | grep -E -o '^aws-cli/[0-9]+' | cut -f2- -d/)
    test "$awsVersion" != "2"
then
    echo "AWS CLI is not version 2" && exit 1
# Check that aws repo is in $PATH
elif
    which VerifyAWSLoginCredentials.sh >>/dev/null
    test $? -ne 0
then
    echo "Please add the absolute path for your aws/scripts directory to your \$PATH environmental variable.
export PATH=$(cd "$(dirname "$0")" && pwd):\$PATH" && exit 1
elif
    aws sts get-caller-identity >/dev/null 2>&1
    test $? -ne 0
then
    echo "AWS credentials not valid!" && exit 1
# Check that AWS_REGION specifically is set.
#
# This is deliberately stricter than the CLI, which resolves a region from the
# first of: the --region command line option, AWS_REGION, AWS_DEFAULT_REGION, or
# the region in the 'Current profile' in ~/.aws/config. (The 'Default profile'
# region only applies when AWS_PROFILE is unset, so it is not relevant here.)
#
# Accepting those other sources would not be safe. Scripts in this repo read
# $AWS_REGION directly rather than letting the CLI resolve it, and several
# interpolate it into an ARN - see AddPermissionsToS3AccessPointPolicy.sh:194 and
# CreateNewIAMAPPolicyJSON.sh:222. With AWS_REGION empty the CLI would still work
# via one of the other sources, while those scripts would silently build
# 'arn:aws:s3::<account>:accesspoint/...' with an empty region field.
elif
    test -z "$AWS_REGION"
then
    echo "AWS_REGION is not set" && exit 1
else
    # If verbose mode is enabled:
    # Loop through env variables with AWS in name and warn user if any other than
    # AWS_PROFILE and AWS_REGION are set
    if $verbose; then
        aws_env_vars=$(env | grep AWS\_)
        while read -r line; do
            # Get name of env variable by taking chars from before the '=' sign
            varname=$(echo "$line" | cut -d '=' -f1)
            if [ "$varname" != "AWS_PROFILE" ] && [ "$varname" != "AWS_REGION" ] && [ "$varname" != "AWS_DEFAULT_REGION" ]; then
                echo ""
                echo "Warning: the following environment variable is set and may cause errors"
                # Name only. The value is deliberately not printed: AWS_SECRET_ACCESS_KEY
                # and AWS_SESSION_TOKEN land here, and this output goes to terminal
                # scrollback and any log a caller redirects it into.
                echo "$varname"
            fi
        done < <(echo "$aws_env_vars")
    fi
    exit 0
fi
