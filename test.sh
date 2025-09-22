[acabralreyes@ip-10-255-2-48 ~]$ ./AMI_script.sh
=== Instances in region: us-west-1 ===
------------------------------------------------------------------------
|                           DescribeInstances                          |
+------------+-----------------------+----------------------+----------+
|     AZ     |          Id           |        Name          |  State   |
+------------+-----------------------+----------------------+----------+
|  us-west-1a|  i-01730f3f5b17cb099  |  bastion-instance-2  |  running |
|  us-west-1c|  i-0a199f7f7ed54bc60  |  private-instance-2  |  running |
+------------+-----------------------+----------------------+----------+

Enter AMI name for instance 'i-0a20f2af6087a9fa1	bastion-instance-2' (i-0a20f2af6087a9fa1) in us-west-1: Bastion AMI Test 1 
Creating AMI 'Bastion AMI Test 1' from i-0a20f2af6087a9fa1 (no reboot) in us-west-1...

An error occurred (InvalidParameterValue) when calling the CreateImage operation: Tag keys starting with 'aws:' are reserved for internal use
[acabralreyes@ip-10-255-2-48 ~]$ vi AMI_script.sh


















#!/usr/bin/env bash
set -euo pipefail

# Requires: aws CLI v2, jq
# Usage: export AWS_PROFILE=yourprofile; export AWS_REGION=us-east-1; ./make-instance-amis.sh
# Tip: set ALL_REGIONS=1 to process all regions in the account.

ALL_REGIONS="${ALL_REGIONS:-0}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing dependency: $1" >&2; exit 1; }; }
need aws
need jq

get_regions() {
  if [[ "$ALL_REGIONS" == "1" ]]; then
    aws ec2 describe-regions --all-regions --query 'Regions[].RegionName' --output text | tr '\t' '\n'
  else
    # Use current/default region
    echo "${AWS_REGION:-$(aws configure get region || true)}"
  fi
}

image_exists() {
  local region="$1" name="$2"
  aws ec2 describe-images \
    --owners self \
    --filters "Name=name,Values=${name}" \
    --query 'Images[0].ImageId' \
    --output text \
    --region "$region"
}

next_available_name() {
  local region="$1" base="$2"
  local candidate="$base"
  local n=2
  local exists
  exists="$(image_exists "$region" "$candidate")"
  while [[ "$exists" != "None" && "$exists" != "null" ]]; do
    candidate="${base}_$n"
    exists="$(image_exists "$region" "$candidate")"
    ((n++))
  done
  echo "$candidate"
}

deregister_image() {
  local region="$1" image_id="$2"
  echo "Deregistering existing AMI $image_id in $region..."
  aws ec2 deregister-image --image-id "$image_id" --region "$region" >/dev/null
  echo "Deregistered $image_id."
}

create_image_for_instance() {
  local region="$1" instance_id="$2" inst_name="$3"

  # Ask for AMI name
  local ami_name
  read -rp "Enter AMI name for instance '${inst_name}' (${instance_id}) in ${region}: " ami_name
  if [[ -z "$ami_name" ]]; then
    echo "Skipping ${instance_id}: AMI name cannot be empty."
    return
  fi

  local existing_id
  existing_id="$(image_exists "$region" "$ami_name")"

  if [[ "$existing_id" != "None" && "$existing_id" != "null" ]]; then
    echo "An AMI named '$ami_name' already exists (ImageId: $existing_id)."
    read -rp "Do you want to overwrite it? (y/N): " answer
    answer="${answer:-N}"
    if [[ "$answer" =~ ^[Yy]$ ]]; then
      echo "NOTE: Overwriting will deregister the existing AMI. Its snapshots are NOT deleted by this script."
      deregister_image "$region" "$existing_id"
      final_name="$ami_name"
    else
      final_name="$(next_available_name "$region" "$ami_name")"
      echo "Using next available name: $final_name"
    fi
  else
    final_name="$ami_name"
  fi

  # Optional: copy Name/other tags from instance to the AMI
  # Gather instance tags into TagSpecifications format
  local tag_json
    # Get instance tags and sanitize:
  tag_json="$(aws ec2 describe-instances \
    --instance-ids "$instance_id" \
    --region "$region" \
    --query 'Reservations[0].Instances[0].Tags' \
    --output json)"

  # Merge tags:
  # - remove any tag whose Key starts with "aws:"
  # - remove existing Name (we’ll set it to the AMI name)
  # - add Name=<final_name>
  merged_tags="$(jq -c --arg name "$final_name" '
      (map(select((.Key|startswith("aws:"))|not) | select(.Key != "Name"))
       + [{"Key":"Name","Value":$name}]) // [{"Key":"Name","Value":$name}]
    ' <<<"$tag_json")"

  # Proper JSON for --tag-specifications (NOT shorthand)
  tag_spec='[{"ResourceType":"image","Tags":'"$merged_tags"'}]'

  desc="Backup of instance ${inst_name:-$instance_id} created on $(date -u +'%Y-%m-%dT%H:%M:%SZ')"

  echo "Creating AMI '$final_name' from ${instance_id} (no reboot) in ${region}..."
  if [[ "$merged_tags" != "[]" ]]; then
    image_id="$(aws ec2 create-image \
      --instance-id "$instance_id" \
      --name "$final_name" \
      --description "$desc" \
      --no-reboot \
      --tag-specifications "$tag_spec" \
      --query 'ImageId' \
      --output text \
      --region "$region")"
  else
    # If no tags survived sanitization, create the AMI and tag afterwards.
    image_id="$(aws ec2 create-image \
      --instance-id "$instance_id" \
      --name "$final_name" \
      --description "$desc" \
      --no-reboot \
      --query 'ImageId' \
      --output text \
      --region "$region")"

    aws ec2 create-tags \
      --resources "$image_id" \
      --tags "Key=Name,Value=$final_name" \
      --region "$region"
  fi

  echo "AMI creation started: $image_id  (region: $region)"

}

list_instances() {
  local region="$1"
  echo "=== Instances in region: $region ==="
  aws ec2 describe-instances \
    --region "$region" \
    --filters "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].{Id:InstanceId,Name:Tags[?Key==`Name`]|[0].Value,State:State.Name,AZ:Placement.AvailabilityZone}' \
    --output table
  echo
}

main() {
  local regions
  regions="$(get_regions)"
  if [[ -z "$regions" ]]; then
    echo "No region configured. Set AWS_REGION or enable ALL_REGIONS=1." >&2
    exit 1
  fi

  for region in $regions; do
    [[ -z "$region" || "$region" == "None" ]] && continue

    list_instances "$region"

    # Collect instance IDs and names
    mapfile -t rows < <(aws ec2 describe-instances \
      --region "$region" \
      --query 'Reservations[].Instances[].[InstanceId, Tags[?Key==`Name`]|[0].Value]' \
      --output text)

    if [[ ${#rows[@]} -eq 0 ]]; then
      echo "No instances found in $region."
      continue
    fi

    for row in "${rows[@]}"; do
      instance_id="$(awk '{print $1}' <<<"$row")"
      inst_name="$(cut -d' ' -f2- <<<"$row" || true)"
      # Handle instances with no Name tag (inst_name may be empty)
      [[ -z "${inst_name// }" || "$inst_name" == "None" ]] && inst_name="(no-Name-tag)"
      create_image_for_instance "$region" "$instance_id" "$inst_name"
      echo
    done
  done

  echo "All done."
}

main "$@"

