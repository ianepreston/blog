---
title: "Parsing XSD schemas in Databricks"
date: "2024-07-12"
description: "Maybe I'll save someone else some suffering"
layout: "post"
toc: true
categories: [databricks, spark]
---

# Introduction

Databricks recently announced [enhanced XML parsing](https://www.databricks.com/blog/announcing-simplified-xml-data-ingestion).
This is great news, as my organization has a ton of XML that I would like to parse
and publish in more user friendly structures. Unfortunately for me, most of the example
code and docs assume that your XML inputs have a relatively simple and consistent schema
that can be parsed out using a single sample record. My requirements are more complicated
than that, as our schema varies depending on the particular type of record being read
(different type of forms capturing a subset of all possible inputs), so any sample
record I provide will not have a complete schema for all possible records.

We do have an XML Schema Definition (XSD) file that describes the complete schema of all
possible attributes for these records, and there's a brief snippet in
[the docs](https://learn.microsoft.com/en-us/azure/databricks/query/formats/xml#xsd-support)
that mentions you can use a file like this to create a schema that can be used in parsing
XML. In practice, I found a number of tricky aspects to actually getting this working
that I'll document below in case it's helpful for anyone else.

# Setting up for schema parsing

The first hurdle was figuring out how to actually call the schema parsing method.

From [the docs](https://learn.microsoft.com/en-us/azure/databricks/archive/connectors/spark-xml-library#xsd-support)
I should be able to run something like this in scala (no python interface) and get
a schema object:

```scala
import com.databricks.spark.xml.util.XSDToSchema
import java.nio.file.Paths

val schema = XSDToSchema.read(Paths.get("/path/to/your.xsd"))
val df = spark.read.schema(schema)....xml(...)
```

Unfortunately when I tried to run that in databricks (under various cluster types and
runtime versions) I got an error that `XSDToSchema` did not actually exist.

After a bunch of searching around I found the
[databricks/spark-xml](https://github.com/databricks/spark-xml) repo, which did seem
to have that functionality. After adding `com.databricks:spark-xml_2.12:0.18.0` to a
cluster I was able to actually call that function.

**NOTE**
As best I understand it, this library might conflict with the databricks xml parsing
libraries, so it should only be used for schema extraction. Use a separate cluster to
actually do the xml parsing with the extracted schema.

# Actually extracting the schema

Once you've got the schema out, the next thing to do is get it into a format that's
useful for feeding into `read_xml`. This is relatively straightforward but not well
documented at all.

This bit of scala gets you a json representation of your schema:

```scala
import com.databricks.spark.xml.util.XSDToSchema
import java.nio.file.Paths
import java.io._
import org.apache.spark.sql.types.{StructType, StructField, StringType}
val schema = XSDToSchema.read(Paths.get("path/to/xsd_file.xsd"))
val topField = schema("TopLevelName").dataType.asInstanceOf[StructType]
val schemaStr = topField.json
val file = new File("/path/to/output/schema.json")
val bw = new BufferedWriter(new FileWriter(file))
bw.write(schemaStr)
bw.close()
```

In my case the XSD had a top level struct as if the whole thing was going to be one
dataframe. I actually wanted it to be a column, so I had to drill down one level. Depending
on your particular use case you'll have to modify that.

## Add in a failed record field

I don't want my whole pipeline to fall over if I hit an invalid record, so I'll want to
specify `PERMISSIVE` mode in my XML parsing code. If I do that it expects there to be a
rescue struct to put the failed xml within the target. I'm calling mine `corruptxml`
so I switch over to python, add that in, and write it out as a nicely formatted json.
Even if you don't want to add this in it's probably still worth making a round trip through
python. The json that comes out of the scala step above is valid but it's one single line.
If you put it in python first you get a more readably formatted multi line json at the end.

```python
from pathlib import Path
import json
ddl_base_path = Path("/path/to/output/schema.json")
with open(ddl_base_path, "r") as f:
    ddl_base = f.read()
ddl_dict = json.loads(ddl_base)
# Have to have this field in the schema to use PERMISSIVE mode when reading
ddl_dict["fields"].append({"name": "corruptxml", "type": "string", "nullable": True})
ddl_clean_path = Path("/path/to/output/schema.json")
with open(ddl_clean_path, "w") as f:
    f.write(json.dumps(ddl_dict, indent=4))
```

# Use the schema in a pipeline

In my use case I have an existing DataFrame with a column called `RPT_DATA` that I want
to parse. My code looks something like this:

```python
    from_xml_opts = {
        "mode": "PERMISSIVE",
        "columnNameOfCorruptRecord": "corruptxml",
    }
    ddl_path = Path("schema_ddl.json")
    with open(ddl_path, "r") as f:
        ddl_str = f.read()
    parsed_df = (
        xml_data_df
        # illegal escape character
        .withColumn("RPT_DATA", regexp_replace(col("RPT_DATA"), r"\u001a", ""))
        # illegal escape character
        .withColumn("RPT_DATA", regexp_replace(col("RPT_DATA"), r"&#x1A;", ""))
        # illegal escape character
        .withColumn("RPT_DATA", regexp_replace(col("RPT_DATA"), r"&#x\d;", ""))
        # emojis
        .withColumn("RPT_DATA", regexp_replace(col("RPT_DATA"), r"\&#\d{5};", ""))
        .withColumn("report_xml_dat", from_xml(xml_data_df.RPT_DATA, ddl_str, from_xml_opts))
    )
```

In my case I had to parse out some illegal characters from the strings before I could
get it working. Depending on your inputs those might not be required.

# Conclusion

Parsing out a schema from an XSD and using it to turn a string of XML into a valid
`StructField` isn't too bad and doesn't take a ton of code - if you can actually
find out how to do it. I spent a ton of time googling, trying things that broke, and
going back and forth with Databricks support to get this working so I want to preserve it.
