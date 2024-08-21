---
title: "For each tasks in Databricks asset bundles"
date: "2024-08-21"
description: "Maybe I'll save someone else some suffering"
layout: "post"
toc: true
categories: [databricks]
---

This is just a quick post because I couldn't find good documentation for defining
tasks in a loop format in databricks.

Let's say I have a block in a [DAB](https://learn.microsoft.com/en-us/azure/databricks/dev-tools/bundles/)
deployment that looks like this:

```yml
tasks:
    - task_key: "task_for_table_a"
        notebook_task:
            base_parameters:
                table: "table_a"
            notebook_path: "../jobs/table_task.py"
    - task_key: "task_for_table_b"
        notebook_task:
            base_parameters:
                table: "table_b"
            notebook_path: "../jobs/table_task.py"
    - task_key: "task_for_table_c"
        notebook_task:
            base_parameters:
                table: "table_c"
            notebook_path: "../jobs/table_task.py"
```

And I want to convert it into a `for_each_task`
The [api docs](https://docs.databricks.com/api/azure/workspace/jobs/create#tasks-for_each_task)
describe a for_each_task as having an `inputs` field, a `concurrency` field, and then
a `task` field that defines the task that will be run for each element of the array.

That's all good, but they don't actually show how to structure that `inputs` field
or pass it into the looping task. This snippet below shows how it works.

```yml
tasks:
    - task_key: "task_for_tables"
        for_each_task:
            inputs: "[\"table_a\",\"table_b\",\"table_c\"]"
            concurrency: 1 # or whatever
            task:
                task_key: "task_for_tables_loop"
                notebook_task:
                    base_parameters:
                        table: "{{input}}"
                    notebook_path: "../jobs/table_task.py"
```

Note the weird formatting for inputs and the need to define an inner and outer task key.
I think the string can be any json style string, so if you wanted more complex inputs
you could create a list of maps instead of the list of strings in this example.
I think you can pass stuff in from another task to define
inputs, but I didn't have a requirement for that so I haven't tested it.