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
     * [Shortest Path](https://neo4j.com/blog/graph-algorithms-neo4j-shortest-path/)
     * [Closeness Centrality](https://neo4j.com/blog/graph-algorithms-neo4j-closeness-centrality/)

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

Now we build a property map for AS nodes:

    # list of unique AS numbers
    zcat asn.txt.gz \
        | sed -e 's/^\(23456\) \(.*\)$/\1|-Reserved AS-|\2|ZZ/; s/\( -Reserved AS-\), ZZ,/\1,/; s/^\([0-9]*\) \(.*\) - \(.*\), \([A-Z][A-Z]\)$/\1|\2|\3|\4/; s/^\([0-9]*\) \(.*\), \([A-Z][A-Z]\)$/\1|\2|\2|\3/;' \
        | gzip -c > as.psv.gz

Now we extract the information we want from this (takes about a minute for `rrc06`):

    # mapping of prefix to AS number
    zcat bgpdump.psv.gz \
        | sed -e 's/ {[0-9,]*}|/|/' \
        | awk 'BEGIN { FS="|"; OFS="|" } { split($7, P, " "); print $6, P[length(P)] }' \
        | grep -v -E '^(0\.0\.0\.0/0|::/0|(10|192\.168|172\.(1[6-9]|2[0-9]|3[0-1]))\.)' \
        | sort -u \
        | gzip -c > prefix2as.psv.gz

    # peerings by protocol ipver between AS numbers
    zcat bgpdump.psv.gz \
        | sed -e 's/ {[0-9,]*}|/|/' \
        | awk 'BEGIN { FS="|"; OFS="|" } { if (index($6, ":") == 0) { V = 4 } else { V = 6 }; split($7, P, " "); for (I = 1; I < length(P); I++) if ( P[I] != P[I+1] ) print V, P[length(P)], P[I], P[I+1] }' \
        | sort -u \
        | gzip -c > peer.psv.gz

## Import

Run the following from your project directory:

    mkdir -p plugins
    wget -P plugins https://github.com/neo4j-contrib/neo4j-apoc-procedures/releases/download/3.5.0.6/apoc-3.5.0.6-all.jar
    wget -P plugins https://github.com/neo4j-contrib/neo4j-graph-algorithms/releases/download/3.5.4.0/graph-algorithms-algo-3.5.4.0.jar

    docker run -it --rm \
        --publish=127.0.0.1:7474:7474 --publish=127.0.0.1:7687:7687 \
        --volume=$(pwd):/import:ro \
        --volume=$(pwd)/plugins:/plugins:ro \
        --env=NEO4J_AUTH=none \
        --env=NEO4J_dbms_memory_pagecache_size=2G \
        --env=NEO4J_dbms_memory_heap_max__size=16G \
        --env=NEO4J_dbms_security_procedures_unrestricted='apoc.*,algo.*' \
        neo4j:3.5

Point your browser at http://localhost:7474 and log in using 'No authentication', [select the cog at the bottom left to open 'Browser Settings' and uncheck 'Connect result nodes'](https://stackoverflow.com/questions/50065869/neo4j-show-only-specific-relations-in-the-browser-graph-view).

Now in the top query box copy and paste the following Cypher statements (takes about two minutes to work through `rrc06`):

    CREATE CONSTRAINT ON (a:AS) ASSERT a.num IS UNIQUE;

    CREATE CONSTRAINT ON (p:Prefix) ASSERT p.cidr IS UNIQUE;

    USING PERIODIC COMMIT
    LOAD CSV FROM "file:///as.psv.gz" AS row
    FIELDTERMINATOR '|'
    CREATE (a:AS { num: toInteger(row[0]) })
    SET a.netname = row[1], a.org = row[2], a.tld = row[3];

    // cannot used CREATE as prefix2as is not a 1:1 mapping
    USING PERIODIC COMMIT
    LOAD CSV FROM "file:///prefix2as.psv.gz" AS row
    FIELDTERMINATOR '|'
    WITH CASE WHEN row[0] CONTAINS ':' THEN 6 ELSE 4 END AS ipver, row[0] AS cidr
    MERGE (p:Prefix { cidr: cidr })
    ON CREATE SET p.ipver = ipver;

    USING PERIODIC COMMIT
    LOAD CSV FROM "file:///prefix2as.psv.gz" AS row
    FIELDTERMINATOR '|'
    WITH row[0] AS cidr, toInteger(row[1]) AS num
    MATCH (p:Prefix { cidr: cidr })
    MATCH (o:AS { num: num })
    CREATE (p)-[:ADVERTISEMENT]->(o);

    CREATE INDEX ON :Peer(ipver, origin, snum, dnum);

    USING PERIODIC COMMIT
    LOAD CSV FROM "file:///peer.psv.gz" AS row
    FIELDTERMINATOR '|'
    WITH [x IN row | toInteger(x)] AS row
    WITH row[0] AS ipver, row[1] AS origin, row[2] AS dnum, row[3] AS snum
    MATCH (s:AS { num: snum })
    MATCH (d:AS { num: dnum })
    MERGE (d)-[:PEER]->(:Peer { ipver: ipver, origin: origin, snum: snum, dnum: dnum })-[:PEER]->(s);

    DROP INDEX ON :Peer(ipver, origin, snum, dnum);

    MATCH f=(d:AS)-[r1:PEER]->(p:Peer { snum: s.num, dnum: d.num })-[r2:PEER]->(s:AS)
    CREATE (d)-[r:PEER { origin: p.origin, ipver: p.ipver }]->(s)
    DETACH DELETE r1, p, r2;

## Explore

Now in the query box try the following statements:

    # peerings to 212.69.32.0/19
    MATCH p=(:AS)-[r:PEER { origin: a.num, ipver: n.ipver }]->(a:AS)<-[:ADVERTISEMENT]-(n:Prefix { cidr: "212.69.32.0/19" })
    RETURN p;

    # peerings between 212.69.32.0/19 and AS2497
    MATCH p=(n:Prefix { cidr: "212.69.32.0/19" })-[:ADVERTISEMENT]->(s:AS)<-[:PEER*.. { origin: s.num, ipver: n.ipver }]-(:AS { num: 2497 })
    RETURN p;

    # discover BGP Multiple Origin AS (MOAS) conflicts
    MATCH (n:Prefix)-[r:ADVERTISEMENT]->(:AS)
    WITH n, count(r) AS rel_cnt
    WHERE rel_cnt > 1
    WITH n
    LIMIT 100
    MATCH p=(n)-[:ADVERTISEMENT]->(:AS)
    RETURN p;
