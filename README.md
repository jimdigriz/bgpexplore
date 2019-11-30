These instructions cover how to import MRT dump data (from BGP routing daemons) into a graph database ([neo4j](https://neo4j.com/)) to quickly explore it.

The project also includes an Erlang implementation of the original Python [`mrt2bgpdump`](https://github.com/t2mune/mrtparse) implementation as it was found to be extremely slow.

## Related Links

 * [Multi-Threaded Routing Toolkit (MRT) Routing Information Export Format](https://tools.ietf.org/html/rfc6396)
     * MRT data sources:
         * [RIPE - RIS Raw Data](https://www.ripe.net/analyse/internet-measurements/routing-information-service-ris/ris-raw-data)
         * [Route Views](http://www.routeviews.org)
         * [Isolario Project](https://www.isolario.it)
 * [neo4j - Cypher Manual](https://neo4j.com/docs/cypher-manual/current/)
     * [Remove consecutive duplicates from a list](https://markhneedham.com/blog/2019/01/12/neo4j-cypher-remove-consecutive-duplicates/)

# Preflight

 * Docker (sorry!)
 * Erlang - used to extract data from the MRT as `mrt2bgpdump` is *really* slow

If you find you need to explore the MRT dumps you probably will want to install [`mrtparse`](https://github.com/t2mune/mrtparse).

# Usage

## Fetch

Fetch some RIS data (about 3GB over 20+ files; you can manually download a single file to process):

    env DATE=$(date -u +%Y%m%d) sh fetch.sh

**N.B.** `DATE` defaults to today so can be left out (if after UTC midnight!) 

## Extract

Extract the bits of BGP information we want (about 1min for `rrc06`, does ~50k routes per second, on an [i7-8550U](https://ark.intel.com/content/www/us/en/ark/products/122589/intel-core-i7-8550u-processor-8m-cache-up-to-4-00-ghz.html) it takes about 30mins to cook every with `xargs` and `-P6`):

    ./mrt2bgpdump.escript ris-data/bview.20191101.0000.06.gz > bgpdump.psv

**N.B.** you will need to amend the `bview` filename to reflect the date of the data downloaded

Then from this we need to build the path relationships (takes about 30 seconds for `rrc06`):

    cat bgpdump.psv \
        | awk 'BEGIN { FS="|"; OFS="|" } { if (index($6, ":") == 0) { V = 4 } else { V = 6 }; split($7, P, " "); for (I = 1; I < length(P); I++) if ( P[I] != P[I+1] ) print V, P[I], P[I+1] }' \
        | sort -u > path.psv

## Import

Run the following from your project directory:

    docker run --rm --publish=7474:7474 --publish=7687:7687 --volume=$(pwd):/import:ro --env=NEO4J_AUTH=none neo4j

Point your browser at: http://localhost:7474 and in the top query box type (executing each statement one by one) the following Cypher statments (takes about two minutes to work through the lot):

    CREATE CONSTRAINT ON (a:AS) ASSERT a.num IS UNIQUE;

    CREATE CONSTRAINT ON (p:Prefix) ASSERT p.cidr IS UNIQUE;

    USING PERIODIC COMMIT 5000
    LOAD CSV WITH HEADERS FROM "file:///dump.tsv" AS row
    FIELDTERMINATOR '\t'
    WITH row, CASE WHEN row.cidr CONTAINS ':' THEN 6 ELSE 4 END AS ver, toInteger(split(row.path, ":")[-1]) AS asnum
    MERGE (a:AS { num: asnum })
    MERGE (n:Prefix { version: ver, cidr: row.cidr })
    MERGE (n)-[:Advertisement { version: ver }]->(a);

    USING PERIODIC COMMIT 5000
    LOAD CSV FROM "file:///path.tsv" AS row
    FIELDTERMINATOR '\t'
    MATCH (s:AS { num: toInteger(row[1]) })
    MATCH (d:AS { num: toInteger(row[2]) })
    MERGE (s)-[:Path { version: toInteger(row[0]) }]->(d);

## Explore

Now in the query box try the following statements:

    MATCH p=()-[r:Path { version: 4 }]->() RETURN p LIMIT 25

    MATCH p=(:AS)-[:Path { version: 4 }]-(:AS)-[:Advertisement]-(n:Prefix) WHERE n.cidr = "1.0.0.0/24" RETURN p LIMIT 100;

    MATCH p=(:AS)-[:Path { version: 4 }]-(:AS)-[:Advertisement]-(n:Prefix) WHERE n.cidr = "212.69.32.0/19" RETURN p LIMIT 100;
