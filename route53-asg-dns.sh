#!/bin/bash
#
# Get all IPs from an autoscale group and update set the local ip as
# equal weight A entries (round robin dns). Takes autoscale group as
# parameter.
#

POSITIONAL=()
while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    -d|--domain)
    DOMAIN="$2"
    shift # past argument
    shift # past value
    ;;
    -a|--auto-scaling-group)
    GROUP="$2"
    shift # past argument
    shift # past value
    ;;
    -t|--name-tag)
    NAME_TAG="$2"
    shift # past argument
    shift # past value
    ;;
    *)    # unknown option
    POSITIONAL+=("$1") # save it in an array for later
    shift # past argument
    ;;
esac
done

set -- "${POSITIONAL[@]}" # restore positional parameters
([ -n "$DOMAIN" ]  && ([ -n "$GROUP" ] || [ -n "$NAME_TAG" ])) || {
  echo >&2 "Usage: $0 -d <domain> -t <name-tag> -a <auto-scaling-group>"
  exit 2
}

asg_ips () {
	
    local instance_ids="$(aws autoscaling describe-auto-scaling-groups \
                        --auto-scaling-group-names "$GROUP" \
                        --query 'AutoScalingGroups[*].Instances[*].[InstanceId]' --output text)"

    aws ec2 describe-instances --instance-ids $instance_ids \
        --query 'Reservations[*].Instances[*].[PrivateIpAddress]' --output text
}

gen_json () {
    local private_ips=($(asg_ips))
    cat <<EOF
{
  "Comment": "Modifying autoscale group $1 record for the zone.",
  "Changes": [
    {
    "Action": "UPSERT",
    "ResourceRecordSet": {
        "Name": "$1.${DOMAIN}.",
        "Type": "A",
        "TTL": 300,
        "ResourceRecords": [
EOF

    local -i count=${#private_ips[@]}
    for ((i=0 ; i < $count - 1 ; i ++)); do
    cat <<EOF
            {
                "Value": "${private_ips[$i]}"
            },
EOF
    done
    cat <<EOF
            {
                "Value": "${private_ips[(( $count - 1 ))]}"
            }
EOF
    cat <<EOF
        ]
      }
    }
  ]
}
EOF
}
if [ -z "$GROUP" ]; then
	GROUP=$(aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[?contains(Tags[?Key==\`Name\`].Value, \`${NAME_TAG}\`)].[AutoScalingGroupName]")
fi
gen_json "$GROUP" > /tmp/${GROUP}.json
ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name ${DOMAIN} --query 'HostedZones[*].Id' --output text)
ZONE_ID=${ZONE_ID##/hostedzone/}
aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch file:///tmp/${GROUP}.json
