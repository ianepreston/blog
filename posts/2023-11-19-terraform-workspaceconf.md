---
title: "Databricks workspace config in terraform"
date: '2023-11-19'
description: "Expanding the limited examples I could find online"
layout: post
toc: true
categories: [databricks, terraform]
---

# Introduction

The [Databricks Security Analysis Tool (SAT)](https://www.databricks.com/blog/2022/11/02/announcing-security-analysis-tool-sat.html)
is a pretty handy tool developed by databricks to scan your workspaces and produce alerts
where your configuration deviates from best practices. To remediate some of these issues
you need to modify your workspace configuration. Some things can be done from the UI,
others I believe require calling the API. In either case, it would be preferable to automate
these configurations as part of workspace provisioning. The [databricks_workspace_conf](https://registry.terraform.io/providers/databricks/databricks/latest/docs/resources/workspace_conf) resource in terraform can be used to
accomplish this. Unfortunately, similar to the issue I documented trying to
[configure cluster policies](2023-11-18-terraform-cluster.md), the docs are pretty limited
and it's difficult to figure out what the actual config changes should be. After some
poking around and following a trail of forum posts to a random
[powershell script](https://www.powershellgallery.com/packages/DatabricksPS/1.11.0.8/Content/Public%5CWorkspaceConfig.ps1)
that happened to document the settings I wanted, I was able to create a config that worked.
I've reproduced it below as a reference to both myself and anyone else interested in
remediating SAT issues with terraform.

# The code

```hcl
resource "databricks_workspace_conf" "this" {
  custom_config = {
    "maxTokenLifetimeDays" : "180"
    "enableTokensConfig" : true
    "enableDeprecatedClusterNamedInitScripts" : false
    "enableDeprecatedGlobalInitScripts" : false
    "enforceUserIsolation" : true
    # set at account level, can't be done at workspace level
    # DO NOT UNCOMMENT OR OTHERWISE ADD THIS, IT WILL BREAK YOUR STATE
    # "enableWebTerminal" : true
    "enableNotebookTableClipboard" : false
    "enableResultsDownloading" : false
  }
}
```

# Conclusion

That's it, I just spent a lot of time figuring out how to make that little block of
code so I wanted to share it. Put something like the above in your workspace provisioning
script and you'll address the SAT issues that are related to your workspace config.