#!/bin/bash

# Parse parameters
while [[ "$#" -gt 0 ]]; do case $1 in
  --user-profile) USER_PROFILE="$2"; shift;;
  --role-profile) ROLE_PROFILE="$2"; shift;;
  --role-arn) ROLE_ARN="$2"; shift;;
  --session) SESSION="$2";shift;;
  --region) REGION="$2";shift;;
  *) echo "Unknown parameter passed: $1"; exit 1;;
esac; shift; done

# Verify parameters
if [ -z "$USER_PROFILE" ]; then echo "User profile name is not set."; exit 1; fi;
if [ -z "$ROLE_PROFILE" ]; then echo "Role profile name is not set."; exit 1; fi;
if [ -z "$ROLE_ARN" ]; then echo "Role ARN is not set"; exit 1; fi;
if [ -z "$SESSION" ]; then echo "Session name is not set."; exit 1; fi;
if [ -z "$REGION" ]; then echo "Region is not set."; exit 1; fi;

main() {
  local credentials
  if ! credentials=$(
    aws sts assume-role \
      --role-arn "$ROLE_ARN" \
      --role-session-name "$SESSION" \
      --profile "$USER_PROFILE"\
  ) || [ -z "$credentials" ]; then
      echo 'Could not assume the role'
      exit 1
  fi

  local aws_access_key_id
  if ! aws_access_key_id=$(
    echo "$credentials" | jq -r '.Credentials.AccessKeyId'
  ) || [ -z "$aws_access_key_id" ]; then
      echo 'Could parse access key ID'
      exit 1
  fi
  echo ::add-mask::"$aws_access_key_id"

  local aws_secret_access_key
  if ! aws_secret_access_key=$(
    echo "$credentials" | jq -r '.Credentials.SecretAccessKey'
  ) || [ -z "$aws_secret_access_key" ]; then
      echo 'Could parse access key'
      exit 1
  fi
  echo ::add-mask::"$aws_secret_access_key"


  local aws_session_token
  if ! aws_session_token=$(
    echo "$credentials" | jq -r '.Credentials.SessionToken'
  ) || [ -z "$aws_secret_access_key" ]; then
      echo 'Could parse session token'
      exit 1
  fi
  echo ::add-mask::"$aws_session_token"

  if ! aws configure \
    --profile "$ROLE_PROFILE" \
    set aws_access_key_id "$aws_access_key_id"
  then
    echo 'Could set access key ID'
    exit 1
  fi

  if ! aws configure \
    --profile "$ROLE_PROFILE" \
    set aws_secret_access_key "$aws_secret_access_key"
  then
    echo 'Could set access key'
    exit 1
  fi

  if ! aws configure \
    --profile "$ROLE_PROFILE" \
    set aws_session_token "$aws_session_token"
  then
    echo 'Could set session token'
    exit 1
  fi

  if ! aws configure \
    --profile "$ROLE_PROFILE" \
    set region "$REGION"
  then
    echo 'Could set region'
    exit 1
  fi

  echo "Profile $ROLE_PROFILE is successfully created"

  bash "${BASH_SOURCE%/*}/mask-identity.sh" --profile "$ROLE_PROFILE"
}


main