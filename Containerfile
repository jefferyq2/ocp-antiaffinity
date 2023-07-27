FROM registry.access.redhat.com/ubi8/ubi-minimal
RUN microdnf install tar gzip curl util-linux jq -y
RUN curl -L -o - "https://github.com/vmware/govmomi/releases/latest/download/govc_$(uname -s)_$(uname -m).tar.gz" | tar -C /usr/local/bin -xvzf - govc
RUN curl -L -o - "https://mirror.openshift.com/pub/openshift-v4/x86_64/clients/ocp/stable/openshift-client-linux.tar.gz" | tar -C /usr/local/bin -xvzf - oc
RUN curl -L -o /usr/local/bin/yq "https://github.com/mikefarah/yq/releases/download/v4.34.1/yq_linux_amd64" && chmod 0755 /usr/local/bin/yq
