#!/bin/bash

# Parse parameters
while [[ "$#" -gt 0 ]]; do case $1 in
  --access-key-id)                  ACCESS_KEY_ID="$2"; shift;;                 # Required, used for AWS authentication
  --secret-access-key)              SECRET_ACCESS_KEY="$2"; shift;;             # Required, used for AWS authentication
  --region)                         REGION="$2";shift;;                         # Required, as preferred location for resources
  --root-domain)                    ROOT_DOMAIN="$2";shift;;                    # Required, for setting-up the DNS
  --resource-prefix)                RESOURCE_PREFIX="$2";shift;;                # Required, for naming resources
  --site-dist-dir)                  SITE_DIST_DIR="$2";shift;;                  # Required, for deploying site
  --session-name)                   SESSION_NAME="$2";shift;;                   # Required, for auditability and troubleshooting
  --role-arn-iam)                   ROLE_ARN_IAM="$2";shift;;                   # Required, output from IAM stack
  --role-arn-dns)                   ROLE_ARN_DNS="$2";shift;;                   # Required, output from IAM stack
  --role-arn-cert)                  ROLE_ARN_CERT="$2";shift;;                  # Required, output from IAM stack
  --role-arn-web)                   ROLE_ARN_WEB="$2";shift;;                   # Required, output from IAM stack
  --role-arn-cf-lambda-sync)        ROLE_ARN_CF_LAMBDA_SYNC="$2";shift;;        # Required, output from IAM stack
  --role-arn-cf-invalidate)         ROLE_ARN_CF_INVALIDATE="$2";shift;;         # Required, output from IAM stack
  --role-arn-s3-upload)             ROLE_ARN_S3_UPLOAD="$2";shift;;             # Required, output from IAM stack
  --use-index-html-rewrite)         USE_INDEX_HTML_REWRITE="$2";shift;;         # Optional
  --404-page)                       PAGE_404="$2";shift;;                       # Optional
  --use-deep-links)                 USE_DEEP_LINKS="$2";shift;;                 # Optional
  --use-path-html-rewrite)          USE_PATH_HTML_REWRITE="$2";shift;;          # Optional
  --force-remove-trailing-slash)    FORCE_REMOVE_TRAILING_SLASH="$2";shift;;    # Optional
  --force-trailing-slash)           FORCE_TRAILING_SLASH="$2";shift;;           # Optional
  *) echo "Unknown parameter passed: $1"; exit 1;;
esac; shift; done

# Verify parameters
if [ -z "$ACCESS_KEY_ID" ];             then echo 'Access key ID is not set';                               exit 1; fi;
if [ -z "$SECRET_ACCESS_KEY" ];         then echo 'Secret access key is not set.';                          exit 1; fi;
if [ -z "$REGION" ];                    then echo 'Region is not set.';                                     exit 1; fi;
if [ -z "$ROOT_DOMAIN" ];               then echo 'Root domain is not set.';                                exit 1; fi;
if [ -z "$RESOURCE_PREFIX" ];           then echo 'Resource prefix is not set.';                            exit 1; fi;
if [ -z "$SITE_DIST_DIR" ];             then echo 'Site dist dir (build artifacts) is not set.';            exit 1; fi;
if [ -z "$SESSION_NAME" ];              then echo 'Session name is not set.';                               exit 1; fi;
if [ -z "$ROLE_ARN_IAM" ];              then echo 'Role ARN for IAM stack is not set.';                     exit 1; fi;
if [ -z "$ROLE_ARN_DNS" ];              then echo 'Role ARN for DNS stack is not set.';                     exit 1; fi;
if [ -z "$ROLE_ARN_CERT" ];             then echo 'Role ARN for cert stack is not set.';                    exit 1; fi;
if [ -z "$ROLE_ARN_WEB" ];              then echo 'Role ARN for WEB stack is not set.';                     exit 1; fi;
if [ -z "$ROLE_ARN_CF_INVALIDATE" ];    then echo 'Role ARN for CloudFront invalidation is not set.';       exit 1; fi;
if [ -z "$ROLE_ARN_CF_LAMBDA_SYNC" ];   then echo 'Role ARN for CloudFront Lambda@Edge sync is not set.';   exit 1; fi;
if [ -z "$ROLE_ARN_S3_UPLOAD" ];        then echo 'Role ARN for S3 site deployment is not set.';            exit 1; fi;
if [[ ! -d "$SITE_DIST_DIR" ]]; then
    echo "Error: Site distribution directory '$SITE_DIST_DIR' does not exist"
    exit 1
fi

set -e # Abort the script if any command fails

main() {
    local -r project_root="$(locate_project_root)"

    echo '--------------------------------'
    echo '----Create AWS user profile-----'
    echo '--------------------------------'
    readonly profile_name='user'
    bash "$project_root/scripts/configure/create-user-profile.sh" \
        --profile "$profile_name" \
        --access-key-id "$ACCESS_KEY_ID" \
        --secret-access-key "$SECRET_ACCESS_KEY" \
        --region "$REGION"

    echo '--------------------------------'
    echo '--------Deploy IAM stack--------'
    echo '--------------------------------'
    readonly iam_stack_name="$RESOURCE_PREFIX-iam-stack"
    readonly web_stack_name="$RESOURCE_PREFIX-web-stack"
    readonly dns_stack_name="$RESOURCE_PREFIX-dns-stack"
    readonly cert_stack_name="$RESOURCE_PREFIX-cert-stack"
    bash "$project_root/scripts/deploy/deploy-stack.sh" \
        --template-file "$project_root/stacks/iam-stack.yaml" \
        --stack-name "$iam_stack_name" \
        --capabilities CAPABILITY_IAM \
        --parameter-overrides "\
            WebStackName=$web_stack_name \
            DnsStackName=$dns_stack_name \
            CertificateStackName=$cert_stack_name \
            RootDomainName=$ROOT_DOMAIN \
        " \
        --region "$REGION" \
        --role-arn "$ROLE_ARN_IAM" \
        --profile "$profile_name" \
        --session "$SESSION_NAME"

    echo '--------------------------------'
    echo '--------Deploy DNS stack--------'
    echo '--------------------------------'
    bash "$project_root/scripts/deploy/deploy-stack.sh" \
        --template-file "$project_root/stacks/dns-stack.yaml" \
        --stack-name "$dns_stack_name" \
        --parameter-overrides "\
            RootDomainName=$ROOT_DOMAIN \
        " \
        --region "$REGION" \
        --role-arn "$ROLE_ARN_DNS" \
        --profile "$profile_name" \
        --session "$SESSION_NAME"

    echo '--------------------------------'
    echo '----Deploy certificate stack----'
    echo '--------------------------------'
    # It must be deployed in us-east-1, see: https://repost.aws/knowledge-center/cloudfront-invalid-viewer-certificate
    bash "$project_root/scripts/deploy/deploy-stack.sh" \
        --template-file "$project_root/stacks/certificate-stack.yaml" \
        --stack-name "$cert_stack_name" \
        --parameter-overrides "\
            RootDomainName=$ROOT_DOMAIN \
            DnsStackName=$dns_stack_name \
        " \
        --region 'us-east-1' \
        --role-arn "$ROLE_ARN_CERT" \
        --profile "$profile_name" \
        --session "$SESSION_NAME"

    echo '--------------------------------'
    echo '--------Deploy web stack--------'
    echo '--------------------------------'
    params=(
        "CertificateStackName=$cert_stack_name"
        "DnsStackName=$dns_stack_name"
        "RootDomainName=$ROOT_DOMAIN"
    )
    [[ -n "$USE_INDEX_HTML_REWRITE" ]]          &&  params+=("UseIndexHtmlRewrite=$USE_INDEX_HTML_REWRITE")
    [[ -n "$PAGE_404" ]]                        &&  params+=("404Page=$PAGE_404")
    [[ -n "$USE_DEEP_LINKS" ]]                  &&  params+=("UseDeepLinks=$USE_DEEP_LINKS")
    [[ -n "$FORCE_REMOVE_TRAILING_SLASH" ]]     &&  params+=("ForceRemoveTrailingSlash=$FORCE_REMOVE_TRAILING_SLASH")
    [[ -n "$FORCE_TRAILING_SLASH" ]]            &&  params+=("ForceTrailingSlash=$FORCE_TRAILING_SLASH")
    [[ -n "$USE_PATH_HTML_REWRITE" ]]           &&  params+=("UsePathHtmlRewrite=$USE_PATH_HTML_REWRITE")
    bash "$project_root/scripts/deploy/deploy-stack.sh" \
        --template-file "$project_root/stacks/web-stack.yaml" \
        --stack-name "$web_stack_name" \
        --parameter-overrides "$(IFS=' ' ; echo "${params[*]}")"\
        --capabilities CAPABILITY_IAM \
        --region "$REGION" \
        --role-arn "$ROLE_ARN_WEB" \
        --profile "$profile_name" \
        --session "$SESSION_NAME"

    echo '--------------------------------'
    echo '-Sync CloudFront Lambda version-'
    echo '--------------------------------'
    bash "$project_root/scripts/deploy/sync-cloudfront-lambda-version.sh" \
        --profile "$profile_name" \
        --role-arn "$ROLE_ARN_CF_LAMBDA_SYNC" \
        --session "$SESSION_NAME" \
        --region "$REGION" \
        --web-stack-name "$web_stack_name" \
        --web-stack-cloudfront-arn-output-name CloudFrontDistributionArn

    echo '--------------------------------'
    echo '----------Deploy to S3----------'
    echo '--------------------------------'
    bash "$project_root/scripts/deploy/deploy-to-s3.sh" \
        --folder "$SITE_DIST_DIR" \
        --web-stack-name "$web_stack_name" \
        --web-stack-s3-name-output-name S3BucketName \
        --storage-class ONEZONE_IA \
        --role-arn "$ROLE_ARN_S3_UPLOAD" \
        --region "$REGION" \
        --profile "$profile_name" \
        --session "$SESSION_NAME"

    echo '--------------------------------'
    echo '--Invalidate CloudFront cache---'
    echo '--------------------------------'
    bash "$project_root/scripts/deploy/invalidate-cloudfront-cache.sh" \
        --paths "/*" \
        --web-stack-name "$web_stack_name" \
        --web-stack-cloudfront-arn-output-name CloudFrontDistributionArn \
        --role-arn "$ROLE_ARN_CF_INVALIDATE" \
        --region "$REGION" \
        --profile "$profile_name" \
        --session "$SESSION_NAME"
}

locate_project_root() {
    local script_path
    if ! script_path="$(cd -- "$(dirname "$0")" >/dev/null 2>&1 ; pwd -P)"; then
        echo 'Could not locate self directory'
    fi
    local project_root
    if ! project_root=$(dirname "$script_path"); then
        echo 'Could not locate project root'
    fi
    echo "$project_root"
}

main
