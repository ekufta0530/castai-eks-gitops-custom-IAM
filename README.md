## EKS and CAST AI example for GitOps onboarding flow — Custom IAM

## Custom IAM Overview

Unlike the standard CAST AI Terraform module which creates IAM resources automatically, this example defines all IAM resources explicitly in `iam.tf`. This is the pattern for environments with strict IAM governance where auto-created wildcard policies are not permitted.

### What gets created in `iam.tf`

**1. EC2 Instance Profile** (`castai-eks-<cluster>-node-role`)

Role assumed by EC2 instances that CAST AI launches as EKS worker nodes. Attaches four AWS-managed policies:
- `AmazonEKSWorkerNodePolicy`
- `AmazonEC2ContainerRegistryReadOnly`
- `AmazonEKS_CNI_Policy`
- `AmazonEBSCSIDriverPolicy`

**2. CAST AI Assume Role** (`castai-eks-<cluster>-cluster-role`)

Role assumed by the CAST AI service (via `castai_eks_user_arn`). The trust policy requires:
- Principal: the CAST AI user ARN (fetched dynamically from `castai_eks_user_arn`)
- `sts:ExternalId` condition locked to the specific CAST AI cluster ID

Attaches two AWS-managed read-only policies:
- `AmazonEC2ReadOnlyAccess`
- `IAMReadOnlyAccess`

**3. Inline policy `CastEKSRestrictedAccess`** (attached to the assume role)

This is where the hardening lives. The default CAST AI policy uses `arn:aws:iam::*:role/*` for `iam:PassRole`. This example replaces that with a series of scoped statements:

| Statement | What it allows | Restriction |
|---|---|---|
| `PassRoleEC2` / `PassRoleEKS` | `iam:PassRole` | Locked to the single instance profile role ARN; service-specific condition |
| `RunInstancesTagRestriction` | `ec2:RunInstances` on instances | Only when tagged `kubernetes.io/cluster/<name>=owned` |
| `RunInstancesVpcRestriction` | `ec2:RunInstances` on subnets | Only within the specified VPC (`var.vpc_id`) |
| `InstanceActionsTagRestriction` | `Terminate/Start/Stop` instances | Only cluster-tagged instances (`owned` or `shared`) |
| `AutoscalingActionsTagRestriction` | ASG lifecycle actions | Only cluster-tagged ASGs |
| `EKS` | Describe/List/Tag/Create/Delete nodegroups | Scoped to this cluster and its nodegroups only |
| `CreateLaunchTemplateWithTag` | `ec2:CreateLaunchTemplate` | Requires `kubernetes.io/cluster/<name>=owned` tag on creation |
| `ManageLaunchTemplatesAndCreateNodeGroupWithLaunchTemplate` | LT describe/delete/update | Scoped to cluster-tagged launch templates |

**Key difference from the default module:** `iam:PassRole` is pinned to the exact instance profile role ARN (`arn:aws:iam::<account>:role/castai-eks-<cluster>-node-role`) instead of `arn:aws:iam::*:role/*`. This prevents CAST AI credentials from passing arbitrary roles.

### Additional required variable

`vpc_id` — the EKS cluster's VPC ID. Used in the `RunInstancesVpcRestriction` statement to prevent CAST AI from launching nodes in any other VPC in the account.

---

## GitOps flow 

Terraform Managed ==>  IAM roles, CAST AI Node Configuration, CAST Node Templates and CAST Autoscaler policies

Helm Managed ==>  All Castware components such as `castai-agent`, `castai-cluster-controller`, `castai-evictor`, `castai-spot-handler`, `castai-kvisor`, `castai-workload-autoscaler`, `castai-pod-pinner`, `castai-egressd` are to be installed using other means (e.g ArgoCD, manual Helm releases, etc.)


                                                +-------------------------+
                                                |         Start           |
                                                +-------------------------+
                                                            | Set Profile in AWS CLI
                                                            | 
                                                +-------------------------+
                                                | 0. AWS CLI profile is already set to default,override if only required
                                                | 
                                                +-------------------------+
                                                            | 
                                                            | AWS CLI
                                                +-------------------------+
                                                | 1.Check EKS Auth Mode is API/API_CONFIGMAP
                                                | 
                                                +-------------------------+
                                                            |
                                                            | 
                                    -----------------------------------------------------
                                    | YES                                               | NO
                                    |                                                   |
                        +-------------------------+                      +-----------------------------------------+
                        No action needed from User                     2. User to add cast role in aws-auth configmap
                        
                        +-------------------------+                      +-----------------------------------------+
                                    |                                                   |
                                    |                                                   |
                                    -----------------------------------------------------
                                                            | 
                                                            | 
                                                            | TERRAFORM
                                                +-------------------------+
                                                | 3. Update TF.VARS 
                                                  4. Terraform Init & Apply| 
                                                +-------------------------+
                                                            | 
                                                            | TERRAFORM OUTPUT
                                                +-------------------------+
                                                |  5. Execute terraform output command
                                                | terraform output cluster_id  
                                                  terraform output cluster_token
                                                +-------------------------+
                                                            | 
                                                            |GITOPS
                                                +-------------------------+
                                                | 6. Deploy Helm chart of castai-agent castai-cluster-controller`, `castai-evictor`, `castai-spot-handler`, `castai-kvisor`, `castai-workload-autoscaler`, `castai-pod-pinner`
                                                +-------------------------+         
                                                            | 
                                                            | 
                                                +-------------------------+
                                                |         END             |
                                                +-------------------------+


Prerequisites:
- CAST AI account
- Obtained CAST AI Key [API Access key](https://docs.cast.ai/docs/authentication#obtaining-api-access-key) with Full Access


### Step 0: Set Profile in AWS CLI
AWS CLI profile is already set to default, override if only required.


### Step 1: Get EKS cluster authentication mode
```
CLUSTER_NAME=""
REGION="" 
current_auth_mode=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION | grep authenticationMode | awk '{print $2}') 
echo "Authentication mode is $current_auth_mode"
```


### Step 2: If EKS AUTH mode is API/API_CONFIGMAP, This step can be SKIPPED.
#### User to add cast role in aws-auth configmap, configmap may have other entries, so add the below role to it
```
apiVersion: v1
data:
  mapRoles: |
    - rolearn: arn:aws:iam::028075177508:role/castai-eks-instance-<clustername>
      username: system:node:{{EC2PrivateDNSName}}
      groups:
      - system:bootstrappers
      - system:nodes
kind: ConfigMap
metadata:
  name: aws-auth
  namespace: kube-system
```


### Step 3 & 4: Update TF vars & TF Init, plan & apply
After successful apply, CAST Console UI will be in `Connecting` state. \
Note generated 'CASTAI_CLUSTER_ID' from outputs

### Step 5: Execute TF output command & save the below output values
terraform output cluster_id  
terraform output cluster_token

Obtained values are needed for next step. Note that cluster_token must be used within few hours after creation or it gets expired. It is recommended to install at least castai-agent to keep cluster_token active.

### Step 6: Deploy Helm chart of CAST Components
Coponents: `castai-cluster-controller`,`castai-evictor`, `castai-spot-handler`, `castai-kvisor`, `castai-workload-autoscaler`, `castai-pod-pinner` \
After all CAST AI components are installed in the cluster its status in CAST AI console would change from `Connecting` to `Connected` which means that cluster onboarding process completed successfully.

```
CASTAI_API_KEY="<Replace cluster_token>"
CAST_CONFIG_CLUSTERID="castai-agent-metadata"
CAST_SECRET_APIKEY="castai-agent"


#### Mandatory Component: Castai-agent
helm upgrade -i castai-agent castai-helm/castai-agent -n castai-agent --create-namespace \
  --set apiKey="$CASTAI_API_KEY" \
  --set provider=eks \
  --set createNamespace=false \ 
  --set metadataStore.enabled=true

#### Mandatory Component: castai-cluster-controller
helm upgrade -i cluster-controller castai-helm/castai-cluster-controller -n castai-agent \
  --set autoscaling.enabled=true \
  --set "envFrom[0].secretRef.name=$CAST_SECRET_APIKEY" \
  --set "envFrom[1].configMapRef.name=$CAST_CONFIG_CLUSTERID"

#### castai-spot-handler
helm upgrade -i castai-spot-handler castai-helm/castai-spot-handler -n castai-agent \
--set "envFrom[0].configMapRef.name=$CAST_CONFIG_CLUSTERID" \
--set castai.provider=aws

#### castai-evictor
helm upgrade -i castai-evictor castai-helm/castai-evictor -n castai-agent --set replicaCount=1

#### castai-pod-pinner
helm upgrade -i castai-pod-pinner castai-helm/castai-pod-pinner -n castai-agent \
--set "envFrom[0].secretRef.name=$CAST_SECRET_APIKEY" \
--set "envFrom[1].configMapRef.name=$CAST_CONFIG_CLUSTERID" \ 
--set replicaCount=0

#### castai-workload-autoscaler
helm upgrade -i castai-workload-autoscaler castai-helm/castai-workload-autoscaler -n castai-agent \
--set "envFrom[0].secretRef.name=$CAST_SECRET_APIKEY" \
--set "envFrom[1].configMapRef.name=$CAST_CONFIG_CLUSTERID" \ 

#### castai-kvisor
helm upgrade -i castai-kvisor castai-helm/castai-kvisor -n castai-agent \
--set "envFrom[0].secretRef.name=$CAST_SECRET_APIKEY" \
--set "envFrom[1].configMapRef.name=$CAST_CONFIG_CLUSTERID" \ 
--set controller.extraArgs.kube-linter-enabled=true \
--set controller.extraArgs.image-scan-enabled=true \
--set controller.extraArgs.kube-bench-enabled=true \
--set controller.extraArgs.kube-bench-cloud-provider=eks
```

## Steps Overview

1. If EKS auth mode is not API/API_CONFIGMAP - Update [aws-auth](https://docs.aws.amazon.com/eks/latest/userguide/add-user-role.html) configmap with instance profile used by CAST AI. This instance profile is used by CAST AI managed nodes to communicate with EKS control plane.  Example of entry can be found [here](https://github.com/castai/terraform-provider-castai/blob/157babd57b0977f499eb162e9bee27bee51d292a/examples/eks/eks_cluster_assumerole/eks.tf#L28-L38).
2. Configure `terraform.tfvars.example` file with required values. If EKS cluster is already managed by Terraform you could instead directly reference those resources.
3. Run `terraform init`
4. Run `terraform apply` and make a note of `cluster_id`  output values. At this stage you would see that your cluster is in `Connecting` state in CAST AI console
5. Install CAST AI components using Helm. Use `cluster_id` and `api_key` values to configure Helm releases:
- Set `castai.apiKey` property to `api_key`
- Set `castai.clusterID` property to `cluster_id`
6. After all CAST AI components are installed in the cluster its status in CAST AI console would change from `Connecting` to `Connected` which means that cluster onboarding process completed successfully.


## Importing already onboarded cluster to Terraform

This example can also be used to import EKS cluster to Terraform which is already onboarded to CAST AI console through [script](https://docs.cast.ai/docs/cluster-onboarding#how-it-works).   
For importing existing cluster follow steps 1-3 above and change `castai_node_configuration.default` Node Configuration name.
This would allow to manage already onboarded clusters' CAST AI Node Configurations and Node Templates through IaC.
