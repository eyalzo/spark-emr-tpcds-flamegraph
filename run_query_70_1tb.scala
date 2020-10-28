import com.databricks.spark.sql.perf.tpcds.TPCDSTables

import org.apache.spark.sql._

// location of dsdgen
// Note: you must use Databricks version that prints to stdout (see above)
val dsdgenDir="/opt/profiler/databricks-tpcds-kit/tools"
val scaleFactor="1000"

val sqlContext = new SQLContext(sc)
val tables = new TPCDSTables(sqlContext, dsdgenDir = dsdgenDir, scaleFactor = scaleFactor)

val dataGenDir="s3a://eyalzo-tpcds/tpcds-data-1000g"
val databaseName: String = "tpcds_1000g"
sql(s"create database $databaseName")
// Create metastore tables in a specified database for your data.
// Once tables are created, the current database will be switched to the specified database.
// Note: update discoverPartitions if using partitions
tables.createExternalTables(dataGenDir, "parquet", databaseName, overwrite = true, discoverPartitions = false)

val df=spark.sql("""--q70.sql--
                   |
                   | select
                   |    sum(ss_net_profit) as total_sum, s_state, s_county
                   |   ,grouping(s_state)+grouping(s_county) as lochierarchy
                   |   ,rank() over (
                   | 	    partition by grouping(s_state)+grouping(s_county),
                   | 	    case when grouping(s_county) = 0 then s_state end
                   | 	    order by sum(ss_net_profit) desc) as rank_within_parent
                   | from
                   |    store_sales, date_dim d1, store
                   | where
                   |    d1.d_month_seq between 1200 and 1200+11
                   | and d1.d_date_sk = ss_sold_date_sk
                   | and s_store_sk  = ss_store_sk
                   | and s_state in
                   |    (select s_state from
                   |        (select s_state as s_state,
                   | 			      rank() over ( partition by s_state order by sum(ss_net_profit) desc) as ranking
                   |         from store_sales, store, date_dim
                   |         where  d_month_seq between 1200 and 1200+11
                   | 			   and d_date_sk = ss_sold_date_sk
                   | 			   and s_store_sk  = ss_store_sk
                   |         group by s_state) tmp1
                   |     where ranking <= 5)
                   | group by rollup(s_state,s_county)
                   | order by
                   |   lochierarchy desc
                   |  ,case when lochierarchy = 0 then s_state end
                   |  ,rank_within_parent
                   | limit 100""".stripMargin)

df.show(10000)

//df.write.format("parquet").mode("Overwrite").save("tpcds-profilling/20201025/query-70-1tb-5exec")