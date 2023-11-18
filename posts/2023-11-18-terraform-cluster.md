---
title: "Databricks cluster policies in terraform"
date: '2023-11-18'
description: "Expanding the limited examples I could find online"
layout: post
toc: true
categories: [databricks, terraform]
---

# Introduction

Recently I had to define some [databricks cluster policies](https://learn.microsoft.com/en-ca/azure/databricks/administration-guide/clusters/policies) at work using [terraform](https://registry.terraform.io/providers/databrickslabs/databricks/latest/docs/resources/cluster_policy). I didn't have super sophisticated requirements (at least I didn't think so),
but I still struggled to find sample code online that covered my requirements. This post
is a brief write up on what I implemented and why, as well as some notes on potential
improvements I might make later as my requirements get more detailed.

# Creating the policies

All cluster policies are encoded in JSON, which we create from passing a collection of  `map`s that we `merge` in terraform into the `jsonencode` method.

## Runtimes

One of the first things we want our cluster policy to enforce is using a recent version of the Databricks Runtime (DBR). Depending on the environment we might further restrict this to LTS releases only. Using a series of `data` blocks I find all the relevant releases. Note that this will change as new releases come out, so we'll want to schedule running this to ensure we're always enforcing the latest runtimes. As an example, this block finds the latest LTS release that supports the ML runtime and has GPU drivers installed:

```hcl
data "databricks_spark_version" "latest_ml_gpu_lts" {
  latest            = true
  long_term_support = true
  ml                = true
  gpu               = true
}
```

Another bonus on enforcing runtime policies is it provides an easier way to restrict GPU compute without having to find a list of instance types with GPUs. Since you can't provision a runtime onto a VM with a GPU unless it includes GPU drivers we can limit access to GPU easily with this.

In terms of which runtimes are enabled I made the assumption that we would want consistency across policies in terms of enabled runtimes. That is, the code does not allow for you to enable GPUs on single node compute policies but disable them on multi node.

You'll see a bit further down that offering multiple runtime limitations across policies
within a workspace would be fairly straightforward but introduce a lot of boilerplate code,
at least the way I've implemented it. Again, I don't really see this being a requirement.
Specific runtimes are enabled or disabled with the module booleans `lts_dbr`, `ml_dbr`, and `gpu_dbr`. So if `lts_dbr` is true then only LTS runtimes are enabled, if it's false users are allowed to choose LTS or the most recent runtime. It's similar for `ml_dbr` for ML runtimes and `gpu_dbr` for ML runtimes with GPU enabled (there is no non-ML GPU enabled runtime)


Setting the actual array of allowed runtimes feels kind of hacky, terraform doesn't seem to support if else blocks, or other cleaner ways I could think of to do this:

```hcl
  no_lts_no_ml_no_gpu_arr = (!var.lts_dbr && !var.ml_dbr && !var.gpu_dbr) ? [data.databricks_spark_version.latest_lts.id, data.databricks_spark_version.latest.id] : null
  lts_no_ml_no_gpu_arr    = (var.lts_dbr && !var.ml_dbr && !var.gpu_dbr) ? [data.databricks_spark_version.latest_lts.id] : null
  lts_ml_no_gpu_arr       = (var.lts_dbr && var.ml_dbr && !var.gpu_dbr) ? [data.databricks_spark_version.latest_ml_lts.id, data.databricks_spark_version.latest_lts.id] : null
  lts_ml_gpu_arr          = (var.lts_dbr && var.ml_dbr && var.gpu_dbr) ? [data.databricks_spark_version.latest_ml_lts.id, data.databricks_spark_version.latest_lts.id, data.databricks_spark_version.latest_ml_gpu_lts.id] : null
  no_lts_ml_no_gpu_arr    = (!var.lts_dbr && var.ml_dbr && !var.gpu_dbr) ? [data.databricks_spark_version.latest_ml_lts.id, data.databricks_spark_version.latest_ml.id, data.databricks_spark_version.latest_lts.id, data.databricks_spark_version.latest.id, ] : null
  no_lts_ml_gpu_arr       = (!var.lts_dbr && var.ml_dbr && !var.gpu_dbr) ? [data.databricks_spark_version.latest_ml_lts.id, data.databricks_spark_version.latest_ml.id, data.databricks_spark_version.latest_lts.id, data.databricks_spark_version.latest.id, data.databricks_spark_version.latest_ml_gpu_lts.id, data.databricks_spark_version.latest_ml_gpu.id] : null
  fallback_spark_vers_arr = [data.databricks_spark_version.latest_lts.id]
  runtime_version = {
    "spark_version" : {
      "type" : "allowlist",
      "values" : coalesce(local.no_lts_no_ml_no_gpu_arr, local.lts_no_ml_no_gpu_arr, local.lts_ml_no_gpu_arr, local.no_lts_ml_no_gpu_arr, local.no_lts_ml_gpu_arr, local.fallback_spark_vers_arr),
      "defaultValue" : data.databricks_spark_version.latest_lts.id
    }
  }
```

basically, whichever of those conditionals is true for the combination of runtime booleans that's the list of runtimes that will be available to users of that policy. I put just the latest LTS runtime as a fallback just to handle errors, it shouldn't really come up.

This is honestly more limiting than I'd strictly prefer for the non-LTS releases. As an example, if DBR 14.0 is the latest LTS runtime, and 14.2 is the latest overall runtime,
I'd prefer users be able to provision 14.1 as well. To handle that though I think I'd have to do some array sorting and regex inference to find the position of the LTS release
in the non-LTS array and return everything up to and including that index, and frankly I didn't feel like writing that. Maybe I'll be more motivated in the future.

## Cost management

The next big thing we want to enforce is cost management. One approach would be setting careful limitations on combinations of instance types and number of workers, but databricks also offers a `max_dbu` parameter which just limits the compute cost. This doesn't exactly translate to overall cost, as underlying VM costs are not factored in, but they tend to be very closely related to the DBU cost of the instance type, so the simplicity seemed like a worthwhile trade off. Again, I'm assuming that we don't want to have too many different DBU limits within a given workspace, although I have allowed for interactive and job/DLT compute to have different thresholds. We probably generally want to limit the threshold for exploratory work below what we use to run scheduled jobs. Note that this does introduce a somewhat perverse incentive at the margins to run a larger instance with photon disabled, as enabling photon doubles your DBU cost for any given size of underlying compute.

This is accomplished by passing a line into the compute policy definition that looks something like this:

```hcl
    { "dbus_per_hour" : { "type" : "range", "maxValue" : var.max_dbu_job } },
```

## Single of multi node

For interactive clusters I've created both single node and multi node cluster policies. In theory we shouldn't really care which a user selects, as long as they're below their cost threshold, but for less sophisticated users it might reduce complexity to only allow single node clusters.

```hcl
  single_node = {
    "spark_conf.spark.databricks.cluster.profile" : {
      "type" : "fixed",
      "value" : "singleNode",
      "hidden" : true
    },
    "num_workers" : {
      "type" : "fixed",
      "value" : 0,
      "hidden" : true
    }
  }
```

This can either be added to or left out of a policy definition to enforce single node

## Auto termination

For all interactive policies (it's not relevant to jobs or DLT) I enforce an auto termination of 10 minutes to minimize cluster idling. We could make that a variable if a need comes up, but I'd personally like to keep it low and consistent for now:

```hcl
  autotermination = {
    "autotermination_minutes" : {
      "type" : "fixed",
      "value" : 10
      # "hidden" : true
  } }
```

I took off the `hidden` flag for now so users can see that it's been auto set for them. We can remove that later to reduce the complexity of the cluster creation interface.

I have heard some feedback from ML users that it's not reasonable to expect them to be sitting around ready to pounce on long running tasks when they're
prototyping so I'm going to end up modifying this to a range with a higher maximum value that we can configure for ML workspaces.

## Tags

Finally, I added some tags, which right now don't really do much since I don't know what additional tags we want to add. A lot gets auto applied that might be sufficient, but I wanted to demonstrate the capability:

```hcl
  default_tags = {
    "custom_tags.lob" : {
      "type" : "fixed",
      "value" : "${var.lob_name}",
      "hidden" : true
    },
    "custom_tags.TEST" : {
      "type" : "fixed",
      "value" : "testfromterraform"
    }
  }
```

## Actual cluster policies

Putting it all together we can define cluster policies like so:

```hcl
resource "databricks_cluster_policy" "multi-node-personal" {
  count = var.create_multi_node_personal_policy ? 1 : 0
  name  = "Multi Node Personal Compute"
  definition = jsonencode(merge(
    { "dbus_per_hour" : { "type" : "range", "maxValue" : var.max_dbu_interactive } },
    local.runtime_version,
    local.autotermination,
    local.default_tags,
    local.photon
  ))
}
```

# Conclusion

In this post I demonstrated how to create a set of databricks cluster policies using
a terraform module that can be applied to your workspaces. Nothing particularly
earth shattering, and I'm not sure whether to be pleased or horrified with that
giant block I wrote to produce the acceptable runtime list, but it works and it at least
adds some more example code that others can build off.