# Installing the Monitor

This project contains instructions for sending metrics from two sources to influxdb/grafana:
* JVM profiler
* collectd

## Install Grafana

```bash
sudo apt-get install -y apt-transport-https
sudo apt-get install -y software-properties-common wget
wget -q -O - https://packages.grafana.com/gpg.key | sudo apt-key add -
echo "deb https://packages.grafana.com/oss/deb stable main" | sudo tee -a /etc/apt/sources.list.d/grafana.list
sudo apt-get update
sudo apt-get install -y grafana

sudo update-rc.d grafana-server defaults 
sudo systemctl start grafana-server.service 
sudo systemctl status grafana-server.service
```

### Grafana config

Login and set password
Go to port 3000 and login using admin\admin and “change” password to “admin”.
To enable anonymous login, change one entry in /etc/grafana/grafana.ini and restart.
The dashboard is found here: (https://github.com/baghelamit/spark-influxdb-grafana/blob/master/Spark-InfluxDB-Grafana.json)

## Install Influxdb

```bash
wget -qO- https://repos.influxdata.com/influxdb.key | sudo apt-key add -
source /etc/lsb-release
echo "deb https://repos.influxdata.com/${DISTRIB_ID,,} ${DISTRIB_CODENAME} stable" | sudo tee /etc/apt/sources.list.d/influxdb.list
sudo apt-get update && sudo apt-get install influxdb
sudo systemctl unmask influxdb.service
sudo systemctl start influxdb
```

The service looks like this:

```commandline
/system.slice/influxdb.service
             └─ /usr/bin/influxd -config /etc/influxdb/influxdb.conf
```

### Prepare influxdb database 'metrics' for JVM profiler

Before first run, we need to preapre the database that will hold the metrics:

```bash
$ sudo influx
Connected to http://localhost:8086 version 1.8.3
InfluxDB shell version: 1.8.3
> CREATE DATABASE metrics
> use metrics
Using database metrics
> CREATE USER admin WITH PASSWORD 'admin' WITH ALL PRIVILEGES
> show users
user  admin
----  -----
admin true
```

### Config influxdb to accept collectd data

Taken from (https://docs.influxdata.com/influxdb/v1.8/supported_protocols/collectd/).
In the influxdb machine:

```bash
# Do this, or install collectd
sudo mkdir -p /usr/share/collectd
sudo wget https://raw.githubusercontent.com/collectd/collectd/master/src/types.db -O /usr/share/collectd/types.db
# Fix config
sudo sed -i '/^\[\[collectd\]\]$/,/^\[/ s/^  # enabled = false/enabled = true/' /etc/influxdb/influxdb.conf
# Stop and start, because restart does not work well
sudo systemctl stop influxdb; sleep 2; sudo systemctl start influxdb; sudo systemctl status influxdb
```

If something goes wrong, you can check here why:
```bash
sudo journalctl -u influxdb.service --no-pager|tail -n 100
```

In each reporting collectd machine. Assuming collectd was installed with Amazon AMI tools `sudo amazon-linux-extras install -y collectd`.

```bash
sudo sed -i 's/#LoadPlugin network/LoadPlugin network\n<Plugin network>\n  Server "influxdb.eyalzo.com" "25826"\n<\/Plugin>/g' /etc/collectd.conf
# Stop and start, because restart does not work well
sudo systemctl reload collectd
```

To test at the client side (collectd):

```bash
sudo tcpdump -p -n dst port 25826
```

### Install chronograf to browse influxdb

On the same machine as the influxdb:

```bash
# Install netstat
sudo apt-get install -y net-tools
# Install Chornograf
wget https://dl.influxdata.com/chronograf/releases/chronograf_1.8.7_amd64.deb
sudo dpkg -i chronograf_1.8.7_amd64.deb
sudo netstat -ltpn|grep 8888
# Expected results 0 :::8888                 :::*                    LISTEN      427/chronograf 
```

# Running experiments

Running TPC-DS experiment on AWS EMR and analyze it with FlameGraph.
Every machine start with running the [preparations script](cluster-bootstrap.sh).
After that, you can run spark from the driver with TPC-DS support:

```bash
spark-shell --jars /opt/profiler/spark-sql-perf_2.12-0.5.1-SNAPSHOT.jar
```

To add FlameGraph you need to save StackTrace.json to local file:

```bash
JVM_PROFILER_JAR="/opt/profiler/jvm-profiler-1.0.0.jar"

spark-shell --jars /opt/profiler/spark-sql-perf_2.12-0.5.1-SNAPSHOT.jar \
--conf "spark.jars=${JVM_PROFILER_JAR}" \
--conf "spark.driver.extraJavaOptions=-javaagent:${JVM_PROFILER_JAR}=reporter=com.uber.profiling.reporters.FileOutputReporter,outputDir=/tmp/profiler_output,metricInterval=5000,sampleInterval=5000,ioProfiling=true" \
--conf "spark.executor.extraJavaOptions=-javaagent:${JVM_PROFILER_JAR}=reporter=com.uber.profiling.reporters.FileOutputReporter,outputDir=/tmp/profiler_output,tag=influxdb,metricInterval=5000,sampleInterval=5000,ioProfiling=true" 
```

Alternatively, to save metrics to centralized influxdb/grafana, set a config file (see below) and do the following.
In this example the StackTrace is turned off by setting `sampleInterval` to zero, and metrics sampling rate is set to 1 second.

```bash
PROFILER_CONFIG="/opt/profiler/influxdb.yaml"
JVM_PROFILER_JAR="/opt/profiler/jvm-profiler-1.0.0.jar"

spark-shell --jars /opt/profiler/spark-sql-perf_2.12-0.5.1-SNAPSHOT.jar \
--conf "spark.jars=${JVM_PROFILER_JAR}" \
--conf "spark.driver.extraJavaOptions=-javaagent:${JVM_PROFILER_JAR}=reporter=com.uber.profiling.reporters.InfluxDBOutputReporter,tag=driver,configProvider=com.uber.profiling.YamlConfigProvider,configFile=${PROFILER_CONFIG},metricInterval=1000,sampleInterval=0,ioProfiling=true" \
--conf "spark.executor.extraJavaOptions=-javaagent:${JVM_PROFILER_JAR}=reporter=com.uber.profiling.reporters.InfluxDBOutputReporter,tag=executor,configProvider=com.uber.profiling.YamlConfigProvider,configFile=${PROFILER_CONFIG},metricInterval=1000,sampleInterval=0,ioProfiling=true"
```

And after the run is complete, exit the shell (control-D) and copy the files somewhere.
For example:
```bash
for i in `ls -d /tmp/profiler_output/*.json`; do aws s3 cp $i s3://eyalzo-tpcds/tpcds-profiling/20201021/gen-10g-5-exec-20-partitions-parquet-xlarge/executor/; done
```

## Experiment
The following example generates TPC-DS data.

```scala
import com.databricks.spark.sql.perf.tpcds.TPCDSTables

import org.apache.spark.sql._
val sqlContext = new SQLContext(sc)

// location of dsdgen
// Note: you must use Databricks version that prints to stdout (see above)
val dsdgenDir="/opt/profiler/databricks-tpcds-kit/tools"
val scaleFactor="100"
// true to replace DecimalType with DoubleType
val useDoubleForDecimal=false
// true to replace DateType with StringType
val useStringForDate = false

val tables = new TPCDSTables(sqlContext, dsdgenDir = dsdgenDir, scaleFactor = scaleFactor, useDoubleForDecimal = useDoubleForDecimal, useStringForDate = useStringForDate) 

val dataGenDir="s3a://eyalzo-tpcds/tpcds-data-100g"
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
val numPartitions=20

// Generate the data (may take a long time)
tables.genData( location = dataGenDir, format = format, overwrite = true, partitionTables = partitionTables, clusterByPartitionColumns = clusterByPartitionColumns, filterOutNullPartitionValues = filterOutNullPartitionValues, tableFilter = tableFilter, numPartitions = numPartitions) 

```

## Run queries

To run queries on existing generated data files, you need to prepare this first: 

```scala
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
```

Run the experiment (some vars repeat here):

```scala
//
// The experiment itself
//
import com.databricks.spark.sql.perf.tpcds.TPCDS
import org.apache.spark.sql._

val sqlContext = new SQLContext(sc)
val tpcds = new TPCDS (sqlContext = sqlContext)

val dataGenDir="s3a://eyalzo-tpcds/tpcds-data-100g"
val resultLocation = dataGenDir + "/query_results"
val iterations = 1 // how many iterations of queries to run.
val queries = tpcds.tpcds2_4Queries // queries to run.
val timeout = 24*60*60 // timeout, in seconds.
// Run:
val databaseName: String = "tpcds_100g"
sql(s"use $databaseName")
//val experiment = tpcds.runExperiment(queries, iterations = iterations, resultLocation = resultLocation, forkThread = true)
val experiment = tpcds.runExperiment(queries, iterations = iterations, resultLocation = resultLocation)
```

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

# Databricks SQL perf

This is basically an FYI section, because an AMI compatible version of everything here is part of the [bootstrap script](cluster-bootstrap.sh).

The official TPC-DS toolkit is an important complementary instrument to the detailed spec. 
Without it, it would have been impossible to perform comparable tests with today’s analytics tools. 
The official toolkit is a scalable data and queries generator, that ends with a collection of CSV files and basic SQL queries. 
From that point, it is not trivial to prepare a modern collection of data files, properly compressed and distributed, along with column names and runnable queries. 
Therefore, most people use ready toolkits that add scripts and wrappers to make the required preparations and/or run the queries. 
One of the most popular tools that help to run TPC-DS over Spark, is Databricks’s tool described here.

## Install SBT

The directions are in [SBT Install on Linux](https://www.scala-sbt.org/1.x/docs/Installing-sbt-on-Linux.html).

## Build spark-sql-perf (requires sbt)

```bash
# If machine is a brand new Ubuntu, you may need to install Java first:
# sudo apt install -y openjdk-11-jre-headless
git clone https://github.com/databricks/spark-sql-perf ~/databricks-spark-sql-perf
cd ~/databricks-spark-sql-perf
# This one may take a couple of minutes
sudo sbt +package
# Expect something like this: /home/ubuntu/databricks-spark-sql-perf/target/scala-2.12/spark-sql-perf_2.12-0.5.1-SNAPSHOT.jar
cp ~/databricks-spark-sql-perf/target/scala-2.12/spark-sql-perf_2.12-*.jar /opt/profiler/.
```

## Build Databricks dsdgen
The original dsdgen (from the TPC-DS toolkit) does not work as expected (version 2.4+), because it does not print to stdout. Therefore, it is required to perform the following:

```bash
git clone https://github.com/databricks/tpcds-kit.git ~/databricks-tpcds-kit
cd ~/databricks-tpcds-kit/tools
# You may need this on a brand new machine:
# sudo apt install -y gcc make flex bison byacc
make

# We do all this just in order to get a slightly modified dsdgen
cp ~/databricks-tpcds-kit/tools/dsdgen /opt/profiler/dsdgen 
```

Now, copy the full-path of dsdgen and use it below in the scala code.

## Run spark-shell with spark-sql-perf
Must run with the correct jar from databricks, to match the scala version used in the shell. 
Otherwise, it may cause some errors when loading classes.

```bash
$ spark-shell --jars /opt/profiler/spark-sql-perf_2.12-0.5.1-SNAPSHOT.jar
```

The scala code
```scala
import com.databricks.spark.sql.perf.tpcds.TPCDSTables

import org.apache.spark.sql._
val sqlContext = new SQLContext(sc)

// Note: you must use Databricks version that prints to stdout (see above)
val dsdgenDir="/opt/profiler"

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
```

## Databricks with S3
```scala
spark-shell --jars /home/ubuntu/databricks-spark-sql-perf/target/scala-2.12/spark-sql-perf_2.12-0.5.1-SNAPSHOT.jar --conf spark.hadoop.fs.s3a.endpoint=s3.eu-central-1.amazonaws.com --conf spark.hadoop.fs.s3a.impl=org.apache.hadoop.fs.s3a.S3AFileSystem --conf spark.executor.extraJavaOptions=-Dcom.amazonaws.services.s3.enableV4=true --conf spark.driver.extraJavaOptions=-Dcom.amazonaws.services.s3.enableV4=true --packages com.amazonaws:aws-java-sdk:1.7.4,org.apache.hadoop:hadoop-aws:2.7.3
```

The scala code requires only a small change:
```scala
sc.hadoopConfiguration.set("fs.s3a.access.key", "<your access key>")
sc.hadoopConfiguration.set("fs.s3a.secret.key", "<your secret>")

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