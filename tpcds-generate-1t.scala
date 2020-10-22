// Run spark shell with profiler every second, reporting to file:
// JVM_PROFILER_JAR="/opt/profiler/jvm-profiler-1.0.0.jar"; spark-shell --jars /opt/profiler/spark-sql-perf_2.12-0.5.1-SNAPSHOT.jar --conf "spark.jars=${JVM_PROFILER_JAR}" --conf "spark.driver.extraJavaOptions=-javaagent:${JVM_PROFILER_JAR}=reporter=com.uber.profiling.reporters.FileOutputReporter,outputDir=/tmp/profiler_output,metricInterval=1000,sampleInterval=1000,ioProfiling=true" --conf "spark.executor.extraJavaOptions=-javaagent:${JVM_PROFILER_JAR}=reporter=com.uber.profiling.reporters.FileOutputReporter,outputDir=/tmp/profiler_output,tag=influxdb,metricInterval=1000,sampleInterval=1000,ioProfiling=true"

import com.databricks.spark.sql.perf.tpcds.TPCDSTables

import org.apache.spark.sql._
val sqlContext = new SQLContext(sc)

// location of dsdgen
// Note: you must use Databricks version that prints to stdout (see above)
val dsdgenDir="/opt/profiler/databricks-tpcds-kit/tools"
val scaleFactor="1000"
// true to replace DecimalType with DoubleType
val useDoubleForDecimal=false
// true to replace DateType with StringType
val useStringForDate = false

val tables = new TPCDSTables(sqlContext, dsdgenDir = dsdgenDir, scaleFactor = scaleFactor, useDoubleForDecimal = useDoubleForDecimal, useStringForDate = useStringForDate)

val dataGenDir="s3a://eyalzo-tpcds/tpcds-data-1000g"
val format="parquet"
// create the partitioned fact tables
val partitionTables=false
// shuffle to get partitions coalesced into single files.
val clusterByPartitionColumns=false
// true to filter out the partition with NULL key value
val filterOutNullPartitionValues = false
// "" means generate all tables
// For example: val tableFilter="catalog_sales"
val tableFilter=""
// how many dsdgen partitions to run - number of input tasks.
val numPartitions=200

// Generate the data (may take a long time)
tables.genData( location = dataGenDir, format = format, overwrite = true, partitionTables = partitionTables, clusterByPartitionColumns = clusterByPartitionColumns, filterOutNullPartitionValues = filterOutNullPartitionValues, tableFilter = tableFilter, numPartitions = numPartitions)

val databaseName: String = "tpcds_100g"
sql(s"create database $databaseName")
// Create metastore tables in a specified database for your data.
// Once tables are created, the current database will be switched to the specified database.
// Note: update discoverPartitions if using partitions
tables.createExternalTables(dataGenDir, "parquet", databaseName, overwrite = true, discoverPartitions = false)
