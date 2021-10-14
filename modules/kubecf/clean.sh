#!/usr/bin/env bash

. ./defaults.sh
. ../../include/common.sh
. .envrc || exit 0

# if no kubeconfig, no cf. Exit
[ -f "$KUBECONFIG" ] || exit 0

# TODO disabling for now, it blocks indefinitely here with the pvc states in
# "Terminating"
# # clean pvcs
# kubectl get -n scf pvc -o name \
#     | xargs --no-run-if-empty kubectl delete -n scf

if helm_ls 2>/dev/null | grep -qi minibroker ; then
    # minibroker testsuite may leave leftovers,
    # https://github.com/SUSE/minibroker-integration-tests/issues/24
    helm ls -n minibroker --short | xargs -L1 helm delete -n minibroker
fi
if kubectl get namespaces 2>/dev/null | grep -qi minibroker ; then
    kubectl delete --ignore-not-found namespace minibroker
fi

if helm_ls 2>/dev/null | grep -qi susecf-scf ; then
    helm_delete susecf-scf --namespace scf
fi

if kubectl get psp 2>/dev/null | grep -qi susecf-scf ; then
    kubectl delete --ignore-not-found psp susecf-scf-default
fi

if helm_ls 2>/dev/null | grep -qi cf-operator ; then
    helm_delete cf-operator --namespace cf-operator
fi
if kubectl get namespaces 2>/dev/null | grep -qi cf-operator ; then
    kubectl delete --ignore-not-found namespace cf-operator
fi

for webhook in $(kubectl get validatingwebhookconfigurations.admissionregistration.k8s.io \
                         --no-headers -o custom-columns=":metadata.name" | grep cf-operator);
do
    kubectl delete validatingwebhookconfigurations.admissionregistration.k8s.io "$webhook"
done

for webhook in $(kubectl get mutatingwebhookconfigurations.admissionregistration.k8s.io \
                         --no-headers -o custom-columns=":metadata.name" | grep cf-operator);
do
    kubectl delete mutatingwebhookconfigurations.admissionregistration.k8s.io "$webhook"
done

for crd in $(kubectl get crd \
                         --no-headers -o custom-columns=":metadata.name" | grep quark);
do
    kubectl delete crd "$crd"
done

if kubectl get namespaces 2>/dev/null | grep -qi eirini ; then
    kubectl delete --ignore-not-found namespace eirini
fi
if helm_ls 2>/dev/null | grep -qi metrics-server ; then
    helm_delete metrics-server
fi

rm -rf scf-config-values.yaml chart helm kube "$CF_HOME"/.cf

rm -rf cf-operator* kubecf* assets templates Chart.yaml values.yaml Metadata.yaml \
   imagelist.txt requirements.lock  requirements.yaml

ok "Cleaned up KubeCF from the k8s cluster"
