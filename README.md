This project aims to expose readers to [BGP](https://en.wikipedia.org/wiki/Border_Gateway_Protocol) and the use of a [graph database](https://en.wikipedia.org/wiki/Graph_database) by going through the steps of downloading, importing and exploring [MRT exports](https://tools.ietf.org/html/rfc6396) from Remote Route Collectors (RRC).

Assumed is that you have passing knowledge but not hands-on experience of the terminology used and the problem space occupied by routing, [BGP](https://blog.cdemi.io/beginners-guide-to-understanding-bgp/) and [graph databases](https://neo4j.com/developer/graph-database/).

This project is not about using the 'best' software, whatever that means, this is a learning aid.  It uses shell scripts (not parallelised deliberately!) instead of code and chooses [Neo4j](https://neo4j.com/) under [Docker](https://docker.com) to lower the barrier for entry.

[Cypher (graph databases)](http://www.opencypher.org/) is a better fit to explore BGP data than SQL but I was unable to find much published work where this had actively been used or explored in detail.  As I wanted an excuse to use a graph database I decided to fill in the gap myself.

## Related Links

 * [Neo4j - Cypher Manual](https://neo4j.com/docs/cypher-manual/3.5/)
 * [Multi-Threaded Routing Toolkit (MRT) Routing Information Export Format](https://tools.ietf.org/html/rfc6396)
     * MRT data sources:
         * [RIPE - RIS Raw Data](https://www.ripe.net/analyse/internet-measurements/routing-information-service-ris/ris-raw-data)
         * [Route Views](http://www.routeviews.org)
         * [Isolario Project](https://www.isolario.it)
 * [BGPlay](https://stat.ripe.net/bgplay)
     * [Real-time BGP Visualisation with BGPlay](https://labs.ripe.net/Members/massimo_candela/real-time-bgp-visualisation-with-bgplay)

# Preflight

 * [Docker](https://docs.docker.com/install/) (sorry!)
 * [Erlang](https://www.erlang.org/downloads)
     * The project includes an Erlang implementation of [`mrt2bgpdump`](https://github.com/t2mune/mrtparse) as it was found to be extremely slow; there is no need to understand or read it
        * though [BGPStream](https://bgpstream.caida.org/) was an option it would have made preflight significantly harder
     * Quick install:
        * **Debian 10/Ubuntu 18.04 bionic:** `apt-get install --no-install-recommends erlang-base`
        * **CentOS 8:** `yum install -y epel-release && yum install erlang`
 * [optional] off-piste exploration of the MRT exports requires [`mrtparse`](https://github.com/t2mune/mrtparse) to be install
     * `mrt-print-all` is in-particularly useful in combination with the comments in `mrt2bgpdump.escript` pointing to the relevant sections of the RFCs in understanding what the decoded attributes mean
     * Quick install:
        * **Debian 10/Ubuntu 18.04 bionic:** `apt-get install --no-install-recommends mrtparse`
        * **CentOS 8/macOS:** `pip3 install mrtparse`

You will also need 10GiB of disk space for the raw/processed data files and about 8GiB of free RAM.

## macOS

You will need to have [`brew` installed](https://brew.sh/) and then you run:

    brew install erlang gawk

# Overview

Beforing starting work with any database, it is wise to put upfront thought into what [schema](https://en.wikipedia.org/wiki/Database_schema) to use which requires some basic understanding of the data and the environment it represents that we will be using.

[BGP works by assigning an Autonomous Systems ('AS') Number ('ASN')](https://tools.ietf.org/html/rfc4271) to every entity on the Internet through which they advertise either IP address space ('prefix') they terminate (eg. [Amazon are assigned AS16509](https://bgp.he.net/AS16509) and host systems in the IP range 34.240.0.0/13) and/or act as transit that advertising connectivity between ASs (eg. Hurricane Electric provide transit between [Choopa on AS20473](https://bgp.he.net/AS20473) and [Infinity Developments Limited on AS12496](https://bgp.he.net/AS12496)).

To build this graph we need to get a snapshot of an Internet router's database, this comes in the form of MRT snapshots.  In these snapshots are [BGP `AS_PATH` attributes](https://tools.ietf.org/html/rfc4271#section-5.1.2) (a list of `AS_SEQUENCE` and `AS_SET` sub-attributes) that describe the path from our router to the destination prefix.

We use the `AS_PATH` attribute to infer the topology of the Internet passively and so a suitable initial schema to work with may look like:

    [Prefix 1] --+-> [AS] <---- [AS peer A] <--- [AS x] <----------- [Our View from the RRC]
                 |     ^             ^                                        |
    [Prefix 2] --+     |             |                                        |
                 |     \------- [AS peer B] <--- [AS y] <-- [AS z] <----------/
    [Prefix 3] --/

An AS node is unique and referenced by its ASN and it has zero ('transit') or more prefixes (IP ranges) associated with it.  The AS additionally has one or more peers that are other AS nodes.

## Fetch

### ASN List

Fetch the ASN list with:

    curl --compressed https://ftp.ripe.net/ripe/asnames/asn.txt | gzip -c > asn.txt.gz

### MRT Exports

Use the following to fetch a snapshot of the global routing table (about 3GB over 20+ files; you can manually download a single file to process) from an archive of RRC exports:

    env DATE=$(date -u +%Y%m%d) sh fetch.sh

**N.B.** `DATE` defaults to today so can be left out (if an hour or so after UTC midnight!)

## Processing

To decorate the AS nodes, we build a list of mappings of ASNs to their registered organisation/country:

    gzip -dc asn.txt.gz \
        | env LC_ALL=C sed -e 's/^\(23456\) \(.*\)$/\1\t-Reserved AS-\t\2\tZZ/; s/\( -Reserved AS-\), ZZ,/\1,/; s/^\([0-9]*\) \(.*\) - \(.*\), \([A-Z][A-Z]\)$/\1\t\2\t\3\t\4/; s/^\([0-9]*\) \(.*\), \([A-Z][A-Z]\)$/\1\t\2\t\2\t\3/;' \
        | gzip -c > asn.tsv.gz

**N.B.** `sed` is used to fix up the original source file to make it consistent and machine readable

As the MRT exports are in a binary format we need to convert them to a parsable ASCII format (choosing 'bgpdump format' as it is popular).

    ./mrt2bgpdump.escript ris-data/bview.20191101.0000.06.gz | gzip -c > ris-data/bview.20191101.0000.06.gz.bgpdump.psv.gz

**N.B.** you will need to amend the `bview` filename to reflect the date of the routing table snapshot downloaded

For the first time you run through these instructions you should only process the downloaded `06` export as you have just done above as it is small and will let you quickly get up and running in under ten minutes; the results from our queries below will make more sense too.  Later though you may want to process all the exports dumps which on an [i7-8550U](https://ark.intel.com/content/www/us/en/ark/products/122589/intel-core-i7-8550u-processor-8m-cache-up-to-4-00-ghz.html) takes about 90 minutes to run end to end (30 minutes alone in the following `mrt2bgpdump` step) which you can do with:

    # only run this if you want all the data imported which for the first time you will not!
    find ris-data -type f -name 'bview.*.gz' \! -name '*.bgpdump.psv.gz' \
        | nice -n19 ionice -c3 xargs -t -P$(getconf _NPROCESSORS_ONLN) -I{} /bin/sh -c "./mrt2bgpdump.escript '{}' | gzip -c > '{}.bgpdump.psv.gz'"

Neo4j supports [importing CSV files](https://neo4j.com/developer/guide-import-csv/) which we will use but is slow unless you take a lot of care in arranging your data to make use of indexes and `CREATE` over `MERGE` meaning we unfortunately have to do a lot of upfront data pre-processing.

Create a list of paths from our RRCs to the ASs they peer with:

    find ris-data -type f -name '*.bgpdump.psv.gz' \
        | xargs -I{} /bin/sh -c "gzip -dc {} | cut -d'|' -f5 | sort -u | xargs -n1 printf '{}|%s\n'" \
        | sed -e 's/^.*\.\([0-9]*\)\.gz\.bgpdump\.psv\.gz/\1/' \
        | gzip -c > rrc2path.psv.gz

Create a list of prefixes to paths:

    # sed to remove the AS_SET attribute
    #  if there is a single entry we break it out
    #  trailing AS_SETs are stripped out and we treat the prefix as being connected to end of the AS_PATH
    #  for the few remaining AS_SETs that exist in the middle of the data we ignore the entire advertisement
    # perl to remove AS_PATH prepending
    #  this is not perfect, but we DELETE the stray loops during the import phase later
    # grep removes the default route prefixes we are not interested in
    find ris-data -type f -name '*.bgpdump.psv.gz' \
        | xargs gzip -dc \
        | cut -d'|' -f6,7 \
        | sed -e 's/{\([0-9]*\)}/\1/g; s/ {.*}$//; /{.*}/ d' \
        | perl -p -e 's/(?:( [0-9]+)\1+)(?![0-9])/\1/g; s/((?: [0-9]+)+)\1/\1/g' \
        | grep -v '^\(0\.0\.0\.0\|::\)/0|' \
        | gzip -c > prefix2aspath.psv.gz

Create a list of prefixes to origins (should be a 1:1 mapping but occasionally is not):

    gzip -dc prefix2aspath.psv.gz \
        | sed -e 's/|.* \([0-9]*\)$/|\1/' \
        | gawk 'BEGIN { FS="|" } { A[$1][$2]++ } END { for (P in A) { printf "%s|", P; for (N in A[P]) printf "%s ", N; print "" } }' \
        | sed -e 's/ $//' \
        | gzip -c > prefix2origins.psv.gz
    
Create a list of the paths between ASs:

    gzip -dc prefix2aspath.psv.gz \
        | awk 'BEGIN { FS="|" } { if (index($1, ":") == 0) { V = 4 } else { V = 6 }; split($2, P, " "); for (I = 1; I < length(P); I++) A[V "|" P[I] "|" P[I+1]]=1 } END { for (X in A) print X }' \
        | gzip -c > aspath.psv.gz

## Import

Run the following from your project directory:

    mkdir -p plugins
    cd plugins
    curl -OJL https://github.com/neo4j-contrib/neo4j-apoc-procedures/releases/download/3.5.0.7/apoc-3.5.0.7-all.jar
    curl -OJL https://github.com/neo4j-contrib/neo4j-graph-algorithms/releases/download/3.5.4.0/graph-algorithms-algo-3.5.4.0.jar
    cd -

    docker run -it --rm \
        --publish=127.0.0.1:7474:7474 --publish=127.0.0.1:7687:7687 \
        --volume=$(pwd):/import:ro \
        --volume=$(pwd)/plugins:/plugins:ro \
        --env=NEO4J_AUTH=none \
        --env=NEO4J_dbms_security_procedures_unrestricted='apoc.*,algo.*' \
        neo4j:3.5

Point your browser at http://localhost:7474 and log in using 'No authentication' and select the cog at the bottom left to open 'Browser Settings':

 * uncheck 'Code font ligatures'
 * check 'Enhanced query editor'
 * check 'Enable multi statement query editor'
 * uncheck ['Connect result nodes'](https://stackoverflow.com/questions/50065869/neo4j-show-only-specific-relations-in-the-browser-graph-view)

Now in the top query box copy and paste the all the following multiple Cypher statements and execute by clicking on the 'play' symbol (takes about two minutes to work through *any* dataset size):

    CREATE CONSTRAINT ON (r:RRC) ASSERT r.id IS UNIQUE;
    CREATE CONSTRAINT ON (a:AS) ASSERT a.num IS UNIQUE;
    CREATE CONSTRAINT ON (p:Prefix) ASSERT p.cidr IS UNIQUE;
    
    LOAD CSV FROM 'file:///asn.tsv.gz' AS row FIELDTERMINATOR '\t'
    CREATE (a:AS { num: toInteger(row[0]) })
    SET a.netname = row[1], a.org = row[2], a.tld = row[3];
    
    LOAD CSV FROM 'file:///rrc2path.psv.gz' AS row FIELDTERMINATOR '|'
    MERGE (r:RRC { id: row[0] })
    WITH toInteger(row[1]) AS num, r
    MATCH (a:AS { num: num })
    CREATE (r)-[:PEER { version: 6 }]->(a), (r)-[:PEER { version: 4 }]->(a);
    
    USING PERIODIC COMMIT
    LOAD CSV FROM 'file:///prefix2origins.psv.gz' AS row FIELDTERMINATOR '|'
    WITH CASE WHEN row[0] CONTAINS ':' THEN 6 ELSE 4 END AS version, row[0] AS cidr, [ x IN split(row[1], " ") | toInteger(x) ] AS origins
    CREATE (p:Prefix { cidr: cidr })
    SET p.version = version
    WITH p, origins
    UNWIND origins AS origin
    MATCH (o:AS { num: origin })
    CREATE (p)-[:ADVERTISEMENT]->(o);
    
    USING PERIODIC COMMIT
    LOAD CSV FROM 'file:///aspath.psv.gz' AS row FIELDTERMINATOR '|'
    WITH [ x IN row | toInteger(x) ] AS row
    WITH row[0] AS version, row[1] AS snum, row[2] AS dnum
    MATCH (s:AS { num: snum }), (d:AS { num: dnum })
    CREATE (s)-[:PEER { version: version }]->(d);
    
    MATCH p=(a:AS)-[r:PEER]-(a:AS)
    DELETE r;

**N.B.** if this does not make any progress after five minutes, you may have missed both the `CREATE CONSTRAINT` statements, you can confirm this by [typing `:schema` into the query window](https://neo4j.com/docs/cypher-manual/3.5/schema/constraints/#constraints-get-a-list-of-all-constraints-in-the-database); if you have none, restart the import process from the beginning (remember to kill and restart the docker container)

![Screenshot of data being actively imported](images/importing.png "Importing the data")

# Usage

Here are some example queries you can try to explore the data with by typing these into the query box.

**N.B.** it is normal the screenshots below may show different results to what you get as the dataset I was processing will be different to the one you are and the global Internet topology is actively evolving

## AS Advertising 212.69.32.0/19

    MATCH (:Prefix { cidr: "212.69.32.0/19" })-[:ADVERTISEMENT]->(a:AS)
    RETURN a;

If you double click on the resulting node, it will expand to show its relationships to other nodes.

Note that CIDR is a string match and not an IP address match.  If you want to look for your own IP and its prefix (both IPv4 and IPv6 can be used here) on the Internet go to https://bgp.he.net/ to find out what you are being 'announced' as and use that to match against.

## Peerings for 212.69.32.0/19

    MATCH (n:Prefix { cidr: "212.69.32.0/19" })-[:ADVERTISEMENT]->(:AS)<-[:PEER { version: n.version }]-(a:AS)
    RETURN a;

This query can be expanded to return the prefix and origin AS relationships with those peering ASs:

    MATCH p=(n:Prefix { cidr: "212.69.32.0/19" })-[:ADVERTISEMENT]->(:AS)<-[:PEER { version: n.version }]-(:AS)
    RETURN p;

## Paths to 212.69.32.0/19

To show the paths between `rrc06` (where our routing table dump come from) and the prefix we can use:

    MATCH p=(n:Prefix { cidr: "212.69.32.0/19" })-[:ADVERTISEMENT]->(:AS)<-[:PEER*..5 { version: n.version }]-(:RRC { id: '06' })
    RETURN p
    LIMIT 10;

**N.B.** we limit the `PEER` relationship length to 5 (more than 80% `AS_PATH`'s are equal or shorter than this) to avoid it getting out of control and we only ask for the first 10 results to stop the UI slowing to a crawl or looking too crowded; for your own CIDR prefix you may need to bump the `PEER` hop limit to 10

Of interest to us is the shortest path, which due to our schema choice is the only 'metric' we can use [BGP Best Path Selection](https://www.theroutingtable.com/bgp-best-path-selection/) routing decisions, which describes how traffic moves from `rrc06` to our prefix:

    MATCH i=(n:Prefix { cidr: "212.69.32.0/19" })-[:ADVERTISEMENT]->(o:AS)
    MATCH (r:RRC { id: '06' })
    MATCH p=allShortestPaths((o)<-[rr:PEER*]-(r))
    WHERE all(x in rr WHERE x.version = n.version)
    RETURN i, p;

**N.B.** [`allShortestPaths()`](https://neo4j.com/docs/graph-algorithms/current/labs-algorithms/all-pairs-shortest-path/) does not accept constraints so we have to use the [`all()` predicate](https://neo4j.com/docs/cypher-manual/current/functions/predicate/#functions-all)

![Screenshot of our inferred routing table of rrc06](images/route.png "Route to 212.69.32.0/19 from rrc06")

## Longest `AS_PATH` for `rrc06`

Cypher (and Neo4j) is optimised for finding the shortest paths in a graph but this does not stop us needing to occasionally [look for the longest path](https://neo4j.com/developer/kb/achieving-longestpath-using-cypher/); unfortunately this is usually a really expensive operation.

Fortunately what we can ask is what is the farthest away prefix by iterating over all ASs advertising prefixes, getting the shortest distance to each, sorting by path length in descending order and returning the first ten at the top:

    MATCH (a:AS)<-[:ADVERTISEMENT]-(:Prefix)
    WITH DISTINCT a AS a
    MATCH (r:RRC { id: '06' })
    MATCH p=shortestPath((a)<-[:PEER*]-(r))
    MATCH q=(a)<-[:ADVERTISEMENT]-(:Prefix)
    WITH p, collect(q) AS q
    ORDER BY length(p) DESC
    LIMIT 10
    RETURN p, q;

**N.B.** we `MATCH` and `collect()` the `Prefix`s before we `LIMIT` to avoid receiving the path duplicated for each prefix

![Graph showing the ten longest AS_PATHs](images/longest-paths.png "Results for the Longest Path Query")

Looks like the [USA Army Network Enterprise Technology Command](https://en.wikipedia.org/wiki/USAISC) ([AS320](https://bgp.he.net/AS320)) is a poor choice of a location to host a gaming server for Japan ([`rrc06`'s location](https://www.ripe.net/analyse/internet-measurements/routing-information-service-ris/ris-raw-data)) with a hop length of nine, though there may be other non-technical reasons why you would not!

On this point, hop length is not a good judge of latency, for example London to New York can be a single hop and be 70ms whilst two datacenters in the same city could have several hops separating them.

## Leaking 'Bogon' AS

You may be familiar with the concept of [bogon IP addresses](https://www.team-cymru.com/bogon-reference.html) on the Internet and by [extension there are a number of ASNs that should not be seen in an `AS_PATH`](https://labs.ripe.net/Members/martin_winter/monitoring-bgp-anomalies-on-the-internet) and a good starting point to build one is by looking at the [IANA allocations](https://www.iana.org/assignments/as-numbers/as-numbers.xhtml).

For our example, we will just look for reservations including the [documentation](https://www.iana.org/go/rfc5398) and [private](https://www.iana.org/go/rfc6996) use only ranges.   We build a query looking for bogon ASs that have peering relationships seen publicly:

    MATCH (a:AS)<-[:PEER]-(:AS)
    WITH DISTINCT a AS a
    WHERE a.num = 0 OR (a.num >= 64496 AND a.num <= 131071) OR (a.num >= 4200000000 AND a.num <= 4294967295)
    RETURN a;

## MOAS Conflicts

[`RFC1930`](https://tools.ietf.org/html/rfc1930#section-7) states that generally a prefix will belong to a single AS though there are exceptions for both technical and accidental reasons.  When multiple ASs advertise the same prefix, this is known as [BGP Multiple Origin AS (MOAS) conflict](https://s3.amazonaws.com/www.xiaoliang.net/papers/zhao-imw01.pdf).

We expect to find none, but of course this is the real world and there are around 2500 in the 900k prefixes being advertised:

    MATCH (n:Prefix)-[r:ADVERTISEMENT]->(:AS)
    WITH n, count(r) AS rel_cnt
    WHERE rel_cnt > 1
    WITH DISTINCT n AS n
    MATCH p=(n)-[:ADVERTISEMENT]->(:AS)
    RETURN p, n
    LIMIT 20;

### BGP Hijacking

If a [prefix is hijacked](https://en.wikipedia.org/wiki/BGP_hijacking) we could expect for one type of attack/configuration-error more than one AS number for a given prefix to exist.

We can simulate this by adding the nodes and relationships to set up [AS64497](https://tools.ietf.org/html/rfc5398) to start to advertising 212.69.32.0/19.  Firstly we need to find another AS to set up a peering relationship with that has prefixes seen by `rrc06` (lets pick South Africa as it is far from both Europe and Japan, the latter where `rrc06` is located):

    MATCH (n:Prefix { cidr: "212.69.32.0/19" })
    MATCH (:Prefix { version: n.version })-[:ADVERTISEMENT]->(a:AS { tld: 'ZA' })
    RETURN DISTINCT a
    ORDER BY rand()
    LIMIT 1;

**N.B.** we use [`DISTINCT`](https://neo4j.com/docs/cypher-manual/current/syntax/operators/#syntax-using-the-distinct-operator) otherwise the result is bias to ASs that have a large number of prefixes

When I ran the above I got AS327751 so lets use it:

    MATCH (n:Prefix { cidr: "212.69.32.0/19" })
    MATCH (o:AS { num: 64497 })
    MATCH (a:AS { num: 327751 })
    CREATE
      x=(n)-[:ADVERTISEMENT]->(o),
      y=(o)<-[:PEER { version: n.version }]-(a)
    RETURN x, y;

We can investigate how this could impact the routing table of `rrc06` to 212.69.32.0/19 by using our earlier query (the one using `allShortestPaths()`).  You should see `212.69.32.0/19` now advertises through two different ASs and our hijacker operating AS64497 can steal the portion of the traffic destined for that prefix and traverses the path to it.

![Graph showing two advertisements for 212.69.32.0/19](images/hijack.png "What a BGP Hijack Might Look Like")
