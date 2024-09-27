#!/usr/bin/env bash

# Functions to interact with a container that includes the client caasp4
# binaries and terraform

# to test this by hand:
# $> export CLUSTER_NAME=caasp4os; source backend/caasp4os/defaults.sh; source backend/caasp4os/lib/skuba.sh
# $> skuba_container skuba version

SKUBA_CLUSTER_NAME="my-cluster"

_set_env_vars() {
    JSON=$(skuba_container terraform output -json)
    LB="$(echo "$JSON" | jq -r '.ip_load_balancer.value|to_entries|map(.value)|@tsv')"
    export LB
    MASTERS="$(echo "$JSON" | jq -r '.ip_masters.value|to_entries|map(.value)|@tsv')"
    export MASTERS
    WORKERS="$(echo "$JSON" | jq -r '.ip_workers.value|to_entries|map(.value)|@tsv')"
    export WORKERS
    ALL="$MASTERS $WORKERS"
    export ALL
}

_define_node_group() {
    _set_env_vars
    case "$1" in
        "all")
            GROUP="$ALL"
            ;;
        "masters")
            GROUP="$MASTERS"
            ;;
        "workers")
            GROUP="$WORKERS"
            ;;
        *)
            GROUP="$1"
            ;;
    esac
}

DEBUG_MODE=${DEBUG_MODE:-false}
if [ "$DEBUG_MODE" = true ]; then
    SKUBA_DEBUG=1
else
    SKUBA_DEBUG=0
fi

skuba_container() {
    # Usage: skuba_container <commands to run in container>
    # the container is normally skuba/update, which contains the caasp4 product,
    # skuba, terraform, etc.

    docker run -i --rm \
    -v "$(pwd)":/app:rw \
    -v "$(dirname "$SSH_AUTH_SOCK")":"$(dirname "$SSH_AUTH_SOCK")" \
    -v "/etc/passwd:/etc/passwd:ro" \
    --env-file <( env| cut -f1 -d= ) \
    -e SSH_AUTH_SOCK="$SSH_AUTH_SOCK" \
    -u "$(id -u)":"$(id -g)" \
    skuba/"$CAASP_VER" "$@"
}

_ssh2() {
    local host=$1
    shift
    ssh -o UserKnownHostsFile=/dev/null \
        -o StrictHostKeyChecking=no \
        -F /dev/null \
        -o LogLevel=ERROR \
        "sles@$host" "$@"
}

skuba_wait_ssh() {
    # Usage:
    # wait_ssh <target>

    timeout=$2
    local target="${1:-all}"

    _define_node_group "$target"
    for n in $GROUP; do
        secs=0
        set +e
        _ssh2 "$n" exit
        while test $? -gt 0
        do
            if [ $secs -gt "$timeout" ] ; then
                echo "Timeout while waiting for $n"
                exit 2
            else
                sleep 5
                secs=$(( secs + 5 ))
                _ssh2 "$n" exit
            fi
        done
        set -e
    done
}

skuba_reboots() {
    # usage: skuba_reboots disable

    local action="${1:-disable}"

    if [[ "$action" == "disable" ]]; then
        kubectl -n kube-system annotate ds kured weave.works/kured-node-lock='{"nodeid":"manual"}'
    else
        kubectl -n kube-system annotate ds kured weave.works/kured-node-lock-
    fi
}

skuba_run_cmd() {
    # Usage:
    # skuba_run_cmd <target> "sudo ..."
    # skuba_run_cmd all "sudo ..."
    # skuba_run_cmd masters "sudo ..."

    local target="${1:-all}"

    _define_node_group "$target"
    for n in $GROUP; do
        _ssh2 "$n" "$@"
    done
}

skuba_use_scp() {
    # Usage:
    # skuba_use_scp <target> <src_files> <dest_files>
    # skuba_use_scp masters <src_files> <dest_files>
    # skuba_use_scp workers <src_files> <dest_files>

    local target="${1:-all}"

    _define_node_group "$target"
    SRC="$2"
    DEST="$3"
    local options="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -F /dev/null -o LogLevel=ERROR -r"

    for n in $GROUP; do
        scp "$options" "$SRC" sles@"$n":"$DEST"
    done
}

skuba_show_images() {
    kubectl get pods --all-namespaces -o jsonpath="{.items[*].spec.containers[*].image}" | tr -s '[[:space:]]' '\n'
}

skuba_updates() {
    # Usage:
    # skuba_updates <target> <action>
    # skuba_updates all disable

    local target="${1:-all}"
    local action="${2:-disable}"

    _define_node_group "$target"
    for n in $GROUP; do
        _ssh2 "$n" "sudo systemctl $action --now skuba-update.timer"
    done
}

skuba_raise_pid_limit() {
    # Usage:
    # skuba_raise_pid_limit <target>
    # skuba_raise_pid_limit all

    # from https://confluence.suse.com/pages/viewpage.action?pageId=565905160
    # setting pids_limit = 4096 which is the default number for services

    local target="${1:-all}"
    local action="${2:-disable}"

    _define_node_group "$target"
    for n in $GROUP; do
        _ssh2 "$n" "echo 'pids_limit = 4096 # max num proc in container' | sudo tee /etc/crio/crio.conf.d/02-cap.conf && sudo systemctl restart crio"
    done
}

_init_control_plane() {
    skuba_container skuba cluster init \
                    --cloud-provider openstack \
                    --control-plane "$LB" "$SKUBA_CLUSTER_NAME"
}

_deploy_masters() {
    local i=0
    for n in $1; do
        if [[ $i -eq 0 ]]; then
            # bootstrap first master
            skuba_container skuba node bootstrap \
                            --user sles --sudo \
                            --target "$n" "caasp-master-$STACK-$i" -v "$SKUBA_DEBUG"
            wait
        fi

        if [[ $i -ne 0 ]]; then
            skuba_container skuba node join \
                            --role master \
                            --user sles --sudo \
                            --target "$n" "caasp-master-$STACK-$i" -v "$SKUBA_DEBUG"
            wait
        fi
        ((++i))
    done
}

_deploy_workers() {
    local i=0
    for n in $1; do
        # bootstrap in parallel:
        (skuba_container skuba node join \
                         --role worker \
                         --user sles --sudo \
                         --target  "$n" "caasp-worker-$STACK-$i" -v "$SKUBA_DEBUG") &
        wait
        ((++i))
    done
}

skuba_init() {
    # Usage: deployment$ skuba_init
    # calls skuba init
    _set_env_vars
    _init_control_plane
}

skuba_deploy() {
    # Usage: deployment$ skuba_deploy
    # calls skuba init
    _set_env_vars
    pushd "$SKUBA_CLUSTER_NAME" || exit
    _deploy_masters "$MASTERS"
    _deploy_workers "$WORKERS"
    skuba_container skuba cluster status
    popd
}

skuba_node_upgrade() {
    # Usage:
    #   skuba_node_upgrade <target>
    #   skuba_node_upgrade all
    #   skuba_node_upgrade masters
    #   skuba_node_upgrade workers

    local target="${1:-all}"

     _define_node_group "$target"
    local i=0
    for n in $GROUP; do
        skuba_container skuba node upgrade \
                        apply --user sles --sudo --target "$n" -v "$SKUBA_DEBUG"
    done
}
