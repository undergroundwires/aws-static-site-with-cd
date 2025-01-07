#!/bin/bash

# Summary:
#   This script automates the process of updating Lambda@Edge functions associated with CloudFront distributions.
# Problem:
#   Lambda@Edge functions need to be versioned, and CloudFront distributions need to be updated
#   to reference the latest function version. Doing this manually is error-prone and time-consuming,
#   especially in CI/CD pipelines.
# Details:
#   This script ensures that a given CloudFront distribution uses the latest published version 
#   of its associated Lambda@Edge function. It compares the currently associated Lambda version 
#   in CloudFront against the newest published version in AWS Lambda; if outdated, the script 
#   updates the CloudFront distribution to point to the new version. This helps avoid stale lambda
#   versions in production.
# Related StackOverflow discussions:
#   - https://stackoverflow.com/questions/62655805/how-to-update-lambdaedge-arn-in-cloudfront-distribution-using-cli
#       Explains the core challenge of updating Lambda@Edge ARNs in CloudFront distributions
#   - https://stackoverflow.com/questions/50967018/awscli-lambda-function-update-trigger
#       Shows how to manage Lambda@Edge triggers and versioning through AWS CLI

# Parse parameters
while [[ "$#" -gt 0 ]]; do case $1 in
  --profile) PROFILE="$2"; shift;;
  --role-arn) ROLE_ARN="$2";shift;;
  --session) SESSION="$2";shift;;
  --region) REGION="$2";shift;;
  --web-stack-name) WEB_STACK_NAME="$2"; shift;;
  --web-stack-cloudfront-arn-output-name) WEB_STACK_CLOUDFRONT_ARN_OUTPUT_NAME="$2"; shift;;
  *) echo "Unknown parameter passed: $1"; exit 1;;
esac; shift; done

# Verify parameters
if [ -z "$REGION" ]; then echo "Region is not set."; exit 1; fi;
if [ -z "$PROFILE" ]; then echo "Profile is not set."; exit 1; fi;
if [ -z "$ROLE_ARN" ]; then echo "Role ARN is not set."; exit 1; fi;
if [ -z "$SESSION" ]; then echo "Role session is not set."; exit 1; fi;
if [ -z "$WEB_STACK_NAME" ]; then echo "Web stack name is not set."; exit 1; fi;
if [ -z "$WEB_STACK_CLOUDFRONT_ARN_OUTPUT_NAME" ]; then echo "CloudFront ARN output name is not set."; exit 1; fi;


readonly ROLE_PROFILE='sync-cloudfront-lambda-version'

main() {
    echo Assuming role
    bash "${BASH_SOURCE%/*}/../configure/create-role-profile.sh" \
        --role-profile "$ROLE_PROFILE" \
        --user-profile "$PROFILE" \
        --role-arn "$ROLE_ARN" \
        --session "$SESSION" \
        --region "$REGION"

    echo "Getting CloudFront ARN from stack $WEB_STACK_NAME with output $WEB_STACK_CLOUDFRONT_ARN_OUTPUT_NAME"
    local cloudfront_arn
    if ! cloudfront_arn=$(aws cloudformation describe-stacks \
        --stack-name "$WEB_STACK_NAME" \
        --query "Stacks[0].Outputs[?OutputKey=='$WEB_STACK_CLOUDFRONT_ARN_OUTPUT_NAME'].OutputValue" \
        --output text \
        --profile "$ROLE_PROFILE"
    ) || [ -z "$cloudfront_arn" ]; then
        echo 'Could not read CloudFront ARN'
        exit 1
    fi
    echo ::add-mask::"$cloudfront_arn"
    cloudfront_distribution_id="${cloudfront_arn##*/}"

    echo 'Comparing CloudFront associated Lambda@Edge with latest lambda version.'
    local cloudfront_distribution_config
    if ! cloudfront_distribution_config=$(aws cloudfront get-distribution-config \
        --id "$cloudfront_distribution_id" \
        --region "$REGION" \
        --profile "$ROLE_PROFILE"
    ) || [ -z "$cloudfront_distribution_config" ]; then
        echo 'Could not read distribution config'
        exit 1
    fi

    cloudfront_associated_lambda_version_arn=$(
        echo "$cloudfront_distribution_config" \
            | jq -r '.DistributionConfig.DefaultCacheBehavior.LambdaFunctionAssociations.Items[] | select(.EventType=="origin-request") | .LambdaFunctionARN'
    )
    echo ::add-mask::"$cloudfront_associated_lambda_version_arn"

    lambda_arn=${cloudfront_associated_lambda_version_arn%:[0-9]*} # Remove version part (e.g. `:1`) from end.
    echo ::add-mask::"$lambda_arn"

    local latest_lambda_version_arn
    if ! latest_lambda_version_arn=$( # It publishes only Only publishes if code/config has changed, see https://awscli.amazonaws.com/v2/documentation/api/latest/reference/lambda/publish-version.html
        aws lambda publish-version \
            --function-name "$lambda_arn" \
            --region "$REGION" \
            --profile "$ROLE_PROFILE" \
            | jq -r '.FunctionArn'
    ) || [ -z "$latest_lambda_version_arn" ]; then
        echo 'Could publish Lambda version'
        exit 1
    fi
    echo ::add-mask::"$latest_lambda_version_arn"

    cloudfront_associated_lambda_version_digit=${cloudfront_associated_lambda_version_arn##*:}
    latest_lambda_version_digit=${latest_lambda_version_arn##*:}

    if [[ "$cloudfront_associated_lambda_version_digit" == "$latest_lambda_version_digit" ]]; then
        echo "CloudFront is already associated with latest lambda version ($latest_lambda_version_digit), no action needed."
        exit 0
    fi
    echo "Updating CloudFront lambda association ($cloudfront_associated_lambda_version_digit) with the latest lambda version ($latest_lambda_version_digit)."
    e_tag=$( # The entity tag is a hash of the object, see https://docs.aws.amazon.com/AmazonS3/latest/API/API_Object.html#AmazonS3-Type-Object-ETag
        echo "$cloudfront_distribution_config" \
            | jq -r '.ETag'
    )
    cloudfront_distribution_config_payload=$(
        echo "$cloudfront_distribution_config" \
            | jq '(.DistributionConfig.DefaultCacheBehavior.LambdaFunctionAssociations.Items[] | select(.EventType=="origin-request") | .LambdaFunctionARN ) |= "'"$latest_lambda_version_arn"'"' \
            | jq -r '.DistributionConfig' # ETag parameter must be stripped out
    )
    if ! aws cloudfront update-distribution \
        --id "$cloudfront_distribution_id" \
        --distribution-config "$cloudfront_distribution_config_payload" \
        --if-match "$e_tag" \
        --region "$REGION" \
        --profile "$ROLE_PROFILE" \
        --no-paginate \
        --no-cli-pager; then
        echo 'Failed to update Lambda@Edge association'
        exit 1
    fi
    echo 'Successfully updated the Lambda@Edge association'
}

main
