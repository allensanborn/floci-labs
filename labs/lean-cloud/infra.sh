#!/usr/bin/env bash
# infra.sh — lean-cloud's own AWS provisioning (deploy/aws.sh + its OpenTofu root:
# VPC, IAM, EKS cluster/node group/add-ons/pod identity, ECR, S3) against Floci.
#
# Every command below is lean-cloud's helper, unmodified. The only redirection is an
# AWS CLI profile whose endpoint_url is Floci; OpenTofu's AWS provider and kubectl's
# `aws eks get-token` both honour it. AWS config lives in .work/aws, not ~/.aws.
set -euo pipefail
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENDPOINT=${AWS_ENDPOINT_URL:-http://localhost:4566}
NAME=${LEAN_CLOUD_CLUSTER:-floci-lab}
INFRA=$PWD/.work/aws-infra
AWS_SH=.work/lean-cloud/deploy/aws.sh
KUBE_SH=.work/lean-cloud/deploy/kubernetes.sh

say() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32mok\033[0m  %s\n' "$*"; }
gap() { printf '\033[1;33mgap\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }

[ -x "$AWS_SH" ] || die "lean-cloud checkout missing — run ./build.sh first"
curl -fsS "$ENDPOINT/_floci/health" >/dev/null || die "Floci is not answering at $ENDPOINT"
ok "Floci $(curl -fsS "$ENDPOINT/_floci/health" | jq -r .version) at $ENDPOINT"

# A profile named lean-cloud, aws.sh's default. Unset any ambient endpoint so the
# profile is the only redirection in play.
unset AWS_ENDPOINT_URL AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
mkdir -p .work/aws
export AWS_CONFIG_FILE=$PWD/.work/aws/config AWS_SHARED_CREDENTIALS_FILE=$PWD/.work/aws/credentials AWS_PAGER=
printf '[profile lean-cloud]\nregion = us-east-1\nendpoint_url = %s\n' "$ENDPOINT" > "$AWS_CONFIG_FILE"

# Floci's EKS token webhook verifies `aws eks get-token` signatures against keys it
# issued, so the blanket test/test key gets no kubectl access. Mint a real IAM key.
printf '[lean-cloud]\naws_access_key_id = test\naws_secret_access_key = test\n' > "$AWS_SHARED_CREDENTIALS_FILE"
aws iam get-user --profile lean-cloud --user-name lean-cloud-admin >/dev/null 2>&1 ||
  aws iam create-user --profile lean-cloud --user-name lean-cloud-admin >/dev/null
# IAM allows two keys per user, so a rerun retires the previous run's keys first.
for old in $(aws iam list-access-keys --profile lean-cloud --user-name lean-cloud-admin \
    --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
  aws iam delete-access-key --profile lean-cloud --user-name lean-cloud-admin --access-key-id "$old"
done
key=$(aws iam create-access-key --profile lean-cloud --user-name lean-cloud-admin --output json)
printf '[lean-cloud]\naws_access_key_id = %s\naws_secret_access_key = %s\n' \
  "$(jq -r .AccessKey.AccessKeyId <<<"$key")" "$(jq -r .AccessKey.SecretAccessKey <<<"$key")" > "$AWS_SHARED_CREDENTIALS_FILE"
ok "profile lean-cloud -> $ENDPOINT as IAM user lean-cloud-admin"

if [ -f "$INFRA/terraform.tfstate" ] && [ -n "$(tofu -chdir="$INFRA" state list 2>/dev/null)" ]; then
  say "0. destroying what an earlier run left"
  "$AWS_SH" destroy-plan "$INFRA" >/dev/null && "$AWS_SH" destroy "$INFRA" >/dev/null
fi
rm -rf "$INFRA"

say "1. aws.sh init"
set +e; "$AWS_SH" init "$INFRA" --name "$NAME" --admin-cidr 203.0.113.10/32 > .work/init.log 2>&1; rc=$?; set -e
if [ "$rc" = 0 ]; then
  ok "init: $(jq -c '{machine_size,architecture,worker_zone,kubernetes_version}' "$INFRA/aws.tfvars.json")"
else
  # init reads instance-type architecture, zone offerings and EKS versions from the
  # API. Where Floci cannot answer, write the same file init would have written.
  msg=$(tail -1 .work/init.log)
  gap "init could not run on this Floci (exit $rc) ${msg:+— $msg}"
  aws eks describe-cluster-versions --profile lean-cloud >/dev/null 2>&1 ||
    gap "  eks describe-cluster-versions is not implemented"
  [ "$(aws ec2 describe-instance-types --profile lean-cloud --instance-types m7g.large --query 'length(InstanceTypes)' 2>/dev/null)" = 1 ] ||
    gap "  ec2 describe-instance-types does not know m7g.large"
  rm -rf "$INFRA"; mkdir -p "$INFRA"; chmod 700 "$INFRA"
  jq -n --arg name "$NAME" '{name:$name,account:"000000000000",profile:"lean-cloud",region:"us-east-1",machines:1,
    machine_size:"m7g.large",architecture:"arm64",worker_zone:"us-east-1a",os_disk_size_gb:32,
    kubernetes_version:"1.33",administrator_cidrs:["203.0.113.10/32"],namespace:"lean-cloud"}' > "$INFRA/aws.tfvars.json"
  ok "wrote the aws.tfvars.json init would have written"
fi

say "2. aws.sh plan + create (OpenTofu apply, kubeconfig, StorageClass)"
"$AWS_SH" plan "$INFRA" > .work/plan.log 2>&1 || { tail -20 .work/plan.log; die "plan failed"; }
log() { sed 's/\x1b\[[0-9;]*m//g' "$1" | grep -E "$2" | sed 's/^/  /' || true; }
log .work/plan.log '^Plan:'
"$AWS_SH" create "$INFRA" > .work/create.log 2>&1 || { tail -20 .work/create.log; die "create failed"; }
log .work/create.log 'Apply complete|Saved Kubernetes|storageclass|ready'
ok "cluster $(aws eks describe-cluster --profile lean-cloud --name "$NAME" --query cluster.status --output text), outputs in .work/aws-infra/cloud.json"

say "3. the cluster behind it"
kubectl --kubeconfig "$INFRA/kubeconfig" get nodes --no-headers | awk '{print "  node " $1 " " $2 " " $5}'
kubectl --kubeconfig "$INFRA/kubeconfig" get storageclass --no-headers \
  -o custom-columns=N:.metadata.name,P:.provisioner | awk '{print "  storageclass " $1 " (" $2 ")"}'
aws eks list-addons --profile lean-cloud --cluster-name "$NAME" --query addons --output text | tr '\t' '\n' | sed 's/^/  addon /'
aws eks list-pod-identity-associations --profile lean-cloud --cluster-name "$NAME" \
  --query 'associations[].[namespace,serviceAccount]' --output text | awk '{print "  pod identity " $1 "/" $2}'

say "4. lean-cloud's nodes as pods in the cluster"
kubectl --kubeconfig "$INFRA/kubeconfig" get storageclass local-path >/dev/null 2>&1 ||
  die "no local-path StorageClass: start Floci with FLOCI_SERVICES_EKS_DEFAULT_STORAGE_CLASS=true (docker-compose.yml does)"
DEPLOY=$PWD/.work/aws-deployment
rm -rf "$DEPLOY"
# aws.sh publish pushes to the repositoryUri, <acct>.dkr.ecr.<region>.localhost:<port>/<repo>.
# A Docker 29+ daemon with the containerd image store speaks only HTTPS to that name, so
# push the same repository through the path-style alias Floci serves on localhost.
repo=$(jq -er .repository "$INFRA/cloud.json"); port=${ENDPOINT##*:}
alias_ref="localhost:$port/000000000000/us-east-1/${repo#*/}:lab-v1"
aws ecr get-login-password --profile lean-cloud | docker login -u AWS --password-stdin "localhost:$port" >/dev/null 2>&1
docker tag lean-cloud-demo:floci "$alias_ref"
docker push -q "$alias_ref" > .work/push.log 2>&1 || { tail -3 .work/push.log
  die "docker push to Floci's ECR failed. Floci 2.4.0 answers 503 here; use a build with floci-io/floci#7224 (nightly-11012026 or later)"; }
ok "pushed lean-cloud-demo:floci to ${repo}:lab-v1"
"$AWS_SH" configure "$INFRA" "$DEPLOY" lab-v1 3 > .work/configure.log 2>&1 || { tail -5 .work/configure.log; die "configure failed"; }
ok "aws.sh configure pinned $(jq -r .image "$DEPLOY/deployment.json" | sed 's/.*@/image @/')"
# The two settings aws.sh's docs say to review before the first up. Floci's EBS CSI
# add-on is metadata, so disks come from k3s's local-path provisioner; pods reach S3 at
# Floci's address on the cluster's VPC network, with keys instead of pod identity.
node=$(kubectl --kubeconfig "$INFRA/kubeconfig" get nodes -o jsonpath='{.items[0].metadata.name}')
vpcnet=$(docker network ls --format '{{.Name}}' | grep -- "-vpc-$(jq -r .vpcId "$INFRA/cloud.json" | sed 's/^vpc-//')" | head -1)
floci_ip=$(docker network inspect "$vpcnet" -f '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}' |
  grep -v -- '-eks-' | awk 'NF {sub(/\/.*/, "", $2); print $2; exit}')
[ -n "$floci_ip" ] || die "could not find Floci on the cluster's VPC network ($vpcnet)"
jq '.storageClass="local-path"' "$DEPLOY/deployment.json" > "$DEPLOY/d.next" && mv -f "$DEPLOY/d.next" "$DEPLOY/deployment.json"
jq --arg e "http://$floci_ip:4566" '.endpoint=$e | .authentication={kind:"keys",accessKey:"test",secretKey:"test"}' \
  "$DEPLOY/storage.json" > "$DEPLOY/s.next" && mv -f "$DEPLOY/s.next" "$DEPLOY/storage.json"
chmod 600 "$DEPLOY"/*.json
ok "storageClass local-path; blobs at http://$floci_ip:4566 (Floci on $vpcnet)"
"$KUBE_SH" render "$DEPLOY" >/dev/null
"$KUBE_SH" up "$DEPLOY" > .work/up.log 2>&1 || { tail -10 .work/up.log; die "kubernetes.sh up failed"; }
kubectl --kubeconfig "$INFRA/kubeconfig" -n lean-cloud get pods --no-headers | awk '{print "  pod " $1 " " $3 " on '"$node"'"}'

say "5. log-summary, run in the cluster"
"$KUBE_SH" connect "$DEPLOY" 18090 > .work/connect.log 2>&1 &
tunnel=$!
trap 'kill $tunnel 2>/dev/null' EXIT
deployment=$(jq -r .name "$DEPLOY/deployment.json"); token=$(cat "$DEPLOY/client.token")
api() { curl -fsS -H "Authorization: Bearer $token" localhost:18090/deployment \
  -d "{\"protocolVersion\":1,\"apiVersion\":1,\"deployment\":\"$deployment\",\"request\":$1}"; }
for _ in $(seq 1 30); do api '"describe"' >/dev/null 2>&1 && break; sleep 1; done
sample=$(api '"programs"' | jq -c '.result.ok[] | select(.entry=="log-summary/v1").sampleInput')
api "{\"submit\":{\"id\":\"eks-logs\",\"entry\":\"log-summary/v1\",\"input\":$sample}}" >/dev/null
out=
for _ in $(seq 1 120); do
  out=$(api '{"result":{"id":"eks-logs"}}' | jq -r '.result.ok // empty'); [ -n "$out" ] && break; sleep 1
done
[ "$out" = "files=16, errors=24" ] || die "log-summary in the cluster returned '$out'"
ok "log-summary in Floci's EKS: $out"
kill $tunnel 2>/dev/null; wait $tunnel 2>/dev/null || true; trap - EXIT
"$KUBE_SH" clean "$DEPLOY" --yes > .work/clean.log 2>&1 || { tail -5 .work/clean.log; die "kubernetes.sh clean failed"; }
log .work/clean.log 'Removed namespace'

say "6. a second plan: does Floci read back what it was given?"
set +e
tofu -chdir="$INFRA" plan -detailed-exitcode -no-color -input=false > .work/drift.log 2>&1; rc=$?
set -e
drift=$(grep -E '^  # .* will be' .work/drift.log | sed -E 's/^  # ([^ ]+) .*/\1/' | sort -u | tr '\n' ' ')
case "$rc" in
  0) ok "no drift" ;;
  2) if [ "$drift" = "aws_eks_cluster.cloud " ] && grep -q 'upgrade_policy' .work/drift.log; then
       gap "drift on aws_eks_cluster.cloud upgrade_policy only (floci-io/floci#5640)"
     else
       grep -E '^\s+[~+-] ' .work/drift.log | head -20; die "unexpected drift: $drift"
     fi ;;
  *) tail -20 .work/drift.log; die "second plan failed" ;;
esac

say "7. aws.sh destroy-plan + destroy"
"$AWS_SH" destroy-plan "$INFRA" > .work/destroy-plan.log 2>&1 || { tail -20 .work/destroy-plan.log; die "destroy-plan failed"; }
"$AWS_SH" destroy "$INFRA" > .work/destroy.log 2>&1 || { tail -20 .work/destroy.log; die "destroy failed"; }
log .work/destroy.log 'Destroy complete|Apply complete|AWS infrastructure removed'
echo
printf '\033[1;32mlean-cloud provisions and tears down its AWS stack on Floci.\033[0m\n'
