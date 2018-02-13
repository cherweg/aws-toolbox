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
    -z|--zone-type)
    ZONE_TYPE="$2"
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
([ -n "$DOMAIN" ]  &&  [ -n "$NAME_TAG" ] &&  [ -n "$ZONE_TYPE" ]) || {
  echo >&2 "Usage: $0 -d <domain> -z <zone-type> -t <name-tag> -a <auto-scaling-group>"
  exit 2
}

asg_ips () {

    local instance_ids="$(aws autoscaling describe-auto-scaling-groups \
                        --auto-scaling-group-names "$GROUP" \
                        --region eu-central-1 \
                        --query 'AutoScalingGroups[*].Instances[*].[InstanceId]' --output text)"

    aws ec2 describe-instances --instance-ids $instance_ids --region eu-central-1 \
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
        "Name": "${NAME_TAG}.${DOMAIN}.",
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
  GROUP=$(aws autoscaling describe-auto-scaling-groups --region eu-central-1 --query "AutoScalingGroups[?contains(Tags[?Key==\`Name\`].Value, \`${NAME_TAG}\`)].[AutoScalingGroupName]" --output text)
fi
gen_json "$GROUP" > /tmp/${GROUP}.json
if [ "$ZONE_TYPE" == "PUBLIC" ]; then 
  ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name ${DOMAIN} --region eu-central-1 --query 'HostedZones[?Config.PrivateZone == `false` ].Id' --output text)
elif [ "$ZONE_TYPE" == "PRIVATE" ]; then
  ZONE_ID=$(aws route53 list-hosted-zones-by-name --dns-name ${DOMAIN} --region eu-central-1 --query 'HostedZones[?Config.PrivateZone == `true` ].Id' --output text)
else
  echo >&2 "ZONE_TYPE must be PUBLIC||PRIVATE"
  exit 3
fi
ZONE_ID=${ZONE_ID##/hostedzone/}
aws route53 change-resource-record-sets --region eu-central-1 --hosted-zone-id $ZONE_ID --change-batch file:///tmp/${GROUP}.json
