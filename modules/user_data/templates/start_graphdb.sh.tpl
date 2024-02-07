#!/usr/bin/env bash

set -euxo pipefail

until ping -c 1 google.com &> /dev/null; do
  echo "waiting for outbound connectivity"
  sleep 5
done

systemctl stop graphdb

# Set common variables used throughout the script.
imds_token=$( curl -Ss -H "X-aws-ec2-metadata-token-ttl-seconds: 300" -XPUT 169.254.169.254/latest/api/token )
local_ipv4=$( curl -Ss -H "X-aws-ec2-metadata-token: $imds_token" 169.254.169.254/latest/meta-data/local-ipv4 )
instance_id=$( curl -Ss -H "X-aws-ec2-metadata-token: $imds_token" 169.254.169.254/latest/meta-data/instance-id )
availability_zone=$( curl -Ss -H "X-aws-ec2-metadata-token: $imds_token" 169.254.169.254/latest/meta-data/placement/availability-zone )
volume_id=""

# Search for an available EBS volume to attach to the instance. Wait one minute for a volume to become available,
# if no volume is found - create new one, attach, format and mount the volume.

for i in $(seq 1 6); do

  volume_id=$(
    aws --cli-connect-timeout 300 ec2 describe-volumes \
      --filters "Name=status,Values=available" "Name=availability-zone,Values=$availability_zone" "Name=tag:Name,Values=${name}-graphdb-data" \
      --query "Volumes[*].{ID:VolumeId}" \
      --output text | \
      sed '/^$/d'
  )

  if [ -z "$${volume_id:-}" ]; then
    echo 'ebs volume not yet available'
    sleep 10
  else
    break
  fi
done

if [ -z "$${volume_id:-}" ]; then

  volume_id=$(
    aws --cli-connect-timeout 300 ec2 create-volume \
      --availability-zone "$availability_zone" \
      --encrypted \
      --kms-key-id "${ebs_kms_key_arn}" \
      --volume-type "${ebs_volume_type}" \
      --size "${ebs_volume_size}" \
      --iops "${ebs_volume_iops}" \
      --throughput "${ebs_volume_throughput}" \
      --tag-specifications "ResourceType=volume,Tags=[{Key=Name,Value=${name}-graphdb-data}]" | \
      jq -r .VolumeId
  )

  aws --cli-connect-timeout 300 ec2 wait volume-available --volume-ids "$volume_id"
fi

aws --cli-connect-timeout 300 ec2 attach-volume \
  --volume-id "$volume_id" \
  --instance-id "$instance_id" \
  --device "${device_name}"

# Handle the EBS volume used for the GraphDB data directory
# beware, here be dragons...
# read these articles:
# https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/device_naming.html
# https://github.com/oogali/ebs-automatic-nvme-mapping/blob/master/README.md

# this variable comes from terraform, and it's what we specified in the launch template as the device mapping for the ebs
# because this might be attached under a different name, we'll need to search for it
device_mapping_full="${device_name}"
device_mapping_short="$(echo $device_mapping_full | cut -d'/' -f3)"

graphdb_device=""

# the device might not be available immediately, wait a while
for i in $(seq 1 12); do
  for volume in $(find /dev | grep -i 'nvme[0-21]n1$'); do
    # extract the specified device from the vendor-specific data
    # read https://github.com/oogali/ebs-automatic-nvme-mapping/blob/master/README.md, for more information
    real_device=$(nvme id-ctrl --raw-binary $volume | cut -c3073-3104 | tr -s ' ' | sed 's/ $//g')
    if [ "$device_mapping_full" = "$real_device" ] || [ "$device_mapping_short" = "$real_device" ]; then
      graphdb_device="$volume"
      break
    fi
  done

  if [ -n "$graphdb_device" ]; then
    break
  fi
  sleep 5
done

# create a file system if there isn't any
if [ "$graphdb_device: data" = "$(file -s $graphdb_device)" ]; then
  mkfs -t ext4 $graphdb_device
fi

disk_mount_point="/var/opt/graphdb"

# Check if the disk is already mounted
if ! mount | grep -q "$graphdb_device"; then
  echo "The disk at $graphdb_device is not mounted."

  # Create the mount point if it doesn't exist
  if [ ! -d "$disk_mount_point" ]; then
    mkdir -p "$disk_mount_point"
  fi

  # Add an entry to the fstab file to automatically mount the disk
  if ! grep -q "$graphdb_device" /etc/fstab; then
    echo "$graphdb_device $disk_mount_point ext4 defaults 0 2" >> /etc/fstab
  fi

  # Mount the disk
  mount "$disk_mount_point"
  echo "The disk at $graphdb_device is now mounted at $disk_mount_point."
else
  echo "The disk at $graphdb_device is already mounted."
fi

# Ensure data folders exist
mkdir -p $disk_mount_point/node $disk_mount_point/cluster-proxy

# this is needed because after the disc attachment folder owner is reverted
chown -R graphdb:graphdb $disk_mount_point

# Register the instance in Route 53, using the volume id for the sub-domain

subdomain="$( echo -n "$volume_id" | sed 's/^vol-//' )"
node_dns="$subdomain.${zone_dns_name}"

aws --cli-connect-timeout 300 route53 change-resource-record-sets \
  --hosted-zone-id "${zone_id}" \
  --change-batch '{"Changes": [{"Action": "UPSERT","ResourceRecordSet": {"Name": "'"$node_dns"'","Type": "A","TTL": 60,"ResourceRecords": [{"Value": "'"$local_ipv4"'"}]}}]}'

hostnamectl set-hostname "$node_dns"

# Configure GraphDB

aws --cli-connect-timeout 300 ssm get-parameter --region ${region} --name "/${name}/graphdb/license" --with-decryption | \
  jq -r .Parameter.Value | \
  base64 -d > /etc/graphdb/graphdb.license

graphdb_cluster_token="$(aws --cli-connect-timeout 300 ssm get-parameter --region ${region} --name "/${name}/graphdb/cluster_token" --with-decryption | jq -r .Parameter.Value)"

cat << EOF > /etc/graphdb/graphdb.properties
graphdb.auth.token.secret=$graphdb_cluster_token
graphdb.connector.port=7201
graphdb.external-url=http://$${node_dns}:7201/
graphdb.rpc.address=$${node_dns}:7301
EOF

load_balancer_dns=$(aws --cli-connect-timeout 300 ssm get-parameter --region ${region} --name "/${name}/graphdb/lb_dns_name" | jq -r .Parameter.Value)

cat << EOF > /etc/graphdb-cluster-proxy/graphdb.properties
graphdb.auth.token.secret=$graphdb_cluster_token
graphdb.connector.port=7200
graphdb.external-url=http://$${load_balancer_dns}
graphdb.vhosts=http://$${load_balancer_dns},http://$${node_dns}:7200
graphdb.rpc.address=$${node_dns}:7300
graphdb.proxy.hosts=$${node_dns}:7301
EOF

mkdir -p /etc/systemd/system/graphdb.service.d/

cat << EOF > /etc/systemd/system/graphdb.service.d/overrides.conf
[Service]
Environment="GDB_HEAP_SIZE=${jvm_max_memory}g"
EOF

# Configure the GraphDB backup cron job

cat <<-EOF > /usr/bin/graphdb_backup
#!/bin/bash

set -euxo pipefail

GRAPHDB_ADMIN_PASSWORD="\$(aws --cli-connect-timeout 300 ssm get-parameter --region ${region} --name "/${name}/graphdb/admin_password" --with-decryption | jq -r .Parameter.Value)"
NODE_STATE="\$(curl --silent --fail --user "admin:\$GRAPHDB_ADMIN_PASSWORD" localhost:7201/rest/cluster/node/status | jq -r .nodeState)"

if [ "\$NODE_STATE" != "LEADER" ]; then
  echo "current node is not a leader, but \$NODE_STATE"
  exit 0
fi

function trigger_backup {
  local backup_name="\$(date +'%Y-%m-%d_%H-%M-%S').tar"

  curl \
    -vvv --fail \
    --user "admin:\$GRAPHDB_ADMIN_PASSWORD" \
    --url localhost:7201/rest/recovery/cloud-backup \
    --header 'Content-Type: application/json' \
    --header 'Accept: application/json' \
    --data-binary @- <<-DATA
    {
      "backupOptions": { "backupSystemData": true },
      "bucketUri": "s3:///${backup_bucket_name}/\$backup_name?region=${region}"
    }
DATA
}

function rotate_backups {
  all_files="\$(aws --cli-connect-timeout 300 s3api list-objects --bucket ${backup_bucket_name} --query 'Contents' | jq .)"
  count="\$(echo \$all_files | jq length)"
  delete_count="\$((count - ${backup_retention_count} - 1))"

  for i in \$(seq 0 \$delete_count); do
    key="\$(echo \$all_files | jq -r .[\$i].Key)"

    aws --cli-connect-timeout 300 s3 rm s3://${backup_bucket_name}/\$key
  done
}

if ! trigger_backup; then
  echo "failed to create backup"
  exit 1
fi

rotate_backups

EOF

chmod +x /usr/bin/graphdb_backup
echo "${backup_schedule} graphdb /usr/bin/graphdb_backup" > /etc/cron.d/graphdb_backup

# https://docs.aws.amazon.com/elasticloadbalancing/latest/network/network-load-balancers.html#connection-idle-timeout
echo 'net.ipv4.tcp_keepalive_time = 120' | tee -a /etc/sysctl.conf
echo 'fs.file-max = 262144' | tee -a /etc/sysctl.conf

sysctl -p

tmp=$(mktemp)
jq '.logs.metrics_collected.prometheus.log_group_name = "${resource_name_prefix}-graphdb"' /etc/graphdb/cloudwatch-agent-config.json > "$tmp" && mv "$tmp" /etc/graphdb/cloudwatch-agent-config.json
jq '.logs.metrics_collected.prometheus.emf_processor.metric_namespace = "${resource_name_prefix}-graphdb"' /etc/graphdb/cloudwatch-agent-config.json > "$tmp" && mv "$tmp" /etc/graphdb/cloudwatch-agent-config.json
cat /etc/prometheus/prometheus.yaml | yq '.scrape_configs[].static_configs[].targets = ["localhost:7201"]' > "$tmp" && mv "$tmp" /etc/prometheus/prometheus.yaml

amazon-cloudwatch-agent-ctl -a start
amazon-cloudwatch-agent-ctl -a fetch-config -m ec2 -s -c file:/etc/graphdb/cloudwatch-agent-config.json

# the proxy service is set up in the AMI but not enabled there, so we enable and start it
systemctl daemon-reload
systemctl start graphdb
systemctl enable graphdb-cluster-proxy.service
systemctl start graphdb-cluster-proxy.service

# Setup GraphDB Cluster
RETRY_DELAY=1
MAX_RETRIES=10

# Checks if GraphDB is started, we assume it is when the infrastructure endpoint is reached
check_gdb() {
  if [ -z "$1" ]; then
    echo "Error: IP address or hostname is not provided."
    return 1
  fi

  local gdb_address="$1:7200/rest/monitor/infrastructure"
  if curl -s --head -u "admin:\${GRAPHDB_ADMIN_PASSWORD}" --fail "\${gdb_address}" >/dev/null; then
    echo "Success, GraphDB node \${gdb_address} is available"
    return 0
  else
    echo "GraphDB node \${gdb_address} is not available yet"
    return 1
  fi
}

VPC_ID=$(aws ec2 describe-instances --instance-id \$instance_id --query 'Reservations[0].Instances[0].VpcId' --output text)
DNS_JSON=$(aws ec2 describe-instances --filters "Name=vpc-id,Values=\$VPC_ID" --query 'Reservations[*].Instances[*].[PrivateDnsName]')
ALL_DNS_RECORDS=($(echo "\$DNS_JSON" | jq -r '.[][][]'))
ALL_DNS_RECORDS_COUNT="\${#ALL_DNS_RECORDS[@]}"

# Waits for 3 DNS records to be available
wait_dns_records() {
  if [ "\${ALL_DNS_RECORDS_COUNT}" -ne 3 ]; then
    sleep 5
    wait_dns_records
  else
    echo "Private DNS zone record count is \${ALL_DNS_RECORDS_COUNT}"
  fi
}

wait_dns_records

# Check all instances are running
for record in "${ALL_DNS_RECORDS[@]}"; do
  echo "Pinging $record"
  # Removes the '.' at the end of the DNS address
  if [ -n "$record" ]; then
    while ! check_gdb "$record"; do
      echo "Waiting for GDB $record to start"
      sleep "$RETRY_DELAY"
    done
  else
    echo "Error: address is empty."
  fi
done

echo "All GDB instances are available. Creating the cluster."

INSTANCE_IDS_JSON=$(aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC_ID" --query 'Reservations[*].Instances[*].[InstanceId]')
INSTANCE_IDS=($(echo "$INSTANCE_IDS_JSON" | jq -r '.[][][]' | sort))
echo $INSTANCE_IDS
LOWEST_INSTANCE_ID=${INSTANCE_IDS[0]}
MIDDLE_INSTANCE_ID=${INSTANCE_IDS[1]}
HIGHEST_INSTANCE_ID=${INSTANCE_IDS[2]}

echo $LOWEST_INSTANCE_ID
echo $MIDDLE_INSTANCE_ID
echo $HIGHEST_INSTANCE_ID

echo "Volumes: ${volume_id[@]}"
