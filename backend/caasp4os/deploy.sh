#!/usr/bin/env bash


# Deploys Caasp4 cluster on openstack, with an nfs server
# Requires:
# - Built skuba docker image
# - Sourced openrc.sh
# - Key on the ssh keyring. If not, will put one

. ./defaults.sh
. ../../include/common.sh
. .envrc

# nip.io doesn't seem to work well with ECP, use omg.h.w instead:
export MAGICDNS=omg.howdoi.website

# Create STACK var for terraform, and for the node names in lib/skuba.sh:
STACK=${STACK:-"${OWNER}-caasp4-${CAASP_VER::3}-${CLUSTER_NAME}"}
# shellcheck disable=SC1090
. "$ROOT_DIR"/backend/caasp4os/lib/skuba.sh

if [[ ! -v OS_PASSWORD ]]; then
    err "Missing openstack credentials" && exit 1
fi

info "Extracting terraform files from skuba/$CAASP_VER image…"

# Add ssh key if not present, needed for terraform
if ! ssh-add -L | grep -q 'ssh' ; then
    if [[ $(pgrep ssh-agent -u "$USER") ]]; then
        eval "$(ssh-agent -s)"
    fi
    curl "https://raw.githubusercontent.com/SUSE/skuba/master/ci/infra/id_shared" -o id_rsa_shared \
        && chmod 0600 id_rsa_shared
    ssh-add id_rsa_shared
fi

# Extract upstream caasp terraform files
docker run \
       --name skuba-"$CAASP_VER" \
       --detach \
       --rm \
       skuba/"$CAASP_VER" sleep infinity
docker cp \
       skuba-"$CAASP_VER":/usr/share/caasp/terraform/openstack/. \
       deployment
docker rm -f skuba-"$CAASP_VER"

info "Injecting CAP terraform files…"

case "$CAASP_VER" in
    "devel")
        CAASP_REPO='caasp_45_devel_sle15sp2 = "http://ibs-mirror.prv.suse.net/ibs/Devel:/CaaSP:/4.5/SLE_15_SP2/"'
         ;;
    "staging")
        CAASP_REPO='caasp_45_staging_sle15sp2 = "http://ibs-mirror.prv.SUSE.net/ibs/SUSE:/SLE-15-SP2:/Update:/Products:/CASP45/staging/"'
         ;;
    "product")
         # Already on terraform.tfvars
         CAASP_REPO=
         ;;
    "update")
        CAASP_REPO='caasp_45_update_sle15sp2 = "http://ibs-mirror.prv.suse.net/ibs/SUSE/Updates/SUSE-CAASP/4.5/x86_64/update/"',
         ;;
esac
escapeSubst() {
    # escape string for usage in a sed substitution expression
    IFS= read -d '' -r < <(sed -e ':a' -e '$!{N;ba' -e '}' -e 's%[&/\]%\\&%g; s%\n%\\&%g' <<<"$1")
    printf %s "${REPLY%$'\n'}"
}
# save only first ssh key, caasp4 terraform script constraints:
SSHKEY="$(ssh-add -L | head -n 1)"
sed -e "s%#~placeholder_stack~#%$(escapeSubst "$STACK")%g" \
    -e "s%#~placeholder_magic_dns~#%$(escapeSubst "$MAGICDNS")%g" \
    -e "s%#~placeholder_caasp_repo~#%$(escapeSubst "$CAASP_REPO")%g" \
    -e "s%#~placeholder_sshkey~#%$(escapeSubst "$SSHKEY")%g" \
    "$ROOT_DIR"/backend/caasp4os/terraform-os/terraform.tfvars.skel > \
    deployment/terraform.tfvars
# enable cpi
sed -i '/cpi_enable/s/^#//g' deployment/cpi.auto.tfvars
# inject our terraform files
cp -rf "$ROOT_DIR"/backend/caasp4os/terraform-os/* deployment/

pushd deployment || exit

info "Deploying infrastructure with terraform…"

skuba_container terraform init
skuba_container terraform plan -out my-plan
skuba_container terraform apply -auto-approve my-plan

info "Bootstrapping k8s with skuba…"

skuba_container skuba version
skuba_init
# inject cloud/openstack.conf for cpi
cp openstack.conf my-cluster/cloud/openstack/openstack.conf

skuba_deploy
wait
cp -f ./my-cluster/admin.conf ../kubeconfig

info "Disabling node updates…"
skuba_updates all disable
wait

# reboots commented, no updates to trigger them
# info "Disabling node reboots …"
# skuba_reboots disable
# wait

info "Raising pid_limits for crio…"
skuba_raise_pid_limit all
wait

# Create k8s configmap
PUBLIC_IP="$(skuba_container terraform output -json | jq -r '.ip_load_balancer.value|to_entries|map(.value)|first')"
ROOTFS=overlay-xfs
DOMAIN="$PUBLIC_IP"."$MAGICDNS"

if ! kubectl get configmap -n kube-system 2>/dev/null | grep -qi cap-values; then
    kubectl create configmap -n kube-system cap-values \
            --from-literal=public-ip="${PUBLIC_IP}" \
            --from-literal=services="hardcoded" \
            --from-literal=domain="${DOMAIN}" \
            --from-literal=garden-rootfs-driver="${ROOTFS}" \
            --from-literal=platform=caasp4
fi
ok "CaaSP4 on Openstack succesfully deployed!"
