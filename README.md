These instructions cover how to import MRT dump data (from BGP routing daemons) into a graph database ([neo4j](https://neo4j.com/)) to quickly explore it.

The project also includes an Erlang implementation of the original Python [`mrt2bgpdump`](https://github.com/t2mune/mrtparse) implementation as it was found to be extremely slow.

## Related Links

 * [BGPlay](https://stat.ripe.net/bgplay)
     * [Real-time BGP Visualisation with BGPlay](https://labs.ripe.net/Members/massimo_candela/real-time-bgp-visualisation-with-bgplay)
 * [Multi-Threaded Routing Toolkit (MRT) Routing Information Export Format](https://tools.ietf.org/html/rfc6396)
     * MRT data sources:
         * [RIPE - RIS Raw Data](https://www.ripe.net/analyse/internet-measurements/routing-information-service-ris/ris-raw-data)
         * [Route Views](http://www.routeviews.org)
         * [Isolario Project](https://www.isolario.it)
 * [neo4j - Cypher Manual](https://neo4j.com/docs/cypher-manual/current/)

# Preflight

 * [Docker](https://docs.docker.com/install/) (sorry!)
 * [Erlang](https://www.erlang.org/downloads)
    * Quick install:
      * **Debian 10:** `apt-get install erlang`
      * **CentOS 8:** `yum install -y epel-release && yum install erlang`
    * you can alternatively install the Python [`mrtparse`](https://github.com/t2mune/mrtparse) tools and replace below `mrt2bgpdump.escript` with `mrt2bgpdump`; it is *really* slow though and after ~120k routes the output rate flatlines

If you find you need to explore the MRT dumps you may find install [`mrtparse`](https://github.com/t2mune/mrtparse) helpful.

# Usage

## Fetch

Fetch some RIS data (about 3GB over 20+ files; you can manually download a single file to process):

    env DATE=$(date -u +%Y%m%d) sh fetch.sh

**N.B.** `DATE` defaults to today so can be left out (if after UTC midnight!) 

## Extract

We convert the MRT files into bgpdump format (about one minute for `rrc06`, does ~50k routes per second, on an [i7-8550U](https://ark.intel.com/content/www/us/en/ark/products/122589/intel-core-i7-8550u-processor-8m-cache-up-to-4-00-ghz.html) it takes about 30minutes to cook all MRT files with `xargs`):

    ./mrt2bgpdump.escript ris-data/bview.20191101.0000.06.gz | gzip -c > bgpdump.psv.gz

**N.B.** you will need to amend the `bview` filename to reflect the date of the data downloaded

Now we extract the information we want from this (takes about a minute for `rrc06`):

    # list of unique AS numbers
    zcat bgpdump.psv.gz \
        | sed -e 's/ {[0-9,]*}|/|/' \
        | cut -d'|' -f7 \
        | tr ' ' '\n' \
        | sort -u \
        | gzip -c > as.psv.gz

    # mapping of prefix to AS number
    zcat bgpdump.psv.gz \
        | sed -e 's/ {[0-9,]*}|/|/' \
        | awk 'BEGIN { FS="|"; OFS="|" } { split($7, P, " "); print $6, P[length(P)] }' \
        | sort -u \
        | gzip -c > prefix2as.psv.gz

    # peerings by protocol version between AS numbers
    zcat bgpdump.psv.gz \
        | sed -e 's/ {[0-9,]*}|/|/' \
        | awk 'BEGIN { FS="|"; OFS="|" } { if (index($6, ":") == 0) { V = 4 } else { V = 6 }; split($7, P, " "); for (I = 1; I < length(P); I++) if ( P[I] != P[I+1] ) print V, P[I], P[I+1] }' \
        | sort -u \
        | gzip -c > path.psv.gz

## Import

Run the following from your project directory:

    docker run -it --rm \
        --publish=7474:7474 --publish=7687:7687 \
        --volume=$(pwd):/import:ro \
        --env=NEO4J_AUTH=none \
        --env=NEO4J_dbms_memory_pagecache_size=2G \
        --env=NEO4J_dbms_memory_heap_max__size=16G \
        neo4j:3.5

Point your browser at: http://localhost:7474 and in the top query box type (executing each statement one by one) the following Cypher statments (takes about two minutes to work through `rrc06`):

    CREATE CONSTRAINT ON (a:AS) ASSERT a.num IS UNIQUE;

    CREATE CONSTRAINT ON (p:Prefix) ASSERT p.cidr IS UNIQUE;

    USING PERIODIC COMMIT 5000
    LOAD CSV FROM "file:///as.psv.gz" AS row
    FIELDTERMINATOR '|'
    WITH toInteger(row[0]) AS num
    MERGE (:AS { num: num });

    USING PERIODIC COMMIT 5000
    LOAD CSV FROM "file:///prefix2as.psv.gz" AS row
    FIELDTERMINATOR '|'
    WITH row
    WHERE NOT row[0] IN ["::/0", "0.0.0.0/0"]
    WITH CASE WHEN row[0] CONTAINS ':' THEN 6 ELSE 4 END AS ipver, row[0] AS cidr
    MERGE (p:Prefix { cidr: cidr })
    SET p.version = ipver;

    USING PERIODIC COMMIT 5000
    LOAD CSV FROM "file:///prefix2as.psv.gz" AS row
    FIELDTERMINATOR '|'
    WITH row
    WHERE NOT row[0] IN ["::/0", "0.0.0.0/0"]
    WITH row[0] AS cidr, toInteger(row[1]) AS num
    MATCH (p:Prefix { cidr: cidr })
    MATCH (o:AS { num: num })
    MERGE (p)-[:ADVERTISEMENT]->(o);

    USING PERIODIC COMMIT 5000
    LOAD CSV FROM "file:///path.psv.gz" AS row
    FIELDTERMINATOR '|'
    WITH [x IN row | toInteger(x)] AS row
    WHERE row[0] = 4
    WITH row[1] AS dnum, row[2] AS snum
    MATCH (s:AS { num: snum })
    MATCH (d:AS { num: dnum })
    MERGE (d)-[:PATHv4]->(s);

    USING PERIODIC COMMIT 5000
    LOAD CSV FROM "file:///path.psv.gz" AS row
    FIELDTERMINATOR '|'
    WITH [x IN row | toInteger(x)] AS row
    WHERE row[0] = 6
    WITH row[1] AS dnum, row[2] AS snum
    MATCH (s:AS { num: snum })
    MATCH (d:AS { num: dnum })
    MERGE (d)-[:PATHv6]->(s);

## Explore

Now in the query box try the following statements:

    # peerings to 212.69.32.0/19
    MATCH p=(:AS)-[:PATHv4]-(:AS)-[:ADVERTISEMENT]-(n:Prefix)
    WHERE n.cidr = "212.69.32.0/19"
    RETURN p;

    # paths between 212.69.32.0/19 and AS8916
    MATCH p=(:Prefix { cidr: "212.69.32.0/19" })-[:ADVERTISEMENT]->(:AS)-[:PATHv4*..3]-(:AS { num: 8916 })
    RETURN p;

    # find shortest path between 212.69.32.0/19 and AS8916
    MATCH
      i=(:Prefix { cidr: "212.69.32.0/19" })-[:ADVERTISEMENT]->(o:AS),
      (a:AS { num: 8916 }),
      p=shortestPath((o)-[:PATHv4*..]-(a))
    RETURN i, p;
