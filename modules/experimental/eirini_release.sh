#!/bin/bash

. ./defaults.sh
. ../../include/common.sh
. .envrc

DOMAIN=$(kubectl get configmap -n kube-system cap-values -o json | jq -r '.data["domain"]')
container_ip=$(kubectl get configmap -n kube-system cap-values -o json | jq -r '.data["public-ip"]')

admin_pass=$(kubectl get secret --namespace scf \
                     var-cf-admin-password \
                     -o jsonpath='{.data.password}' | base64 --decode)

cat > eirini-values.yaml <<EOF
env:
  DOMAIN: &DOMAIN ${DOMAIN}
  # Uncomment if you want to use Diego to stage applications
  # ENABLE_OPI_STAGING: false
  UAA_HOST: uaa.${DOMAIN}
  UAA_PORT: 2793

kube:
  auth: rbac
  external_ips: &external_ips
  - ${container_ip}
  storage_class:
    persistent: persistent
    shared: persistent

secrets: &secrets
  CLUSTER_ADMIN_PASSWORD: ${admin_pass}
  UAA_ADMIN_CLIENT_SECRET: ${admin_pass}
  BLOBSTORE_PASSWORD: &BLOBSTORE_PASSWORD "${admin_pass}"

services: &services
  loadbalanced: false

eirini:
  env:
    DOMAIN: *DOMAIN
  services: *services
  opi:
    use_registry_ingress: false
    # Enable if use_registry_ingress is set to 'true'
    # ingress_endpoint: kubernetes-cluster-ingress-endpoint

  secrets:
    BLOBSTORE_PASSWORD: *BLOBSTORE_PASSWORD
    BITS_SERVICE_SECRET: &BITS_SERVICE_SECRET "${admin_pass}"
    BITS_SERVICE_SIGNING_USER_PASSWORD: &BITS_SERVICE_SIGNING_USER_PASSWORD  "${admin_pass}"

  kube:
    external_ips: *external_ips

bits:
  env:
    DOMAIN: *DOMAIN
  services: *services
  opi:
    use_registry_ingress: false
    # Enable if use_registry_ingress is set to 'true'
    # ingress_endpoint: kubernetes-cluster-ingress-endpoint

  secrets:
    BLOBSTORE_PASSWORD: *BLOBSTORE_PASSWORD
    BITS_SERVICE_SECRET: *BITS_SERVICE_SECRET
    BITS_SERVICE_SIGNING_USER_PASSWORD: *BITS_SERVICE_SIGNING_USER_PASSWORD

  kube:
    external_ips: *external_ips
EOF


helm repo add eirini https://cloudfoundry-incubator.github.io/eirini-release
#helm repo add bits https://cloudfoundry-incubator.github.io/bits-service-release/helm

if [ ! -d eirini ]; then
  git clone $EIRINI_RELEASE_REPO eirini
fi
pushd eirini || exit
git checkout ${EIRINI_RELEASE_CHECKOUT}
git pull
popd || exit

helm fetch eirini/cf
tar xzvf eirini-cf.tgz
pushd cf/charts || exit
tar xvfz eirini-*.tgz
cp ../../eirini/helm/eirini/templates/eirini-loggregator-bridge.yaml eirini/templates
tar cvfz eirini-*.tgz eirini
rm -rf eirini
popd || exit

kubectl create namespace "uaa" || true
helm_install uaa eirini/uaa --namespace uaa --values eirini-values.yaml
bash ../scripts/wait.sh uaa

SECRET=$(kubectl get pods --namespace uaa -o jsonpath='{.items[?(.metadata.name=="uaa-0")].spec.containers[?(.name=="uaa")].env[?(.name=="INTERNAL_CA_CERT")].valueFrom.secretKeyRef.name}')
CA_CERT="$(kubectl get secret $SECRET --namespace uaa -o jsonpath="{.data['internal-ca-cert']}" | base64 --decode -)"

cp -rfv "$ROOT_DIR"/config/config.toml ./config.toml

sed -i 's/http:\/\/localhost:32001/https:\/\/registry.'${DOMAIN}':6666/g' ./config.toml
sed -i 's/local.insecure-registry.io/registry.'${DOMAIN}'/g' ./config.toml

# Overwrite config.toml with our own
docker cp config.toml ${CLUSTER_NAME}-control-plane:/etc/containerd/config.toml

# Restart the kubelet
docker exec ${CLUSTER_NAME}-control-plane systemctl restart kubelet.service
sleep 120
openssl req -newkey rsa:4096 -nodes -sha256 -keyout domain.key -x509 -days 365 -out domain.crt -subj "/C=GB/ST=London/L=London/O=Global Security/OU=IT Department/CN=registry.${DOMAIN}"

kubectl create namespace "scf" || true
helm_install eirini cf/ --namespace scf --values eirini-values.yaml --set "secrets.UAA_CA_CERT=${CA_CERT}" --set "eirini.secrets.BITS_TLS_KEY=$(cat domain.key)" --set "eirini.secrets.BITS_TLS_CRT=$(cat domain.crt)"

wait_for_kubecf
