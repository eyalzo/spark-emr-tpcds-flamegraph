# spark-emr-tpcds-flamegraph
Running TPC-DS experiment on AWS EMR and analyze it with FlameGraph

# Installations on the Driver and Exectuors

```bash

### Install Uber JVM Profiler on EMR machines (AMI 2)

# Install git and maven
sudo yum -y install git-core
sudo yum -y install maven

# Clone the profiler and build it
git clone https://github.com/uber-common/jvm-profiler.git
cd jvm-profiler/
# Add support to influxdb, as an optional reporter with Grafana (CPU, memory, IO)
mvn -P influxdb clean package

# Copy to the profiler folder and set permissions
sudo mkdir /opt/profiler
sudo cp target/jvm-profiler-1.0.0.jar /opt/profiler/.
sudo chown hadoop:hadoop /opt/profiler/ -R
chmod +x /opt/profiler/jvm-profiler-1.0.0.jar

### Prepare influxdb configuration

# Change this to your influxdb host address
INFLUX_HOST=18.196.147.58

# Prepare the config file with default influxdb settings
PROFILER_CONFIG="/opt/profiler/influxdb.yaml"
echo "influxdb:" > $PROFILER_CONFIG
echo "  host: ${INFLUX_HOST}" >> $PROFILER_CONFIG
echo "  port: 8086" >> $PROFILER_CONFIG
echo "  database: metrics" >> $PROFILER_CONFIG
echo "  username: admin" >> $PROFILER_CONFIG
echo "  password: admin" >> $PROFILER_CONFIG
```

#Databricks SQL perf

The official TPC-DS toolkit is an important complementary instrument to the detailed spec. 
Without it, it would have been impossible to perform comparable tests with today’s analytics tools. 
The official toolkit is a scalable data and queries generator, that ends with a collection of CSV files and basic SQL queries. 
From that point, it is not trivial to prepare a modern collection of data files, properly compressed and distributed, along with column names and runnable queries. 
Therefore, most people use ready toolkits that add scripts and wrappers to make the required preparations and/or run the queries. 
One of the most popular tools that help to run TPC-DS over Spark, is Databricks’s tool described here.

##Install SBT

The directions are in [SBT Install on Linux](https://www.scala-sbt.org/1.x/docs/Installing-sbt-on-Linux.html).
An AMI compatible version is part of the [bootstrap script](cluster-bootstrap.sh).

##Build spark-sql-perf (requires sbt)

```bash
# If machine is a brand new Ubuntu, you may need to install Java first:
# sudo apt install -y openjdk-11-jre-headless
git clone https://github.com/databricks/spark-sql-perf ~/databricks-spark-sql-perf
cd ~/databricks-spark-sql-perf
sudo sbt +package
```

The reason we build it is this:

```bash
$ ls ~/databricks-spark-sql-perf/target/scala-2.12/*.jar
/home/ubuntu/databricks-spark-sql-perf/target/scala-2.12/spark-sql-perf_2.12-0.5.1-SNAPSHOT.jar
```

##Build Databricks dsdgen
The original dsdgen (from the TPC-DS toolkit) does not work as expected (version 2.4+), because it does not print to stdout. Therefore, it is required to perform the following:

```bash
git clone https://github.com/databricks/tpcds-kit.git ~/databricks-tpcds-kit
cd ~/databricks-tpcds-kit/tools
# You may need this on a brand new machine:
# sudo apt install -y gcc make flex bison byacc
make
```

We do all this just in order to get a slightly modified dsdgen:
```bash
$ ls ~/databricks-tpcds-kit/tools/dsdgen 
/home/ubuntu/databricks-tpcds-kit/tools/dsdgen
```

Now, copy the full-path of dsdgen and use it below in the scala code.
Run spark-shell with spark-sql-perf
Must run with the correct jar from databricks, to match the scala version used in the shell. Otherwise, it may cause some errors when loading classes.

```bash
$ spark-shell --jars /home/ubuntu/databricks-spark-sql-perf/target/scala-2.12/spark-sql-perf_2.12-0.5.1-SNAPSHOT.jar
```

The scala code
```scala
import com.databricks.spark.sql.perf.tpcds.TPCDSTables

import org.apache.spark.sql._
val sqlContext = new SQLContext(sc)

// val dsdgenDir="/home/ubuntu/v2.13.0rc1/tools"
// Note: you must use Databricks version that prints to stdout (see above)
val dsdgenDir="/home/ubuntu/databricks-tpcds-kit/tools"

val scaleFactor="10"
val tables = new TPCDSTables(sqlContext,
    dsdgenDir = dsdgenDir, // location of dsdgen
    scaleFactor = scaleFactor,
    useDoubleForDecimal = false, // true to replace DecimalType with DoubleType
    useStringForDate = false) // true to replace DateType with StringType

val dataGenDir="/home/ubuntu/tpc-ds-data-10"
val tableFilter="catalog_sales"
val format="parquet"
val numPartitions=2
val partitionTables=true
val clusterByPartitionColumns=true
tables.genData(
    location = dataGenDir,
    format = format,
    overwrite = true, // overwrite the data that is already there
    partitionTables = partitionTables, // create the partitioned fact tables 
    clusterByPartitionColumns = clusterByPartitionColumns, // shuffle to get partitions coalesced into single files. 
    filterOutNullPartitionValues = false, // true to filter out the partition with NULL key value
    tableFilter = tableFilter, // "" means generate all tables
    numPartitions = numPartitions) // how many dsdgen partitions to run - number of input tasks.
```

Create Parquet files
```scala
val databaseName: String = "tpcds_1g"
sql(s"create database $databaseName")
tables.createExternalTables(dataGenDir, "parquet", databaseName, overwrite = true, discoverPartitions = true)
```scala

##Databricks with S3
```scala
spark-shell --jars /home/ubuntu/databricks-spark-sql-perf/target/scala-2.12/spark-sql-perf_2.12-0.5.1-SNAPSHOT.jar --conf spark.hadoop.fs.s3a.endpoint=s3.eu-central-1.amazonaws.com --conf spark.hadoop.fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem --conf spark.executor.extraJavaOptions=-Dcom.amazonaws.services.s3.enableV4=true --conf spark.driver.extraJavaOptions=-Dcom.amazonaws.services.s3.enableV4=true --packages com.amazonaws:aws-java-sdk:1.7.4,org.apache.hadoop:hadoop-aws:2.7.3
```

The scala code requires only a small change:
```scala
sc.hadoopConfiguration.set("fs.s3a.access.key", "AKIAIY4KDPGV27GL6IBA")
sc.hadoopConfiguration.set("fs.s3a.secret.key", "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")

val scaleFactor="1"
val tables = new TPCDSTables(sqlContext, dsdgenDir = dsdgenDir, scaleFactor = scaleFactor, useDoubleForDecimal = false, useStringForDate = false)

val dataGenDir="s3a://tpcds-10g-parquet-direct-s3"
val numPartitions=2
val partitionTables=false
val clusterByPartitionColumns=false

def time[R](block: => R): R = {
    val t0 = System.nanoTime()
    val result = block    // call-by-name
    val t1 = System.nanoTime()
    println("Elapsed time: " + (t1 - t0) + "ns")
    result
    }

time(tables.genData(location = dataGenDir, format = format, overwrite = true, partitionTables = partitionTables, clusterByPartitionColumns = clusterByPartitionColumns, filterOutNullPartitionValues = false, tableFilter = tableFilter, numPartitions = numPartitions))

val dataGenDir="/tmp"
time(tables.genData(location = dataGenDir, format = format, overwrite = true, partitionTables = partitionTables, clusterByPartitionColumns = clusterByPartitionColumns, filterOutNullPartitionValues = false, tableFilter = tableFilter, numPartitions = numPartitions))
```