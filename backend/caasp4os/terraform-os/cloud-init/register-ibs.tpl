  - /usr/sbin/update-ca-certificates &> /dev/null
  - zypper in -y -l --auto-agree-with-product-licenses -t product caasp
  - zypper in -y -l -t pattern SUSE-CaaSP-Node &> /dev/null
  - zypper up -y -l --auto-agree-with-product-licenses 2>&1>/dev/null
