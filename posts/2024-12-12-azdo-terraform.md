---
title: "What I learned building a pipeline to deploy terraform in Azure DevOps"
date: "2024-12-12"
description: "Mistakes were made and learned from"
layout: "post"
toc: true
categories: [DevOps, terraform]
---

# Introduction

I recently set out to build a pipeline to deploy some resources with Terraform and Azure DevOps.
Along the way I learned a fair bit about DevOps so I'm writing it down for future reference.

# Problem statement

I have a [terraform](https://www.terraform.io/)
code base that stores its state in [ADLS](https://learn.microsoft.com/en-us/azure/storage/blobs/data-lake-storage-introduction)
and deploys other resources to Azure. I've got three environments to deploy to,
`dev`, `uat`, and `prod`. Each environment has an associated [service connection](https://learn.microsoft.com/en-us/azure/devops/pipelines/library/service-endpoints?view=azure-devops)
associated with it that should be used to deploy infrastructure. In DevOps I've created
a corresponding branch for each environment. When I create a PR targeting a particular
branch I want the appropriate service connection to run `terraform plan` and add the
output as a comment on the PR. The service connection to use and environment specific
`tfvars` should be determined by the target branch of the PR. When code is merged
into the one of the environment's branches then I want the appropriate service connection
and `tfvars` to be used to run `terraform apply` based on the source branch.

# The initial plan

This is what I first thought of with some details removed for simplicity:

```yaml
name: terraform apply
trigger:
  branches:
    include:
      - dev
      - uat
      - prod
pr:
  branches:
    include:
      - '*'

jobs:
  - job: setvars
    pool: linux
    steps:
      - script: |
          if [[ $(Build.Reason) -eq 'PullRequest' ]]; then
            echo 'Build Reason is PR, setting branch based on target'
            BRANCH=$(System.pullRequest.targetBranchName)
            echo '##vso[task.setvariable variable=BRANCH;isOutput=true]$(System.pullRequest.targetBranchName)'
          else
            echo 'Not a Pull request, setting branch based on source'
            echo '##vso[task.setvariable variable=BRANCH;isOutput=true]$(Build.SourceBranchName)'
            BRANCH=$(Build.SourceBranchName)
          fi
          echo "##vso[task.setvariable variable=SERVICE_CONNECTION;isOutput=true]${BRANCH}-service-connection"
          echo "##vso[task.setvariable variable=TFVARS_FILE]${BRANCH}_vars.tfvars"
          echo "##vso[task.setvariable variable=TFBACKEND_FILE]${BRANCH}_backend.tf"
        displayName: "Set Variables"
        name: "setvar"
  - job: terraform
    pool: linux
    dependsOn: setvars
    variables:
      BRANCH: $[ dependencies.setvars.outputs['setvar.BRANCH']]
      SERVICE_CONNECTION: $[ dependencies.setvars.outputs['setvar.SERVICE_CONNECTION']]
      TFVARS_FILE: $[ dependencies.setvars.outputs['setvar.TFVARS_FILE']]
      TFBACKEND_FILE: $[ dependencies.setvars.outputs['setvar.TFBACKEND_FILE']]
    steps:
      - checkout: self
      - task: AzureCLI@2
        displayName: terraform init
        inputs: 
          azureSubscription: $(SERVICE_CONNECTION)
          addSpnToEnvironment: true
          scriptType: bash
          scriptLocation: inlineScript
          inlineScript: |
            # Ensure a failure of any line in this script fails the pipeline
            set -e
            terraform init -backend-config=$(TFBACKEND_FILE)
      - task: AzureCLI@2
        condition: eq(variables['Build.Reason'], 'PullRequest')
        displayName: terraform plan
        inputs: 
          azureSubscription: $(SERVICE_CONNECTION)
          addSpnToEnvironment: true
          scriptType: bash
          scriptLocation: inlineScript
          inlineScript: |
            # Ensure a failure of any line in this script fails the pipeline
            set -e
            terraform plan -var-file="$(TFVARS_FILE)" -out=plan.tfplan
            echo "I'd do the PR comment based on this but removed it for simplicity"
      - task: AzureCLI@2
        condition: and(ne(variables['Build.Reason'], 'PullRequest'),or(eq(variables['Build.SourceBranchName'], 'dev'),eq(variables['Build.SourceBranchName'], 'uat'),eq(variables['Build.SourceBranchName'], 'prod')))
        displayName: terraform apply
        inputs: 
          azureSubscription: $(SERVICE_CONNECTION)
          addSpnToEnvironment: true
          scriptType: bash
          scriptLocation: inlineScript
          inlineScript: |
            # Ensure a failure of any line in this script fails the pipeline
            set -e
            terraform apply -auto-approve -var-file="$(TFVARS_FILE)"
```

## What are we doing here?

The first part sets a variable called `BRANCH` based on the target branch if the pipeline is triggered by a PR
or the source branch if it's triggered by a merge into one of our environment branches. From there
we point to the correct `tfvars` files and service connection name to run the correct plan/apply.
The subsequent job retrieves those variables and executes the right command with the right variables.

## Seems fine, what's the problem?

The tldr is that DevOps needs to know the service connection name at compile time,
and since I'm trying to calculate it at run time the job fails. It tries to
start the pipeline with the literal `$(SERVICE_CONNECTION)` instead of `dev-service-connection`
or whatever, which fails since that service connection doesn't exist.

# What I learned troubleshooting this

The main thing is what's listed in the previous section. You can't dynamically calculate
a service connection name in a pipeline step. If I didn't have the criteria for
different behaviour in PRs I might have been able to get away with something like
`${{ variables['Build.SourceBranchName'] }}-service-connection` but with my PR requirement
that wasn't going to fly.

The DevOps syntax for variables is pretty explicit about what you should use where
but until this point I'd just cargo culted in whatever format the closest example I could
find had used without really thinking about it.

To learn more I recommend the following docs:

- [Expressions Docs](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/expressions?view=azure-devops)
- [Runtime parameters docs](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/runtime-parameters?view=azure-devops&tabs=script)
- [Variables docs](https://learn.microsoft.com/en-us/azure/devops/pipelines/process/variables?view=azure-devops&tabs=yaml%2Cbatch) there's more on the sidebar, keep reading through

Also, for problems like this ChatGPT is a nightmare, it just kept cycling me through different syntax, none
of which worked because what I was trying to do wasn't fundamentally possible.
I tried `$(SERVICE_CONNECTION)`, `$[variables.SERVICE_CONNECTION]`, `$[ dependencies.setvars.outputs['setvar.SERVICE_CONNECTION'] ]`
and probably some other permutations I'm forgetting. For each of those I had to push up a commit,
wait for the pipeline to run and fail and then try something else.
I really wish there was a way to locally test the actual pipeline syntax.

# What I ended up doing

Instead of doing a bunch of dynamic stuff on one job, I created a template
with some parameters, and then set that template up to be called in
the pipeline for each environment with a conditional to only trigger in the
circumstance I wanted:

Example template:

```yaml
parameters:
  - name: name
    default: 'dev_apply'
  - name: env
    default: 'dev'
  - name: service_principal
    default: 'dev-service-connection'

jobs:
  - job: ${{ parameters.name }}
    pool: linux
    condition: eq(variables['Build.SourceBranchName'], '${{ parameters.env }}')
    steps:
      - task: AzureCLI@2
        displayName: ${{ parameters.env }} plan
        inputs: 
          azureSubscription: ${{ parameters.service_principal }}
          addSpnToEnvironment: true
          scriptType: bash
          scriptLocation: inlineScript
          inlineScript: |
            # Ensure a failure of any line in this script fails the pipeline
            set -e
            # Required to allow terraform to auth as SP
            export ARM_CLIENT_ID="${servicePrincipalId}"
            export ARM_CLIENT_SECRET="${servicePrincipalKey}"
            export ARM_TENANT_ID="$(az account show --query 'tenantId' -o tsv)"
            export ARM_SUBSCRIPTION_ID="$(az account show --query="id" -o tsv)"
            terraform init -backend-config=${{ parameters.env }}_backend.tfvars
            terraform apply -auto-approve -var-file=${{ parameters.env }}_vars.tfvars
```

Example of the main pipeline:

```yaml
name: my-pipeline
trigger:
  branches:
    include:
      - dev
      - uat
      - prod
pr:
  branches:
    include:
      - '*'

jobs:
  - template: templates/terraform-plan.yaml
    parameters:
      name: 'dev_plan'
      env: 'dev'
      service_principal: dev-service-connection
  - template: templates/terraform-plan.yaml
    parameters:
      name: 'uat_plan'
      env: 'uat'
      service_principal: uat-service-connection
  - template: templates/terraform-plan.yaml
    parameters:
      name: 'prod_plan'
      env: 'prod'
      service_principal: prod-service-connection
  - template: templates/terraform-apply.yaml
    parameters:
      name: 'dev_apply'
      env: 'dev'
      service_principal: dev-service-connection
  - template: templates/terraform-apply.yaml
    parameters:
      name: 'uat_apply'
      env: 'uat'
      service_principal: uat-service-connection
  - template: templates/terraform-apply.yaml
    parameters:
      name: 'prod_apply'
      env: 'prod'
      service_principal: prod-service-connection
```

Pretty clean, still minimal repetition. Not bad!
Note that the conditional has to be in the template, I
originally wanted to set it outside but that's not permitted.

# What about the PR comment?

I left that out of the examples because it wasn't relevant to that part.
For the most part I just followed [Thomas Thornton's approach](https://thomasthornton.cloud/2024/01/24/displaying-terraform-plan-as-a-comment-in-azure-devops-repo-prs-with-azure-devops-pipelines/)
but I do have one minor enhancement that I think is worth calling out.
In his approach the raw terminal output is dumped into the PR comment,
which turns all the `#` comments in the terminal output into markdown
headers. I added a bit of formatting around it so that it would all show up
as a code block in the PR comment. The relevant change looks like this:

```bash
COMMENT=$(printf "#Terraform ${{ parameters.env }} Plan\n\`\`\`bash\n%s\n\`\`\`" "$(terraform show -no-color plan.tfplan)")
```

The `printf` is required so the backticks don't get escaped in the json message.

# Conclusion

DevOps is not very fun for me. I wouldn't hate it so much if the
feedback loop wasn't so slow between change, commit, push, pipeline run.
If anyone has tips on that I'd love to hear it.
