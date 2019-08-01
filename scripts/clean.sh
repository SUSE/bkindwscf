#!/bin/bash
set -x
. scripts/include/common.sh

if [ -d "../build${CLUSTER_NAME}" ]; then
      if [ "$DEEP_CLEAN" = true ] ; then
        helm del --purge susecf-uaa
        helm del --purge susecf-scf
        kubectl delete secret --all
        kubectl delete pod --all -n eirini
        kubectl delete pvc --all -n eirini
        kubectl delete pod --all -n cf
        kubectl delete secret --all -n eirini
      fi
      helm reset --force
      ./kind delete cluster --name="${cluster_name}"
  popd

  rm -rf build${CLUSTER_NAME}
fi
