---
aliases:
- /data/python/yyc/2021/12/30/wheretolive
categories:
- data
- python
- yyc
date: '2021-12-30'
description: An excuse to teach myself some cool tools and figure out the best place
  to live
layout: post
title: Building a where to live app
toc: true

---

# Introduction

To start, [here's the code](https://github.com/ianepreston/wheretolive). I'll include
more specific links to specific parts of the process in detail below.

I have two goals with this project:

-   Figure out a good place to live when I move next
-   Learn some data engineering and system administration type skills

For the first goal, I want to scrape real estate sites in my area and assemble a
database of listings. I want to supplement that with open data from the city and other
sources. I want all of this data to be collected and updated in an automated and
efficient process. Finally, I want to be able to analyze this data in order to find the
best place to live based on my personal preferences and requirements.

The second goal should come about as a consequence of the first. I've done web scraping
before, but mostly for one off tasks where I can babysit if my results look weird. To
store the data that I scrape I'll use a database. I've done lots of querying of
databases, but I haven't had much opportunity to design one, so this will be a learning
experience in the regard. I'll also need to have an
[ETL](https://en.wikipedia.org/wiki/Extract,_transform,_load) pipeline to manage the
scheduling, ingestion, and other tasks between the scraper and the database. Finally,
I'll need some way to serve the recommendations.

# Things I did wrong

Since the purpose of writing this up is largely to document what I learned, let's start
with what I did wrong.

## Too much upfront validation

My first instinct when ingesting data from a source I didn't control (the API endpoints
for rentfaster.ca and realtor.ca) was that I should do a bunch of cleaning and
validation as early as possible, which would allow all of my downstream data processing
steps to remain clean. On the plus side I got to learn a bit about how to use
[fastapi](https://fastapi.tiangolo.com/) and
[pydantic](https://pydantic-docs.helpmanual.io/). On the much larger down side, this
approach meant that if I wanted to modify any of the filtering I was applying, or if
there were unanticipated parsing errors (people put the weirdest stuff in the square
footage field) there was no possible recovery. In the final implementation I downloaded
results in the most raw format I could manage. While the uncompressed data was a little
larger than I wanted to be dealing with daily, it compressed down to very manageable
sizes. Separating extraction from any sort of filtering or processing was definitely the
right call.

## Trying to learn this and cloud at once

Since one of the goals of this project was learning, I fairly early on got the idea in
my head that I should try doing this whole process
"[cloud native](https://en.wikipedia.org/wiki/Cloud_native_computing)" on the
"[modern data stack](https://towardsdatascience.com/the-beginners-guide-to-the-modern-data-stack-d1c54bd1793e)".
I'd read a fair bit about these technologies, but hadn't had the opportunity to
implement much in them. In theory, the cool thing about the cloud is that everything is
pay as you go, so for a relatively small data project like I had in mind, the costs
should have been manageable and the learning curve shouldn't have been insurmountable.
In practice this turned out to be incorrect. First, trying to learn how to solve a
specific problem at the same time as learning to use a general technology really
compounds the difficulty of both. I did manage to learn a lot about creating and
deploying
[Azure Functions](https://azure.microsoft.com/en-us/services/functions/#overview) but
due to some issue that I still don't fully understand I also managed to rack up a
sizable cloud bill. It had something to do with a queue function getting stuck and
reprocessing a message repeatedly rather than failing. I learned a very hard lesson
about setting up cost alerts thanks to this. In a future project I'd like to reimplement
this or a similar project in the cloud, as it is still a skillset I'd like to develop,
but I will definitely do as much locally as I can before migrating to the cloud, rather
than trying to prototype something there directly, at least until I get more experience.

# What I did

## Setting up my environment

One of the most important, but also annoying, aspects of any project is configuring and
managing your environment. Most of my custom built logic was in python, so I built a
[poetry](https://python-poetry.org/) project. On top of python there was a lot of
adjacent infrastructure to manage. For one thing, even though I wasn't using the cloud,
I still had information I wanted to leverage but keep private (namely addresses and API
keys), as well as other services that I needed to have up and running. To coordinate all
of this I used [ansible](https://www.ansible.com/). Specifically I kept my secrets using
[ansible-vault](https://docs.ansible.com/ansible/latest/user_guide/vault.html). From the
vault I could either use a `.env` file to load data in with
[python-dotenv](https://pypi.org/project/python-dotenv/) or use them directly in a
playbook (for example, to set my database password). You can see the playbook I used
[here](https://github.com/ianepreston/wheretolive/blob/main/setup.yml) and there's some
related errata at the root of that repository.

## Scraping the listings

There are two listings sources I'm interested in. [realtor.ca](http://realtor.ca) for
sales listings and [rentfaster.ca](http://rentfaster.ca) for rental listings. That's not
going to be 100% comprehensive but in my experience it will cover the vast majority of
listings.

The pattern for the initial scrape of both was very similar. Both sites have an endpoint
that you can query to get a result back in JSON. There were a few examples online on
GitHub that I was able to base mine on. In each case the endpoint has a limit on the
number of results that it will return at one time, so I needed to find a way to iterate
through. In the case of rentfaster it was easy, since it returned search results with a
page number associated. For a given query I could start at page 1 and increment my page
number until I had an empty result set. After each query I dumped the JSON to a raw date
stamped folder. For realtor.ca it was a little trickier, as there was no automatic
chunking. It did allow a price range though, so I picked a very high price ceiling, and
then incremented my price floor to be the highest price seen in the previous result
until I got an empty result back.

The end result of each of these scrapes was a date stamped folder for each containing
zipped JSON files of the raw results from the endpoint. You can find the scraping code
for realtor.ca
[here](https://github.com/ianepreston/wheretolive/blob/main/src/wheretolive/mls/scrape.py)
and for rentfaster
[here](https://github.com/ianepreston/wheretolive/blob/main/src/wheretolive/rfaster/scrape.py).

## Parsing the listings

After downloading the raw listings data, the next step was to process and format it into
something I'd want to consume. This was pretty tedious, but it's a critical part of any
data project. Lots of validating and transforming of various fields. I won't go into the
details here, but the code for parsing realtor.ca is
[here](https://github.com/ianepreston/wheretolive/blob/main/src/wheretolive/mls/parse.py)
and for rentfaster
[here](https://github.com/ianepreston/wheretolive/blob/main/src/wheretolive/rfaster/parse.py).
As the final stage of parsing any given day I would write a
[pandas](https://pandas.pydata.org/) DataFrame out to
[parquet](https://parquet.apache.org/documentation/latest/) in a folder along with the
compressed raw files. This setup made it easy to read in cleaned up data, while still
giving me the flexibility to go back and modify my data cleaning process as necessary on
historical results.

## Storing all the data

I probably could have done basically everything I needed to do for this project in
pandas, or at least [geopandas](https://geopandas.org/en/stable/), but it didn't seem
like the most elegant solution, and I wanted to learn some stuff. With those two
criteria in mind I went with a [PostgreSQL](https://www.postgresql.org/) using
[PostGIS](https://postgis.net/) to handle the geospatial aspects of the data (location
being very important in selecting where to live after all). I deployed the database
itself in a [docker](https://www.docker.com/) container using ansible to manage the
deployment. I also wrote a small wrapper script to make it easier to connect to the
database from python using [sqlalchemy](https://www.sqlalchemy.org/). The wrapper code
is
[here](https://github.com/ianepreston/wheretolive/blob/main/src/wheretolive/postgis.py).

## Ingesting listings data in PostGIS

The last thing that needed to happen with the listings themselves was getting them into
the database. First I created a table for each of rentfaster and realtor.ca in the final
format I wanted.
[Here's](https://github.com/ianepreston/wheretolive/blob/main/scripts/postgis/create_mls.sql)
the sql used to create the realtor.ca one for example. With that created I used pandas
and sqlalchemy to push the cleaned data into a staging table (no need to predefine this
since it's getting wiped each time and pandas can handle table creation). Once the data
was up in staging I would do a few additional calculations, like turning the latitude
and longitude records into PostGIS Points before moving the data into the final table. I
also would update a materialized view of listing data joined to some other data sets at
this point, but I haven't talked about the other data yet so I'll cover that later.
[Here's](https://github.com/ianepreston/wheretolive/blob/main/src/wheretolive/rfaster/ingest.py)
an example of the ingestion script.

## Adding in commute data

One of the most critical things in terms of choosing where to live is how easy it is to
get places from it. This was one of the key pain points that made me think to develop
this project in the first place. Plugging a candidate location into google maps and then
interating through commute times to various important locations (downtown, work, family)
is quite tedious. To make this easier I wanted to compute
[isochrones](https://en.wikipedia.org/wiki/Isochrone_map) for various transit modes and
locations. I initially looked at
[Azure maps](https://azure.microsoft.com/en-ca/services/azure-maps/) for this. They have
a built in method for isochrones, which I got working. Unfortunately it wasn't very
granular in terms of the isochrones it produced, and it didn't support public transit
data at all.

Fortunately, I learned about an amazing project called
[Open Trip Planner](https://docs.opentripplanner.org/en/v1.5.0/) that was exactly what I
needed. It was definitely more work to set up, but the results were way better than I
could get through Azure. Open Trip Planner doesn't include any maps or transit
information out of the box, so I had to set that up. I used
[this](https://github.com/ianepreston/wheretolive/blob/main/scripts/download_osm_data.py)
script to grab a map of my region from
[OpenStreetMap](https://github.com/ianepreston/wheretolive/blob/main/scripts/download_osm_data.py),
supplemented it with detailed transit commute information for my city with
[this script](https://github.com/ianepreston/wheretolive/blob/main/scripts/download_transit_data.py)
and finally even added in some elevation data so that walking and cycling commute times
would be more accurate from
[This government of Canada page](https://maps.canada.ca/czs/index-en.html). I couldn't
automate that last part at all as I had to queue up for my data request and then
retrieve it from a personalized email link. Oh well.

Once I had OpenTripPlanner up and running (again, in a docker container) I was able to
use the API it provided to compute isochrones of various time ranges, transit modes, and
locations using
[this script](https://github.com/ianepreston/wheretolive/blob/main/scripts/make_isochrone.py)
(it still has the Azure maps code in it even though I didn't end up using that if you're
curious).

The output of that API was saved to JSON files, and then ingested into PostGIS using
[this script](https://github.com/ianepreston/wheretolive/blob/main/src/wheretolive/isochrone.py).

Finally, I needed some way to associate this isochrone data with all the listings I was
saving. I wanted columns that would easily let me filter on things like "Is this more
than a 30 minute walk/transit trip from downtown?". Between the different transit modes
(walk, cycle, transit, drive, plus combinations), time ranges (I did 5 minute intervals
between 10 and 60 minutes) and finally locations of interest I had a _lot_ of possible
ways to slice the data. While I could have hand written a giant SQL statement that would
create them all, that would have been very boring to do, error prone, and also required
significant rework if I changed any of my criteria. Instead I did some hacky string
manipulation in python to construct the various components of my query and then stuck it
together to create a view in PostGIS that associated each listing with all the
transportation related attributes I might be interested in.
[Here's](https://github.com/ianepreston/wheretolive/blob/main/scripts/postgis/mls_commute_syntax.py)
what that looks like for realtor.ca.

## Adding in grocery store data

While commute time to various places is certainly important for location, another factor
is nearby amenities. Specifically I was asked if I could include the nearest grocery
store. For this I used the [FourSquare](https://foursquare.com/) API. Similar to the
initial scraping above, I had some issues with chunking here. The FourSquare API only
returns a maximum of 50 results, and there are (a few) more than 50 grocery stores in
all of Calgary. One thing the API lets you specify is a NE and SW corner to define a
rectangle to search within. I took advantage of that and
[numpy's linspace method](https://numpy.org/doc/stable/reference/generated/numpy.linspace.html)
to chunk the city into many boxes, query for grocery stores in each of them, and combine
the result. The scraping code is
[here](https://github.com/ianepreston/wheretolive/blob/main/src/wheretolive/foursquare.py).
The results are a little messy. There are several locations that FourSquare considers a
grocery store that I would disagree with. It hasn't been enough of an issue to bother
with, but between when I save the raw FourSquare results and when I upload the data into
PostGIS
([here](https://github.com/ianepreston/wheretolive/blob/main/scripts/postgis/upload_foursquare.py))
I could easily (but tediously) add in a step that drops the locations that I don't want
to consider as grocery stores.

Once the grocery store data is in the database I create a table that has a row for each
listing, its nearest grocery store, and the distance in meters to that grocery store.
This is just straight line distance and doesn't consider commute time, but it's fast to
compute, gives a good idea, and doesn't make me run every listing and every grocery
store through OpenTripPlanner daily. That seemed like a reasonable tradeoff to me.

## Adding flood zone data

Another thing I want to consider when choosing where to live is climate resiliency.
Calgary experienced a very significant
[flood](https://www.calgary.ca/uep/water/flood-info/flooding-history-calgary.html) less
than a decade ago, and I would like to avoid living somewhere likely to be impacted by a
similar event in the future. To manage this, I grabbed some flood risk data from the
City of Calgary Open Data Portal and ingested it into PostGIS
([here](https://github.com/ianepreston/wheretolive/blob/main/scripts/postgis/floodzone.py)).
From that I could create a table that checked if any given listing was in the 1 in 20 or
1 in 100 year flood zones as defined by the city
([here](https://github.com/ianepreston/wheretolive/blob/main/scripts/postgis/floodzonemap.sql)).

## Combining the results

At this stage in the write up I have a table with listings and their details, as well as
some views that have a foreign key identifying the listing, along with some other
specific attributes (closest grocery store, flood zone status, commute details).
Creating those views actually takes an appreciable amount of time (not massive, but the
commute one for example is a solid 10 seconds). What I want to build off the combination
of all these tables is a filtered list of just the listings that match my criteria. Both
because I want to be able to iterate on my criteria quickly, and because I'm building
similar criteria list for a few other people who are interested in finding a place to
live, I don't want to have to recompute all those queries every time I want to change
something or need to find candidates for a new person. To manage this, I created a
materialized view of all the data sets joined together
([here's](https://github.com/ianepreston/wheretolive/blob/main/scripts/postgis/mls_wide_table.py)
the realtor.ca table for example). After I ingest a new day of listings I can refresh
this materialized view, and then have quick access to all my updated criteria for
current listings.

## Creating candidate lists

The next piece is filtering down all of the possible listings to just the ones that I
might actually want. I did this by making views on top of the wide table described above
that applied whatever filter criteria I wanted, along with only returning a subset of
the available columns that I'd want to see in advance before investigating a listing
further.
[Here's](https://github.com/ianepreston/wheretolive/blob/main/scripts/postgis/candidate_views.sql)
the code for making candidate views for realtor.ca for example.

## Sharing the candidates

Now to make the candidate listings accessible. To make it easier for me, and possible
for others, I export the listings daily to [Dropbox](https://www.dropbox.com/home). This
part of the process was actually delightfully easy. I made some minor modifications to
the example code on the Dropbox page and then used pandas to_html method to push up a
table of listings. From there I could use regular Dropbox functionality to share
personalized folders with people interested in particular listings candidates. If I was
trying to do this as an actual application I'd obviously need a more robust solution,
but for myself and a couple other people this worked perfect. The basic dropbox export
code is
[here](https://github.com/ianepreston/wheretolive/blob/main/src/wheretolive/dropbox_uploader.py)
and the actual listings upload code is
[here](https://github.com/ianepreston/wheretolive/blob/main/src/wheretolive/mls/upload_candidates.py).

## Scheduling things

Now that I have all the components of the pipeline set up I need to automate it. I was
tempted to go with something cool for this like [airflow](https://airflow.apache.org/)
or [dagster](https://dagster.io/) but it didn't seem worth the complexity. I ended up
adding a task to my ansible playbook to schedule cron jobs for realtor.ca and rentfaster
listings. The script cron runs looks like
[this](https://github.com/ianepreston/wheretolive/blob/main/scripts/daily_rfaster.py).

# Conclusion

Overall I'm quite happy with how this project went. I learned a lot (some things the
hard way, like to always set up cost alerts in the cloud). I also ended up with a
service that I'm finding legitimately useful in locating where I want to live next, that
others are finding valuable too.
