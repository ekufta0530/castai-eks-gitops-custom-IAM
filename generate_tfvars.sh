#!/usr/bin/env bash
# Generates tf.vars from a cluster name + AWS profile.
#
# Usage:
#   ./generate_tfvars.sh <cluster-name> [--region <region>] [--profile <profile>] [--output <file>]
#
# Examples:
#   ./generate_tfvars.sh my-cluster
#   ./generate_tfvars.sh my-cluster --region us-east-1 --profile prod
#   ./generate_tfvars.sh my-cluster --output tf.vars
#   CASTAI_API_TOKEN=xxx ./generate_tfvars.sh my-cluster --output tf.vars

set -euo pipefail

# ── Argument parsing ──────────────────────────────────────────────────────────
CLUSTER_NAME=""
REGION=""
PROFILE="${AWS_PROFILE:-default}"
OUTPUT=""

usage() {
  echo "Usage: $0 <cluster-name> [--region <region>] [--profile <profile>] [--output <file>]"
  exit 1
}

[[ $# -eq 0 ]] && usage

CLUSTER_NAME="$1"; shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region)  REGION="$2";  shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    --output)  OUTPUT="$2";  shift 2 ;;
    *) echo "Unknown argument: $1"; usage ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
info()  { echo "  $*" >&2; }
step()  { echo "" >&2; echo "▸ $*" >&2; }
warn()  { echo "  [warn] $*" >&2; }
die()   { echo "  [error] $*" >&2; exit 1; }

check_deps() {
  for cmd in aws jq; do
    command -v "$cmd" &>/dev/null || die "'$cmd' is required but not installed."
  done
}

# ── Resolve region ────────────────────────────────────────────────────────────
resolve_region() {
  if [[ -n "$REGION" ]]; then return; fi
  REGION=$(aws configure get region --profile "$PROFILE" 2>/dev/null || true)
  if [[ -z "$REGION" ]]; then
    die "Region not set. Pass --region or configure it in profile '$PROFILE'."
  fi
}

# ── AWS helpers ───────────────────────────────────────────────────────────────
aws_() { aws --profile "$PROFILE" --region "$REGION" "$@"; }

get_node_sg() {
  local cluster_sg="$1"
  local node_sg=""

  # Strategy 1: check each managed nodegroup for a remote access SG
  local nodegroups
  nodegroups=$(aws_ eks list-nodegroups --cluster-name "$CLUSTER_NAME" \
    --query 'nodegroups[]' --output text 2>/dev/null || true)

  for ng in $nodegroups; do
    local sg
    sg=$(aws_ eks describe-nodegroup \
      --cluster-name "$CLUSTER_NAME" --nodegroup-name "$ng" \
      --query 'nodegroup.resources.remoteAccessSecurityGroup' --output text 2>/dev/null || true)
    if [[ -n "$sg" && "$sg" != "None" && "$sg" != "null" ]]; then
      node_sg="$sg"
      break
    fi
  done

  # Strategy 2: look at running worker nodes — take the first SG that isn't the cluster SG
  if [[ -z "$node_sg" ]]; then
    node_sg=$(aws_ ec2 describe-instances \
      --filters \
        "Name=tag:kubernetes.io/cluster/${CLUSTER_NAME},Values=owned" \
        "Name=instance-state-name,Values=running" \
      --query "Reservations[0].Instances[0].SecurityGroups[?GroupId!='${cluster_sg}'].GroupId | [0]" \
      --output text 2>/dev/null || true)
    [[ "$node_sg" == "None" || "$node_sg" == "null" ]] && node_sg=""
  fi

  echo "$node_sg"
}

get_azs() {
  local subnets_json="$1"
  # Get unique AZs for the subnets
  local subnet_ids
  subnet_ids=$(echo "$subnets_json" | jq -r '.[]')
  if [[ -z "$subnet_ids" ]]; then echo "[]"; return; fi

  local az_list
  az_list=$(aws_ ec2 describe-subnets \
    --subnet-ids $subnet_ids \
    --query 'Subnets[].AvailabilityZone' --output json 2>/dev/null \
    | jq -r 'unique | .[]' 2>/dev/null || true)

  if [[ -z "$az_list" ]]; then echo "[]"; return; fi

  local hcl_azs
  hcl_azs=$(echo "$az_list" | awk '{printf "  \"%s\",\n", $1}')
  printf "[\n%s]" "$hcl_azs"
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  check_deps
  resolve_region

  echo "" >&2
  echo "Generating tf.vars for cluster: $CLUSTER_NAME" >&2
  echo "  profile : $PROFILE" >&2
  echo "  region  : $REGION" >&2

  # ── CAST AI token ──────────────────────────────────────────────────────────
  local castai_token="${CASTAI_API_TOKEN:-}"
  if [[ -z "$castai_token" ]]; then
    read -rsp "CAST AI API token (input hidden): " castai_token
    echo "" >&2
    [[ -z "$castai_token" ]] && die "CAST AI API token is required."
  fi

  # ── Account ID ────────────────────────────────────────────────────────────
  step "Fetching account ID"
  local account_id
  account_id=$(aws_ sts get-caller-identity --query Account --output text)
  info "account_id = $account_id"

  # ── Cluster details ────────────────────────────────────────────────────────
  step "Fetching EKS cluster details"
  local cluster_json
  cluster_json=$(aws_ eks describe-cluster --name "$CLUSTER_NAME" --query cluster --output json) \
    || die "Could not describe cluster '$CLUSTER_NAME'. Check the name, region, and profile."

  local vpc_id cluster_sg subnets_json
  vpc_id=$(echo "$cluster_json" | jq -r '.resourcesVpcConfig.vpcId')
  cluster_sg=$(echo "$cluster_json" | jq -r '.resourcesVpcConfig.clusterSecurityGroupId')
  subnets_json=$(echo "$cluster_json" | jq -c '.resourcesVpcConfig.subnetIds')
  info "vpc_id             = $vpc_id"
  info "cluster_sg         = $cluster_sg"
  info "subnets            = $(echo "$subnets_json" | jq -r '. | length') found"

  # ── Node security group ────────────────────────────────────────────────────
  step "Detecting node security group"
  local node_sg
  node_sg=$(get_node_sg "$cluster_sg")
  if [[ -n "$node_sg" ]]; then
    info "node_sg            = $node_sg"
  else
    warn "Could not auto-detect node security group — placeholder written, update manually."
    node_sg="# TODO: set node security group ID"
  fi

  # ── Availability zones ────────────────────────────────────────────────────
  step "Resolving availability zones"
  local azs_hcl
  azs_hcl=$(get_azs "$subnets_json")
  info "azs                = $azs_hcl"

  # ── Format subnets as HCL list ─────────────────────────────────────────────
  local subnets_hcl
  subnets_hcl=$(echo "$subnets_json" | jq -r '.[]' | awk '{printf "  \"%s\",\n", $1}')

  # ── Render output ──────────────────────────────────────────────────────────
  local content
  content=$(cat <<EOF
castai_api_token          = "$castai_token"
aws_account_id            = "$account_id"
aws_cluster_region        = "$REGION"
aws_cluster_name          = "$CLUSTER_NAME"
profile                   = "$PROFILE"

vpc_id                    = "$vpc_id"
cluster_security_group_id = "$cluster_sg"
node_security_group_id    = "$node_sg"

subnets = [
$subnets_hcl]

azs = $azs_hcl
EOF
)

  if [[ -n "$OUTPUT" ]]; then
    if [[ -f "$OUTPUT" ]]; then
      cp "$OUTPUT" "${OUTPUT}.bak"
      info "Backed up existing $OUTPUT → ${OUTPUT}.bak"
    fi
    echo "$content" > "$OUTPUT"
    echo "" >&2
    echo "Written to $OUTPUT" >&2
  else
    echo "" >&2
    echo "──────────────────────────────────────" >&2
    echo "$content"
  fi
}

main
