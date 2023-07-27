## OCP VMWare Topology

Simple bash script to configure VMWare host and vm groups and rules for OCP nodes.   The script will :

1. Create VSphere cluster host groups containing hypervisors.  These groups should be in their own failure domain and are analogous to cloud availability zones.
1. Create VSphere cluster vm groups containing label nodes.  For each zone, create a vm group for each defined role (control-plane, infra, app, etc).
1. Create affinity rules to ensure members of each role group only run on the appropriate zone groups.
1. Enable drs full automation for each discovered node.
1. Label each node in OCP with the appropriate zones and regions.

### Configuration

#### Topology

To configure the topology, a simple yaml file is used.

```yaml
---
region: region1
zones:
  - name: 1a
    hosts:
      - esx1.example.com
  - name: 1b
    hosts:
      - esx2.example.com
  - name: 1c
    hosts:
      - esx3.example.com
roles:
  - name: master
    label: node-role.kubernetes.io/control-plane
  - name: app
    label: node-role.kubernetes.io/app
  - name: infra
    label: node-role.kubernetes.io/infra
```

1. The region value is a simple identifier, container for the zones.
1. The zones contain a zone name and list of hypervisors in the zone.
1. The roles contain a list of role identifiers and labels to discover the nodes.  These should be configured prior to running the script and represent the hosts required to be in separate zones.

#### Credentials

When running locally or with podman, an active session to the OpenShift cluster, with sufficient permissions is required.  The vSphere credentials are obtained from the vsphere-creds secret in openshift.  The namespace for the credentials can be overrriden with the NAMESPACE environment variable.  The format follows the vsphere-creds secret, in the kube-system namespace, set by OpenShift VMWare installs.  Cluster admins can use this secret by setting the NAMESPACE environment variable to kube-system.  The format is a key of the vsphere server name appended with .password and .username. Eg vcenter.example.com.password and vcenter.example.com.username.  The name of the server to connect to is extracted from the keyname so should be set when using user provided secrets.

### Invocation

The script can be run locally, via podman or as an openshift job.  Local and podman execution requires an active session to the openshift cluster with sufficient privileges.

#### Local invocation

Ensure that the govc, yq and openshift client dependencies are installed.  Update the cluster.yaml file to reflect the topology you want to apply.

```shell
CONFIG_PATH=./cluster.yaml NAMESPACE=kube-system ./topology.sh
```

#### Podman invocation

Update the cluster.yaml file to reflect the topology you want to apply.

```shell
podman run -it --rm -v "$PWD:$PWD" -e NAMESPACE=kube-system -v "$HOME/.kube/config:/root/.kube/config" -v "/etc/pki:/etc/pki" -v "$PWD/cluster.yaml:/config/cluster.yaml" -v "$HOME/etc/ca.crt:/certificates/ca.crt" -w "$PWD" quay.shakey.dev/lshakesp/govc:latest ./topology.sh
```

The command mounts the current directory, the kube config, the local system certificates, the VSphere certificate authority root and the configuration cluster.yaml file into the container.  It sets the NAMESPACE variable to be kube-system.  It uses the container built from the included conainerfile and runs the topology.sh script.

#### OpenShift Job

An example openshift deployment is included which includes the necessary artifacts.  Update the files in the manifest directory as required, rename the sample files and include your own credentials and hosts.

- ca-configmap.yaml : vSphere TLS root certificate
- cluster.yaml : Cluster topology config file
- pull-secret.yaml : Container Registry pull secret
- vsphere-secret.yaml : vsphere username and password

```shell
oc apply -k ./manifest
```

Permissions are required to update labels on nodes, to lookup the vsphere-creds secret, and to extract the cluster name.  The serviceaccount.yaml file provides a suitable role and clusterrole.  Be aware that the job while not running with any elevated kubernetes privileges, does have API privileges.

### Notes

1. Adding and removing nodes requires the script to be re-run.  This will result in vmotion drs events has the hosts move to new hypervisors.
1. Nodes are sorted alphabetically and as such removing or adding nodes may change their zone placement.  Separation will be maintained, but while the cluster rebalances there will be a very brief period where two nodes may be in the same failure zone.
1. The zone labeling on a node may change which is usual for a Kubernetes node and not well tested.  Workloads spread across the whole zone should not be significantly effected, but consideration should be given to workloads running in one or two zones where OpenShift may restart pods to satisfy placement constraints.
1. Node numbers not divisible by three will work, but any extra nodes will be placed into the first or second zones resulting in a potentially unbalanced vmware cluster.
