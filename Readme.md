# Using NetApp Cloud Volumes Services (CVS) on GCP for Google Kubernetes Engine (GKE) with NetApp Trident as CSI provisioner

Quick recipe to use NetApp [Cloud Volumes Service CVS on GCP](https://cloud.netapp.com/cloud-volumes-service-for-gcp) as reliable NFS persistent volumes (PV) on [Google Kubernetes Engine (GKE)](https://cloud.google.com/kubernetes-engine/), using Netapps Open Source CSI provisioner [Trident](https://github.com/NetApp/trident).

## Features
Using Cloud Volumes Service via Trident with GKE provides:
* Reliable, easy to use Persistant Volumes (PV), managed via Persistent Volume Claims (PVC) and Custom Resource Definitions (CRD)
* Consistent performance with low latency (IOPS and throughput limits can be configured dynamically)
* ReadWriteOnce (RWO) and ReadWriteMany (RWX) support
* Instant, performance neutral resizing of PVs
* Instant, space efficient (only stores changed 4k blocks), performance neutral snapshots of a PV (versioning for persistent data)
* Instant clones of PVs, independent of PV size
* Multiple backup/recovery, CI/CD and Test/DEV use cases, enabled by instant snapshots and cloning

## Requirements
GKE requirements:
* Trident requires Kubernetes >=1.11 [docs](https://netapp-trident.readthedocs.io/en/latest/support/requirements.html#supported-frontends-orchestrators)
* For using the CSI features of Trident (e.g. control everything via CRDs), use GKE >= v1.14
* Container-Optimized OS images don't include an NFS client. Choose Ubuntu images instead. [docs](https://cloud.google.com/kubernetes-engine/docs/concepts/node-images)

CVS requirements:
* [Documentation of CVS](https://cloud.google.com/solutions/partners/netapp-cloud-volumes)
* CVS needs to be reachable from GKE cluster
* Trident is runs as deployment on GKE and needs to be able to do REST calls to https://cloudvolumesgcp-api.netapp.com
* Make sure CVS volumes in the desired region can be created and mounted (by doing a manual test)

Trident requirements:
* [Trident 19.10 or later](https://netapp.io/2019/10/30/trident-19-10/)

Trident links:
* [Documentation](https://netapp-trident.readthedocs.io/en/latest/)
* [CVS on GCP documentation](https://netapp-trident.readthedocs.io/en/latest/kubernetes/operations/tasks/backends/cvs_gcp.html)
* [Trident on Github](https://github.com/NetApp/trident)

## Installation

Assumption:
* GKE cluster >= v1.14 is running
* GKE cluster uses image which got NFS client (e.g. Ubuntu image)
* GKE cluster can reach CVS
* Likely the easiest way is to do the installation from Cloud Shell

### Install Trident
Follow instructions [installation instructions](https://netapp-trident.readthedocs.io/en/latest/kubernetes/deploying.html) until you reach step "Create a Trident backend".

To make the following steps easier, record the trident-installer directory:
```bash
TRIDENT_DIR=$PWD
```

### Configure Trident
The following instructions will assist in building a proper backend configuration.

1. Clone this repository and cd into it
1. Create GCP service account to access CVS API and generate a JSON keyfile.

   See https://cloud.google.com/solutions/partners/netapp-cloud-volumes/api. Here is a video which shows the steps: https://www.youtube.com/watch?v=x-fiw1t3Y4o
   
   Alternatively use the provided script to create the account. Run from Cloud Shell:

    ```bash
    source ./create-api-service-account.sh
    ```
    Store the name of the keyfile in CVS_KEYFILE:
    ```bash
    # if you created keyfile manually, use path to your keyfile
    CVS_KEYFILE=$PWD/cvs-api-sa.json
    ```
1. For later use, record GCP project number:
    ```bash
    PROJECT_NUMBER=<your_project_number>
    # or, if run from CloudShell
    PROJECT_NUMBER=$(gcloud projects list --filter="$DEVSHELL_PROJECT_ID" --format="value(PROJECT_NUMBER)")
    # or, if run on a GKE worker node
    PROJECT_NUMBER=$(curl -s "http://metadata.google.internal/computeMetadata/v1/project/numeric-project-id" -H "Metadata-Flavor: Google")
    ```
    If you are using a shared VPC use the PROJECT_NUMBER of your *hosting project* !
1. Specify VPC the CVS service is connected/peered to:
    ```bash
    # If you are unsure, use
    # gcloud compute networks peerings list
    # to identify the correct VPC. Look for a line where PEER_NETWORK=netapp-tenant-vpc and
    # put that lines NETWORK below
    gcpNetwork=$(gcloud compute networks peerings list | awk '/netapp-tenant-vpc/ {print $2}')
    # if you are using "default" VPC
    gcpNetwork="default"
    ```
1. Set GCP region where you want to store your PVs (CVS volumes):
    ```bash
    gcpRegion="europe-west3"
    ```
1. Generate Trident backend configuration. This can all be done manually by editing file the [backend template](./backend-cvs-gcp-advanced-template.json) or programmatically by running:
    ```bash
    jq -n --argjson apiKey "$(cat $CVS_KEYFILE)" --arg projectNumber "$PROJECT_NUMBER" --arg gcpRegion "$gcpRegion" --arg network "$gcpNetwork" -f backend-cvs-gcp-advanced-template.json > backend.json
    ```
    You may want to modify export policy (default 0.0.0.0/0), snap reserve size (default 10%) and proxy settings (default: none) in backend.json. Examples on how the file might look like are [here](https://netapp-trident.readthedocs.io/en/latest/kubernetes/operations/tasks/backends/cvs_gcp.html).

1. Deploy backend configuration to Trident and create storageclasses
    ```bash
    cp backend.json $TRIDENT_DIR
    cp storage-classes-gcp.yaml $TRIDENT_DIR
    pushd .
    cd $TRIDENT_DIR
    ./tridentctl -n trident create backend -f backend.json

    # check for errors
    ./tridentctl -n trident logs

    # Create new storageclasses for Trident
    kubectl apply -f storage-classes-gcp.yaml
    ```
    This will create 6 new storage classes: 
    ```bash
    $ kubectl get storageclasses
    NAME                              PROVISIONER             AGE
    cvs-extreme                       csi.trident.netapp.io   4h37m
    cvs-extreme-extra-protection      csi.trident.netapp.io   4h37m
    cvs-premium                       csi.trident.netapp.io   4h37m
    cvs-premium-extra-protection      csi.trident.netapp.io   4h37m
    cvs-standard                      csi.trident.netapp.io   4h37m
    cvs-standard-extra-protection     csi.trident.netapp.io   4h37m
    standard (default)                kubernetes.io/gce-pd    6h14m
    ```
    * Standard is 16MB/s per TiB
    * Premium is 64MB/s per TiB
    * Extreme is 128MB/s per TiB

    *-extra-protection reserves 10% capacity (tuneable in backend.json) for snapshots (snap reserve) and makes ".snapshot" directory visible at the PV root directory. The other three classes reserve no space for snapshots and hide the ".snapshot". You will still be able to do "cd .snapshot" to access it.

    Please note that snapshots can be created, no matter which class is used. The [snap reserve](https://kb.netapp.com/app/answers/answer_view/a_id/1004547/~/how-does-the-snapshot-reserve-work%3F-) is merely an accounting "trick". A visible ".snapshot" directory is convenvient for simple snapshot access, but might confuse some containers (e.g. MongoDB container tries to do a chmod -R at startup, which fails since snapshots are read-only).

### Verify PVC creation and accessibility
1. Check if trident can deploy a PV for an PVC successfully:
    ```bash
    popd
    kubectl apply -f nfs-pvc.yaml
    kubectl get pvc nfs-pvc --watch
    ```
    After some seconds a PV should be bound to the PVC.

1. Check if pods can mount the PV successfully:

    The following will deploy one pod with two containers. The first container creates a file "HelloTrident" on the RWX PV, the second does an "ls -l" on the PV.
    ```bash
    kubectl apply -f hello-trident.yaml
    # Wait until pod is deployed
    kubectl logs hellotrident
    # output should look like
    # -rw-r--r--    1 root     root             0 Nov  8 12:46 /data/HelloTrident
    ``` 
1. Cleanup
    ```bash
    kubectl delete -f hello-trident.yaml
    kubectl delete -f nfs-pvc.yaml
    ``` 

Congratulations, it works!

Next step:
* [Learn how to do snapshots and create instant clones.](https://netapp.io/2019/06/28/on-demand-snapshots-with-csi-trident/)
* For Trident 20.01 or later, see notes on [CSI Alpha vs CSI Beta snapshots](https://netapp.io/2020/01/30/alpha-to-beta-snapshots/)

## Support
This is intended as a recipe to simplify Trident installation on GCP. If you run into problems, you might want to check the [Documentation](https://netapp-trident.readthedocs.io/en/latest/). It is the authorative source for installation instructions. It also got an section on how to get official support from NetApp.

## Changelog
* 2020-08-03: Tested procedure successfully with GKE 1.16.11 and Trident 20.07 (old tridentctl installation method)
